import AppKit
import Combine
import Foundation
import UserNotifications
import AlwmL10n

/// Watchlist + settings for Nintendo Price Watcher (Deku Deals).
struct NintendoWatcherSettings: Codable, Equatable, Sendable {
    var watchlist: [NintendoGame]
    var checkIntervalMinutes: Int
    var notifiedSlugs: [String]
    /// Deku Deals country code (`br`, `us`, …) — selects `eshop_{country}` prices.
    var country: String
    var currencySymbol: String

    static let `default` = NintendoWatcherSettings(
        watchlist: [],
        checkIntervalMinutes: 60,
        notifiedSlugs: [],
        country: "br",
        currencySymbol: "R$"
    )
}

struct NintendoGame: Codable, Equatable, Identifiable, Sendable, Hashable {
    var slug: String
    var name: String
    var targetPrice: Double
    var addedDate: Date
    var currentPrice: Double?
    var discountPercent: Int?
    var imageURL: String?

    var id: String { slug }

    var isOnTarget: Bool {
        guard let currentPrice else { return false }
        return currentPrice <= targetPrice
    }

    init(
        slug: String,
        name: String,
        targetPrice: Double,
        addedDate: Date = Date(),
        currentPrice: Double? = nil,
        discountPercent: Int? = nil,
        imageURL: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.targetPrice = targetPrice
        self.addedDate = addedDate
        self.currentPrice = currentPrice
        self.discountPercent = discountPercent
        self.imageURL = imageURL
    }
}

struct NintendoSearchHit: Identifiable, Sendable, Hashable {
    var slug: String
    var name: String
    var price: Double?
    var imageURL: String?
    var id: String { slug }
}

enum NintendoCountry: String, CaseIterable, Identifiable, Sendable {
    case br, us, mx, ar, cl, co, pe, ca, gb, eu_fr = "fr", eu_de = "de", eu_es = "es", jp, au

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .br: return "R$"
        case .us, .mx, .ar, .cl, .co, .ca, .au: return "$"
        case .pe: return "S/"
        case .gb: return "£"
        case .eu_fr, .eu_de, .eu_es: return "€"
        case .jp: return "¥"
        }
    }

    var label: String {
        switch self {
        case .br: return "Brasil (R$)"
        case .us: return "United States (USD)"
        case .mx: return "México (MXN)"
        case .ar: return "Argentina (ARS)"
        case .cl: return "Chile (CLP)"
        case .co: return "Colombia (COP)"
        case .pe: return "Perú (PEN)"
        case .ca: return "Canada (CAD)"
        case .gb: return "United Kingdom (GBP)"
        case .eu_fr: return "France (EUR)"
        case .eu_de: return "Germany (EUR)"
        case .eu_es: return "España (EUR)"
        case .jp: return "Japan (JPY)"
        case .au: return "Australia (AUD)"
        }
    }
}

// MARK: - Deku Deals HTML client

enum DekuDealsAPI {
    private static let base = "https://www.dekudeals.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Shared session keeps `rack.session` cookies — Cloudflare blocks cold search hits.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"
        ]
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    // Rare double warm-up is fine; avoid NSLock in async contexts.
    nonisolated(unsafe) private static var lastWarmAt: Date?
    private static let warmTTL: TimeInterval = 20 * 60
    private static let warmGate = WarmGate()

    private actor WarmGate {
        private var inFlight: Task<Void, Error>?

        func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
            if let inFlight {
                try await inFlight.value
                return
            }
            let task = Task { try await body() }
            inFlight = task
            defer { inFlight = nil }
            try await task.value
        }
    }

    static func itemURL(slug: String) -> URL {
        URL(string: "\(base)/items/\(slug)")!
    }

    static func search(query: String) async throws -> [NintendoSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try await warmUpIfNeeded()
        var comps = URLComponents(string: "\(base)/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "filter[platform]", value: "switch"),
            URLQueryItem(name: "filter[type]", value: "game")
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        let html = try await fetchHTML(url, referer: base + "/")
        return parseSearchResults(html).prefix(8).map { $0 }
    }

    static func searchWithPrices(query: String, country: String, limit: Int = 5) async throws -> [NintendoSearchHit] {
        let baseHits = try await search(query: query)
        // Prefer prices already on search cards (same session country). Only hit item
        // pages when the card has no price — fewer Cloudflare challenges.
        var out: [NintendoSearchHit] = []
        for hit in baseHits.prefix(limit) {
            var enriched = hit
            if enriched.price == nil {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let detail = try? await fetchPrice(slug: hit.slug, country: country) {
                    enriched.price = detail.price
                    if enriched.imageURL == nil { enriched.imageURL = detail.imageURL }
                }
            }
            out.append(enriched)
        }
        return out
    }

    static func fetchPrice(slug: String, country: String) async throws -> (
        price: Double,
        discount: Int?,
        imageURL: String?,
        name: String?
    ) {
        try await warmUpIfNeeded()
        let html = try await fetchHTML(itemURL(slug: slug), referer: base + "/search")
        if let fromAnalytics = parseEshopAnalytics(html: html, country: country) {
            return (
                fromAnalytics.price,
                fromAnalytics.discountPercent,
                parseImageURL(html) ?? nil,
                parseTitle(html)
            )
        }
        // Fallback: schema.org AggregateOffer (lowest across stores).
        if let offer = parseAggregateOffer(html) {
            return (offer.price, nil, parseImageURL(html), parseTitle(html))
        }
        throw URLError(.cannotParseResponse)
    }

    /// Deku Deals issues a session cookie on `/`; without it, `/search` returns 403.
    private static func warmUpIfNeeded(force: Bool = false) async throws {
        let stale: Bool = {
            if force { return true }
            guard let last = lastWarmAt else { return true }
            return Date().timeIntervalSince(last) > warmTTL
        }()
        guard stale else { return }
        try await warmGate.run {
            if !force, let last = lastWarmAt, Date().timeIntervalSince(last) <= warmTTL {
                return
            }
            var req = URLRequest(url: URL(string: base + "/")!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            lastWarmAt = Date()
        }
    }

    private static func fetchHTML(_ url: URL, referer: String, retried: Bool = false) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 403 || http.statusCode == 503 {
            if !retried {
                try await warmUpIfNeeded(force: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
                return try await fetchHTML(url, referer: referer, retried: true)
            }
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Cloudflare interstitial still returns 200 with challenge HTML.
        if let probe = String(data: data.prefix(800), encoding: .utf8),
           probe.contains("Just a moment") || probe.contains("cf-challenge") {
            if !retried {
                try await warmUpIfNeeded(force: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                return try await fetchHTML(url, referer: referer, retried: true)
            }
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }
        return html
    }

    private static func parseSearchResults(_ html: String) -> [NintendoSearchHit] {
        // Each card: optional img → main-link /items/{slug} → <h6>Name</h6> → <strong>price</strong>
        var hits: [NintendoSearchHit] = []
        let pattern = #"(?s)src='(https://cdn\.dekudeals\.com/images/[^']+)'[^>]*>.*?<a class='main-link[^']*' href='/items/([^'?]+)[^']*'>\s*<h6[^>]*>(.*?)</h6>.*?<strong>(.*?)</strong>"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        regex?.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let match,
                  match.numberOfRanges >= 5,
                  let imgR = Range(match.range(at: 1), in: html),
                  let slugR = Range(match.range(at: 2), in: html),
                  let nameR = Range(match.range(at: 3), in: html),
                  let priceR = Range(match.range(at: 4), in: html)
            else { return }
            let slug = String(html[slugR])
            let name = decodeHTML(stripTags(String(html[nameR])))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty, !name.isEmpty else { return }
            let price = parseMoney(String(html[priceR]))
            // CDN only serves some widths (w184/w270 → 403); keep w360 for list thumbs.
            let img = normalizeCoverURL(String(html[imgR]))
            if !hits.contains(where: { $0.slug == slug }) {
                hits.append(NintendoSearchHit(slug: slug, name: name, price: price, imageURL: img))
            }
            if hits.count >= 12 { stop.pointee = true }
        }

        // Fallback looser parse if img+price pattern missed.
        if hits.isEmpty {
            let loose = #"<a class='main-link[^']*' href='/items/([^'?]+)[^']*'>\s*<h6[^>]*>(.*?)</h6>"#
            let re = try? NSRegularExpression(pattern: loose, options: [.dotMatchesLineSeparators])
            re?.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
                guard let match,
                      let slugR = Range(match.range(at: 1), in: html),
                      let nameR = Range(match.range(at: 2), in: html)
                else { return }
                let slug = String(html[slugR])
                let name = decodeHTML(stripTags(String(html[nameR])))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !hits.contains(where: { $0.slug == slug }) else { return }
                hits.append(NintendoSearchHit(slug: slug, name: name, price: nil, imageURL: nil))
                if hits.count >= 12 { stop.pointee = true }
            }
        }
        return hits
    }

    private static func parseEshopAnalytics(html: String, country: String) -> (price: Double, discountPercent: Int?)? {
        let marker = "outAnalytics['eshop_\(country.lowercased()):"
        var best: (price: Double, discountPercent: Int?)?
        for line in html.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard s.contains(marker),
                  let eq = s.range(of: "] = "),
                  let jsonStart = s[eq.upperBound...].firstIndex(of: "{"),
                  let jsonEnd = s[jsonStart...].lastIndex(of: "}")
            else { continue }
            let json = String(s[jsonStart...jsonEnd])
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let items = obj["items"] as? [[String: Any]] ?? []
            let cents: Int? = {
                if let p = items.first?["price"] as? Int { return p }
                if let p = obj["value"] as? Int { return p }
                return nil
            }()
            guard let cents, cents > 0 else { continue }
            let price = Double(cents) / 100.0
            let discountCents = (items.first?["discount"] as? Int) ?? 0
            let discountPercent: Int? = {
                guard discountCents > 0 else { return nil }
                let original = cents + discountCents
                guard original > 0 else { return nil }
                return Int((Double(discountCents) / Double(original) * 100).rounded())
            }()
            if let current = best {
                if price < current.price { best = (price, discountPercent) }
            } else {
                best = (price, discountPercent)
            }
        }
        return best
    }

    private static func parseAggregateOffer(_ html: String) -> (price: Double, currency: String)? {
        guard let low = firstCapture(html, pattern: #"lowPrice"\s*:\s*"([^"]+)""#),
              let value = Double(low.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let currency = firstCapture(html, pattern: #"priceCurrency"\s*:\s*"([^"]+)""#) ?? ""
        return (value, currency)
    }

    private static func parseImageURL(_ html: String) -> String? {
        if let cap = firstCapture(html, pattern: #""image"\s*:\s*\["(https://cdn\.dekudeals\.com/[^"]+)""#) {
            return normalizeCoverURL(cap)
        }
        return firstCapture(html, pattern: #"src='(https://cdn\.dekudeals\.com/images/[^']+)'"#)
            .map(normalizeCoverURL)
    }

    private static func parseTitle(_ html: String) -> String? {
        if let h1 = firstCapture(html, pattern: #"<h1[^>]*>(.*?)</h1>"#) {
            let t = decodeHTML(stripTags(h1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// Prefer a width the CDN actually serves (w184/w270 return 403).
    private static func normalizeCoverURL(_ url: String) -> String {
        url
            .replacingOccurrences(of: "/w184.jpg", with: "/w360.jpg")
            .replacingOccurrences(of: "/w270.jpg", with: "/w360.jpg")
            .replacingOccurrences(of: "/w540.jpg", with: "/w360.jpg")
    }

    private static func decodeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func firstCapture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// Parse `R$27,99`, `$14.99`, `€19,99`, `¥1200`, etc.
    private static func parseMoney(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "R$", with: "")
            .replacingOccurrences(of: "US$", with: "")
            .replacingOccurrences(of: "A$", with: "")
            .replacingOccurrences(of: "C$", with: "")
            .replacingOccurrences(of: "MXN$", with: "")
            .replacingOccurrences(of: "ARS$", with: "")
            .replacingOccurrences(of: "S/", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.lowercased() == "free" { return nil }
        // BR/EU: 1.234,56 → 1234.56
        if cleaned.contains(","), cleaned.contains(".") {
            let normalized = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            return Double(normalized)
        }
        if cleaned.contains(",") {
            return Double(cleaned.replacingOccurrences(of: ",", with: "."))
        }
        return Double(cleaned)
    }
}

// MARK: - Store

final class NintendoWatcherStore: ObservableObject, @unchecked Sendable {
    static let shared = NintendoWatcherStore()

    @Published private(set) var settings: NintendoWatcherSettings = .default
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?

    func setError(_ message: String?) {
        lastError = message
    }

    private let url: URL
    private var timer: Timer?
    var onChange: (() -> Void)?
    var localeCode: () -> String = { PluginL10n.currentCode }

    private func loc() -> String { PluginL10n.resolveCode(localeCode()) }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc()) }

    private func emitChange() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("dev.alwm.nintendo-price-watcher.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            settings = .default
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(NintendoWatcherSettings.self, from: data) {
            settings = decoded
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
        emitChange()
    }

    func startMonitoring() {
        NintendoNotifier.requestAuthorization()
        restartTimer()
        Task { await refreshPrices(notify: true) }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func setInterval(_ minutes: Int) {
        settings.checkIntervalMinutes = min(1440, max(15, minutes))
        save()
        restartTimer()
    }

    func setCountry(_ code: String) {
        let cur = NintendoCountry(rawValue: code) ?? .br
        settings.country = cur.rawValue
        settings.currencySymbol = cur.symbol
        save()
        Task { await refreshPrices(notify: false) }
    }

    func addGame(_ hit: NintendoSearchHit, targetPrice: Double, currentPrice: Double?) {
        guard !settings.watchlist.contains(where: { $0.slug == hit.slug }) else { return }
        settings.watchlist.append(
            NintendoGame(
                slug: hit.slug,
                name: hit.name,
                targetPrice: targetPrice,
                currentPrice: currentPrice,
                imageURL: hit.imageURL
            )
        )
        settings.notifiedSlugs.removeAll { $0 == hit.slug }
        save()
    }

    func removeGame(slug: String) {
        settings.watchlist.removeAll { $0.slug == slug }
        settings.notifiedSlugs.removeAll { $0 == slug }
        save()
    }

    func updateTarget(slug: String, targetPrice: Double) {
        guard let idx = settings.watchlist.firstIndex(where: { $0.slug == slug }) else { return }
        settings.watchlist[idx].targetPrice = targetPrice
        settings.notifiedSlugs.removeAll { $0 == slug }
        save()
    }

    var gamesOnTarget: [NintendoGame] { settings.watchlist.filter(\.isOnTarget) }

    var barTooltip: String {
        if settings.watchlist.isEmpty { return t("plugin.nintendo.tooltip.empty") }
        let hits = gamesOnTarget
        if hits.isEmpty {
            return PluginL10n.tf("plugin.nintendo.tooltip.monitoring", locale: loc(), settings.watchlist.count)
        }
        var lines = [t("plugin.nintendo.tooltip.on_target_header")]
        for g in hits.prefix(6) {
            let price = g.currentPrice.map { String(format: "%.2f", $0) } ?? "?"
            lines.append("• \(g.name) — \(settings.currencySymbol) \(price)")
        }
        lines.append(t("plugin.common.click_to_open"))
        return lines.joined(separator: "\n")
    }

    func refreshPrices(notify: Bool) async {
        guard !isChecking else { return }
        guard !settings.watchlist.isEmpty else {
            isChecking = false
            emitChange()
            return
        }
        isChecking = true
        lastError = nil
        emitChange()
        defer {
            isChecking = false
            emitChange()
        }

        var updated = settings.watchlist
        var newlyHit: [NintendoGame] = []
        for i in updated.indices {
            if i > 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            do {
                let result = try await DekuDealsAPI.fetchPrice(
                    slug: updated[i].slug,
                    country: settings.country
                )
                updated[i].currentPrice = result.price
                updated[i].discountPercent = result.discount
                if let img = result.imageURL { updated[i].imageURL = img }
                if let name = result.name, !name.isEmpty { updated[i].name = name }
                if result.price <= updated[i].targetPrice {
                    newlyHit.append(updated[i])
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        settings.watchlist = updated
        save()

        guard notify else { return }
        let locale = loc()
        for game in newlyHit where !settings.notifiedSlugs.contains(game.slug) {
            NintendoNotifier.notify(game: game, symbol: settings.currencySymbol, locale: locale)
            settings.notifiedSlugs.append(game.slug)
        }
        save()
    }

    private func restartTimer() {
        timer?.invalidate()
        let minutes = Double(max(15, settings.checkIntervalMinutes))
        let t = Timer(timeInterval: minutes * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshPrices(notify: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

enum NintendoNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static var logoURL: URL? {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/PlugIns/NintendoPriceWatcher.alwmplugin/Contents/Resources/logo-notification.png"),
            URL(fileURLWithPath: Bundle.main.bundlePath)
                .appendingPathComponent("Contents/PlugIns/NintendoPriceWatcher.alwmplugin/Contents/Resources/logo-notification.png")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func notify(game: NintendoGame, symbol: String, locale: String) {
        let price = game.currentPrice.map { String(format: "%.2f", $0) } ?? "?"
        let target = String(format: "%.2f", game.targetPrice)
        let content = UNMutableNotificationContent()
        content.title = PluginL10n.t("plugin.nintendo.notify.title", locale: locale)
        content.body = PluginL10n.tf(
            "plugin.nintendo.notify.body",
            locale: locale,
            game.name, symbol, price, symbol, target
        )
        content.sound = .default
        if let logo = logoURL {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("alwm-nintendo-logo-\(UUID().uuidString).png")
            try? FileManager.default.copyItem(at: logo, to: tmp)
            if let attachment = try? UNNotificationAttachment(identifier: "logo", url: tmp) {
                content.attachments = [attachment]
            }
        }
        let req = UNNotificationRequest(
            identifier: "nintendo-\(game.slug)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
