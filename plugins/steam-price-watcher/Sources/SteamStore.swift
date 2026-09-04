import AppKit
import Combine
import Foundation
import UserNotifications
import AlwmL10n

/// Watchlist + settings for Steam Price Watcher.
struct SteamWatcherSettings: Codable, Equatable, Sendable {
    var watchlist: [SteamGame]
    var checkIntervalMinutes: Int
    var notifiedAppIDs: [Int]
    var currency: String
    var currencySymbol: String

    static let `default` = SteamWatcherSettings(
        watchlist: [],
        checkIntervalMinutes: 30,
        notifiedAppIDs: [],
        currency: "br",
        currencySymbol: "R$"
    )

    enum CodingKeys: String, CodingKey {
        case watchlist, checkIntervalMinutes, notifiedAppIDs, currency, currencySymbol
        case checkInterval, notifiedGames
    }

    init(
        watchlist: [SteamGame],
        checkIntervalMinutes: Int,
        notifiedAppIDs: [Int],
        currency: String,
        currencySymbol: String
    ) {
        self.watchlist = watchlist
        self.checkIntervalMinutes = checkIntervalMinutes
        self.notifiedAppIDs = notifiedAppIDs
        self.currency = currency
        self.currencySymbol = currencySymbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchlist = try c.decodeIfPresent([SteamGame].self, forKey: .watchlist) ?? []
        if let m = try c.decodeIfPresent(Int.self, forKey: .checkIntervalMinutes) {
            checkIntervalMinutes = m
        } else {
            checkIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .checkInterval) ?? 30
        }
        if let ids = try c.decodeIfPresent([Int].self, forKey: .notifiedAppIDs) {
            notifiedAppIDs = ids
        } else {
            notifiedAppIDs = try c.decodeIfPresent([Int].self, forKey: .notifiedGames) ?? []
        }
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "br"
        currencySymbol = try c.decodeIfPresent(String.self, forKey: .currencySymbol) ?? "R$"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(watchlist, forKey: .watchlist)
        try c.encode(checkIntervalMinutes, forKey: .checkIntervalMinutes)
        try c.encode(notifiedAppIDs, forKey: .notifiedAppIDs)
        try c.encode(currency, forKey: .currency)
        try c.encode(currencySymbol, forKey: .currencySymbol)
    }
}

struct SteamGame: Codable, Equatable, Identifiable, Sendable, Hashable {
    var appId: Int
    var name: String
    var targetPrice: Double
    var addedDate: Date
    var currentPrice: Double?
    var discountPercent: Int?

    var id: Int { appId }

    var isOnTarget: Bool {
        guard let currentPrice else { return false }
        return currentPrice <= targetPrice
    }

    enum CodingKeys: String, CodingKey {
        case appId, name, targetPrice, addedDate, currentPrice, discountPercent
    }

    init(
        appId: Int,
        name: String,
        targetPrice: Double,
        addedDate: Date = Date(),
        currentPrice: Double? = nil,
        discountPercent: Int? = nil
    ) {
        self.appId = appId
        self.name = name
        self.targetPrice = targetPrice
        self.addedDate = addedDate
        self.currentPrice = currentPrice
        self.discountPercent = discountPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decode(Int.self, forKey: .appId)
        name = try c.decode(String.self, forKey: .name)
        targetPrice = try c.decode(Double.self, forKey: .targetPrice)
        if let date = try? c.decode(Date.self, forKey: .addedDate) {
            addedDate = date
        } else if let raw = try c.decodeIfPresent(String.self, forKey: .addedDate),
                  let parsed = ISO8601DateFormatter().date(from: raw) {
            addedDate = parsed
        } else {
            addedDate = Date()
        }
        currentPrice = try c.decodeIfPresent(Double.self, forKey: .currentPrice)
        discountPercent = try c.decodeIfPresent(Int.self, forKey: .discountPercent)
    }
}

struct SteamSearchHit: Identifiable, Sendable, Hashable {
    var appId: Int
    var name: String
    var price: Double?
    var id: Int { appId }
}

enum SteamCurrency: String, CaseIterable, Identifiable, Sendable {
    case br, us, eu, ar, mx, cl, co, gb, ca, au

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .br: return "R$"
        case .us: return "$"
        case .eu: return "€"
        case .ar: return "ARS$"
        case .mx: return "MXN$"
        case .cl: return "CLP$"
        case .co: return "COP$"
        case .gb: return "£"
        case .ca: return "CAD$"
        case .au: return "AUD$"
        }
    }

    var label: String {
        switch self {
        case .br: return "Real Brasileiro (R$)"
        case .us: return "Dólar Americano (USD)"
        case .eu: return "Euro (EUR)"
        case .ar: return "Peso Argentino (ARS)"
        case .mx: return "Peso Mexicano (MXN)"
        case .cl: return "Peso Chileno (CLP)"
        case .co: return "Peso Colombiano (COP)"
        case .gb: return "Libra Esterlina (GBP)"
        case .ca: return "Dólar Canadense (CAD)"
        case .au: return "Dólar Australiano (AUD)"
        }
    }
}

enum SteamStoreAPI {
    static func capsuleURL(appId: Int) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/capsule_184x69.jpg")!
    }

    static func search(name: String) async throws -> [SteamSearchHit] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let url = URL(string: "https://steamcommunity.com/actions/SearchApps/\(encoded)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.prefix(8).compactMap { row in
            let id: Int?
            if let n = row["appid"] as? Int { id = n }
            else if let s = row["appid"] as? String { id = Int(s) }
            else { id = nil }
            guard let appId = id,
                  let name = row["name"] as? String,
                  !name.isEmpty
            else { return nil }
            return SteamSearchHit(appId: appId, name: name, price: nil)
        }
    }

    /// Search + price for top hits.
    static func searchWithPrices(name: String, currency: String, limit: Int = 5) async throws -> [SteamSearchHit] {
        let base = try await search(name: name)
        var out: [SteamSearchHit] = []
        for hit in base.prefix(limit) {
            var enriched = hit
            if let price = try? await fetchPrice(appId: hit.appId, currency: currency).price {
                enriched.price = price
            }
            out.append(enriched)
        }
        return out
    }

    static func fetchPrice(appId: Int, currency: String) async throws -> (price: Double, discount: Int?) {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appId)&cc=\(currency)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["\(appId)"] as? [String: Any],
              (entry["success"] as? Bool) == true,
              let payload = entry["data"] as? [String: Any],
              let overview = payload["price_overview"] as? [String: Any],
              let finalCents = overview["final"] as? Int
        else {
            throw URLError(.cannotParseResponse)
        }
        return (Double(finalCents) / 100.0, overview["discount_percent"] as? Int)
    }
}

final class SteamWatcherStore: ObservableObject, @unchecked Sendable {
    static let shared = SteamWatcherStore()

    @Published private(set) var settings: SteamWatcherSettings = .default
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
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }
    }

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("dev.alwm.steam-price-watcher.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            settings = .default
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(SteamWatcherSettings.self, from: data) {
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
        SteamNotifier.requestAuthorization()
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

    func setCurrency(_ code: String) {
        let cur = SteamCurrency(rawValue: code) ?? .br
        settings.currency = cur.rawValue
        settings.currencySymbol = cur.symbol
        save()
        Task { await refreshPrices(notify: false) }
    }

    /// Merge watchlist from Noctalia settings, if any.
    @discardableResult
    func importFromNoctalia() -> Int {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/noctalia/plugins/steam-price-watcher/settings.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/noctalia/plugins/steam-price-watcher/settings.json", isDirectory: false)
        ]
        guard let noctaliaURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: noctaliaURL)
        else { return 0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let imported = try? decoder.decode(SteamWatcherSettings.self, from: data) else { return 0 }

        var added = 0
        for game in imported.watchlist {
            guard !settings.watchlist.contains(where: { $0.appId == game.appId }) else { continue }
            settings.watchlist.append(game)
            added += 1
        }
        if settings.watchlist.isEmpty == false {
            if SteamCurrency(rawValue: imported.currency) != nil {
                settings.currency = imported.currency
                settings.currencySymbol = imported.currencySymbol.isEmpty
                    ? (SteamCurrency(rawValue: imported.currency)?.symbol ?? "R$")
                    : imported.currencySymbol
            }
            if imported.checkIntervalMinutes >= 15 {
                settings.checkIntervalMinutes = imported.checkIntervalMinutes
            }
            for id in imported.notifiedAppIDs where !settings.notifiedAppIDs.contains(id) {
                settings.notifiedAppIDs.append(id)
            }
        }
        if added > 0 {
            save()
            restartTimer()
            Task { await refreshPrices(notify: false) }
        }
        return added
    }

    func addGame(_ hit: SteamSearchHit, targetPrice: Double, currentPrice: Double?) {
        guard !settings.watchlist.contains(where: { $0.appId == hit.appId }) else { return }
        settings.watchlist.append(
            SteamGame(appId: hit.appId, name: hit.name, targetPrice: targetPrice, currentPrice: currentPrice)
        )
        settings.notifiedAppIDs.removeAll { $0 == hit.appId }
        save()
    }

    func removeGame(appId: Int) {
        settings.watchlist.removeAll { $0.appId == appId }
        settings.notifiedAppIDs.removeAll { $0 == appId }
        save()
    }

    func updateTarget(appId: Int, targetPrice: Double) {
        guard let idx = settings.watchlist.firstIndex(where: { $0.appId == appId }) else { return }
        settings.watchlist[idx].targetPrice = targetPrice
        settings.notifiedAppIDs.removeAll { $0 == appId }
        save()
    }

    var gamesOnTarget: [SteamGame] { settings.watchlist.filter(\.isOnTarget) }

    var barLabel: String {
        if isChecking { return "…" }
        let n = settings.watchlist.count
        if n == 0 { return "Steam" }
        let hits = gamesOnTarget.count
        return hits > 0 ? "\(hits)/\(n)" : "\(n)"
    }

    var barTooltip: String {
        if settings.watchlist.isEmpty { return t("plugin.steam.tooltip.empty") }
        let hits = gamesOnTarget
        if hits.isEmpty { return PluginL10n.tf("plugin.steam.tooltip.monitoring", locale: loc(), settings.watchlist.count) }
        var lines = [t("plugin.steam.tooltip.on_target_header")]
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
        var newlyHit: [SteamGame] = []
        for i in updated.indices {
            do {
                let result = try await SteamStoreAPI.fetchPrice(
                    appId: updated[i].appId,
                    currency: settings.currency
                )
                updated[i].currentPrice = result.price
                updated[i].discountPercent = result.discount
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
        for game in newlyHit where !settings.notifiedAppIDs.contains(game.appId) {
            SteamNotifier.notify(game: game, symbol: settings.currencySymbol, locale: locale)
            settings.notifiedAppIDs.append(game.appId)
        }
        save()
    }

    private func restartTimer() {
        timer?.invalidate()
        let minutes = Double(max(15, settings.checkIntervalMinutes))
        let t = Timer(timeInterval: minutes * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.refreshPrices(notify: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

enum SteamNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static var logoURL: URL? {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/PlugIns/SteamPriceWatcher.alwmplugin/Contents/Resources/logo-notification.png"),
            URL(fileURLWithPath: Bundle.main.bundlePath)
                .appendingPathComponent("Contents/PlugIns/SteamPriceWatcher.alwmplugin/Contents/Resources/logo-notification.png")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func notify(game: SteamGame, symbol: String, locale: String) {
        let price = game.currentPrice.map { String(format: "%.2f", $0) } ?? "?"
        let target = String(format: "%.2f", game.targetPrice)
        let content = UNMutableNotificationContent()
        content.title = PluginL10n.t("plugin.steam.notify.title", locale: locale)
        content.body = PluginL10n.tf(
            "plugin.steam.notify.body",
            locale: locale,
            game.name, symbol, price, symbol, target
        )
        content.sound = .default
        if let logo = logoURL {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("alwm-steam-logo-\(UUID().uuidString).png")
            try? FileManager.default.copyItem(at: logo, to: tmp)
            if let attachment = try? UNNotificationAttachment(identifier: "logo", url: tmp) {
                content.attachments = [attachment]
            }
        }
        let req = UNNotificationRequest(
            identifier: "steam-\(game.appId)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
