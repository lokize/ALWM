import AppKit
import Foundation
import UserNotifications
import AlwmL10n

// MARK: - Models

enum QuoteKind: String, Codable, Sendable, CaseIterable {
    case fx
    case crypto
}

struct QuoteItem: Codable, Equatable, Identifiable, Sendable, Hashable {
    var id: String
    var kind: QuoteKind
    /// FX: ISO base (USD). Crypto: CoinGecko id (bitcoin).
    var base: String
    /// FX: ISO quote (BRL). Crypto: vs currency (usd, brl).
    var quote: String
    /// Display ticker: USD, BTC, …
    var symbol: String
    var name: String
    var targetPrice: Double?
    var currentPrice: Double?
    var change24h: Double?
    var addedDate: Date

    var pairLabel: String {
        switch kind {
        case .fx: return "\(symbol)/\(quote.uppercased())"
        case .crypto: return "\(symbol)/\(quote.uppercased())"
        }
    }

    var isOnTarget: Bool {
        guard let currentPrice, let targetPrice else { return false }
        return currentPrice <= targetPrice
    }

    static func fx(base: String, quote: String) -> QuoteItem {
        let b = base.uppercased()
        let q = quote.uppercased()
        return QuoteItem(
            id: "fx:\(b)/\(q)",
            kind: .fx,
            base: b,
            quote: q,
            symbol: b,
            name: "\(b)/\(q)",
            targetPrice: nil,
            currentPrice: nil,
            change24h: nil,
            addedDate: Date()
        )
    }

    static func crypto(coinId: String, symbol: String, name: String, vs: String) -> QuoteItem {
        let v = vs.lowercased()
        return QuoteItem(
            id: "crypto:\(coinId):\(v)",
            kind: .crypto,
            base: coinId,
            quote: v,
            symbol: symbol.uppercased(),
            name: name,
            targetPrice: nil,
            currentPrice: nil,
            change24h: nil,
            addedDate: Date()
        )
    }
}

struct QuotesSettings: Codable, Equatable, Sendable {
    var watchlist: [QuoteItem]
    var checkIntervalMinutes: Int
    var notifiedIDs: [String]
    /// Preferred display currency for crypto presets (usd / brl / eur).
    var preferredVs: String
    /// Decimal places for FX pairs (0…8).
    var fxDecimals: Int
    /// Decimal places for crypto (0…8).
    var cryptoDecimals: Int

    static let `default` = QuotesSettings(
        watchlist: [
            .fx(base: "USD", quote: "BRL"),
            .fx(base: "EUR", quote: "BRL"),
            .crypto(coinId: "bitcoin", symbol: "BTC", name: "Bitcoin", vs: "usd"),
            .crypto(coinId: "ethereum", symbol: "ETH", name: "Ethereum", vs: "usd")
        ],
        checkIntervalMinutes: 30,
        notifiedIDs: [],
        preferredVs: "usd",
        fxDecimals: 4,
        cryptoDecimals: 2
    )

    enum CodingKeys: String, CodingKey {
        case watchlist, checkIntervalMinutes, notifiedIDs, preferredVs, fxDecimals, cryptoDecimals
    }

    init(
        watchlist: [QuoteItem],
        checkIntervalMinutes: Int,
        notifiedIDs: [String],
        preferredVs: String,
        fxDecimals: Int,
        cryptoDecimals: Int
    ) {
        self.watchlist = watchlist
        self.checkIntervalMinutes = checkIntervalMinutes
        self.notifiedIDs = notifiedIDs
        self.preferredVs = preferredVs
        self.fxDecimals = fxDecimals
        self.cryptoDecimals = cryptoDecimals
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchlist = try c.decodeIfPresent([QuoteItem].self, forKey: .watchlist) ?? Self.default.watchlist
        checkIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .checkIntervalMinutes) ?? 30
        notifiedIDs = try c.decodeIfPresent([String].self, forKey: .notifiedIDs) ?? []
        preferredVs = try c.decodeIfPresent(String.self, forKey: .preferredVs) ?? "usd"
        fxDecimals = min(8, max(0, try c.decodeIfPresent(Int.self, forKey: .fxDecimals) ?? 4))
        cryptoDecimals = min(8, max(0, try c.decodeIfPresent(Int.self, forKey: .cryptoDecimals) ?? 2))
    }
}

struct CryptoPreset: Identifiable, Hashable, Sendable {
    var id: String { coinId }
    var coinId: String
    var symbol: String
    var name: String
}

enum QuotesCatalog {
    static let fxCurrencies = [
        "USD", "EUR", "GBP", "BRL", "JPY", "CAD", "AUD", "CHF", "MXN", "CNY", "INR", "KRW", "SEK", "NOK", "NZD", "ZAR"
    ]

    static let cryptoPresets: [CryptoPreset] = [
        .init(coinId: "bitcoin", symbol: "BTC", name: "Bitcoin"),
        .init(coinId: "ethereum", symbol: "ETH", name: "Ethereum"),
        .init(coinId: "solana", symbol: "SOL", name: "Solana"),
        .init(coinId: "binancecoin", symbol: "BNB", name: "BNB"),
        .init(coinId: "ripple", symbol: "XRP", name: "XRP"),
        .init(coinId: "cardano", symbol: "ADA", name: "Cardano"),
        .init(coinId: "dogecoin", symbol: "DOGE", name: "Dogecoin"),
        .init(coinId: "polkadot", symbol: "DOT", name: "Polkadot"),
        .init(coinId: "avalanche-2", symbol: "AVAX", name: "Avalanche"),
        .init(coinId: "chainlink", symbol: "LINK", name: "Chainlink"),
        .init(coinId: "litecoin", symbol: "LTC", name: "Litecoin"),
        .init(coinId: "toncoin", symbol: "TON", name: "Toncoin")
    ]

    static let vsCurrencies = ["usd", "brl", "eur", "gbp", "jpy"]
}

// MARK: - APIs

enum QuotesAPI {
    /// Frankfurter (ECB) — free FX, no key.
    static func fetchFX(base: String, quote: String) async throws -> Double {
        let b = base.uppercased()
        let q = quote.uppercased()
        if b == q { return 1 }
        let url = URL(string: "https://api.frankfurter.app/latest?from=\(b)&to=\(q)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = root["rates"] as? [String: Any]
        else {
            throw URLError(.cannotParseResponse)
        }
        if let d = rates[q] as? Double { return d }
        if let n = rates[q] as? NSNumber { return n.doubleValue }
        throw URLError(.cannotParseResponse)
    }

    /// Batch FX rates for several pairs sharing a base, falling back per-pair.
    static func fetchFXBatch(pairs: [(base: String, quote: String)]) async -> [String: Double] {
        var out: [String: Double] = [:]
        let grouped = Dictionary(grouping: pairs, by: { $0.base.uppercased() })
        for (base, list) in grouped {
            let quotes = Array(Set(list.map { $0.quote.uppercased() }.filter { $0 != base }))
            guard !quotes.isEmpty else {
                for p in list where p.base.uppercased() == p.quote.uppercased() {
                    out["\(base)/\(p.quote.uppercased())"] = 1
                }
                continue
            }
            let joined = quotes.joined(separator: ",")
            let url = URL(string: "https://api.frankfurter.app/latest?from=\(base)&to=\(joined)")!
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rates = root["rates"] as? [String: Any]
                else { throw URLError(.badServerResponse) }
                for q in quotes {
                    if let d = rates[q] as? Double {
                        out["\(base)/\(q)"] = d
                    } else if let n = rates[q] as? NSNumber {
                        out["\(base)/\(q)"] = n.doubleValue
                    }
                }
            } catch {
                for p in list {
                    if let v = try? await fetchFX(base: p.base, quote: p.quote) {
                        out["\(p.base.uppercased())/\(p.quote.uppercased())"] = v
                    }
                }
            }
        }
        return out
    }

    /// CoinGecko simple/price — free, no key (rate-limited).
    static func fetchCrypto(
        ids: [String],
        vs: [String]
    ) async throws -> [String: [String: Double]] {
        let uniqueIds = Array(Set(ids.map { $0.lowercased() })).sorted()
        let uniqueVs = Array(Set(vs.map { $0.lowercased() })).sorted()
        guard !uniqueIds.isEmpty, !uniqueVs.isEmpty else { return [:] }
        let idParam = uniqueIds.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let vsParam = uniqueVs.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(idParam)&vs_currencies=\(vsParam)&include_24hr_change=true")!
        var request = URLRequest(url: url)
        request.setValue("ALWM-Quotes/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        var out: [String: [String: Double]] = [:]
        for (coinId, fields) in root {
            var map: [String: Double] = [:]
            for (k, v) in fields {
                if let d = v as? Double {
                    map[k] = d
                } else if let n = v as? NSNumber {
                    map[k] = n.doubleValue
                }
            }
            out[coinId] = map
        }
        return out
    }
}

// MARK: - Formatting

enum QuotesFormat {
    static func price(_ value: Double, kind: QuoteKind, vs: String, decimals: Int) -> String {
        let places = max(0, min(8, decimals))
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = places
        fmt.maximumFractionDigits = places
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        let num = fmt.string(from: NSNumber(value: value)) ?? String(format: "%.\(places)f", value)
        return "\(currencyPrefix(vs))\(num)"
    }

    static func compactPrice(_ value: Double, kind: QuoteKind, vs: String, decimals: Int) -> String {
        let absV = abs(value)
        // Keep chip short for very large numbers, still honour decimals when possible.
        if absV >= 1_000_000 {
            let places = min(1, max(0, decimals))
            return "\(currencyPrefix(vs))\(String(format: "%.\(places)fM", value / 1_000_000))"
        }
        if absV >= 100_000, decimals == 0 {
            return "\(currencyPrefix(vs))\(String(format: "%.0f", value))"
        }
        if absV >= 10_000, decimals <= 1 {
            return "\(currencyPrefix(vs))\(String(format: "%.1fk", value / 1000))"
        }
        return price(value, kind: kind, vs: vs, decimals: decimals)
    }

    static func change(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return String(format: "%@%.2f%%", sign, pct)
    }

    static func currencyPrefix(_ vs: String) -> String {
        switch vs.lowercased() {
        case "usd", "us": return "$"
        case "brl", "br": return "R$"
        case "eur", "eu": return "€"
        case "gbp", "gb": return "£"
        case "jpy", "jp": return "¥"
        default: return "\(vs.uppercased()) "
        }
    }
}

// MARK: - Store

final class QuotesStore: ObservableObject, @unchecked Sendable {
    static let shared = QuotesStore()

    @Published private(set) var settings: QuotesSettings = .default
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?
    /// Rotating index for the bar chip (cycles through watchlist).
    @Published private(set) var barCycleIndex: Int = 0

    private let url: URL
    private var timer: Timer?
    private var barCycleTimer: Timer?
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
        url = dir.appendingPathComponent("dev.alwm.quotes.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            settings = .default
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(QuotesSettings.self, from: data) {
            settings = decoded
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
        clampBarCycle()
        restartBarCycle()
        emitChange()
    }

    func startMonitoring() {
        QuotesNotifier.requestAuthorization()
        restartTimer()
        restartBarCycle()
        Task { await refresh(notify: true) }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        barCycleTimer?.invalidate()
        barCycleTimer = nil
    }

    func setInterval(_ minutes: Int) {
        settings.checkIntervalMinutes = min(1440, max(5, minutes))
        save()
        restartTimer()
    }

    func setPreferredVs(_ vs: String) {
        settings.preferredVs = vs.lowercased()
        save()
    }

    func setFXDecimals(_ n: Int) {
        settings.fxDecimals = min(8, max(0, n))
        save()
    }

    func setCryptoDecimals(_ n: Int) {
        settings.cryptoDecimals = min(8, max(0, n))
        save()
    }

    func decimals(for kind: QuoteKind) -> Int {
        kind == .fx ? settings.fxDecimals : settings.cryptoDecimals
    }

    func formatPrice(_ value: Double, kind: QuoteKind, vs: String) -> String {
        QuotesFormat.price(value, kind: kind, vs: vs, decimals: decimals(for: kind))
    }

    func formatCompact(_ value: Double, kind: QuoteKind, vs: String) -> String {
        QuotesFormat.compactPrice(value, kind: kind, vs: vs, decimals: decimals(for: kind))
    }

    func addFX(base: String, quote: String) {
        let item = QuoteItem.fx(base: base, quote: quote)
        guard !settings.watchlist.contains(where: { $0.id == item.id }) else { return }
        settings.watchlist.append(item)
        save()
        Task { await refresh(notify: false) }
    }

    func addCrypto(preset: CryptoPreset, vs: String? = nil) {
        let v = (vs ?? settings.preferredVs).lowercased()
        let item = QuoteItem.crypto(coinId: preset.coinId, symbol: preset.symbol, name: preset.name, vs: v)
        guard !settings.watchlist.contains(where: { $0.id == item.id }) else { return }
        settings.watchlist.append(item)
        save()
        Task { await refresh(notify: false) }
    }

    func remove(id: String) {
        settings.watchlist.removeAll { $0.id == id }
        settings.notifiedIDs.removeAll { $0 == id }
        save()
    }

    func setTarget(id: String, target: Double?) {
        guard let idx = settings.watchlist.firstIndex(where: { $0.id == id }) else { return }
        settings.watchlist[idx].targetPrice = target
        settings.notifiedIDs.removeAll { $0 == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        settings.watchlist.move(fromOffsets: source, toOffset: destination)
        save()
    }

    var onTarget: [QuoteItem] { settings.watchlist.filter(\.isOnTarget) }

    /// Quote currently shown on the bar chip.
    var barQuote: QuoteItem? {
        let list = settings.watchlist
        guard !list.isEmpty else { return nil }
        return list[barCycleIndex % list.count]
    }

    func advanceBarCycle() {
        let n = settings.watchlist.count
        guard n > 1 else { return }
        barCycleIndex = (barCycleIndex + 1) % n
        emitChange()
    }

    private func clampBarCycle() {
        let n = settings.watchlist.count
        if n == 0 {
            barCycleIndex = 0
        } else {
            barCycleIndex = barCycleIndex % n
        }
    }

    private func restartBarCycle() {
        barCycleTimer?.invalidate()
        barCycleTimer = nil
        clampBarCycle()
        guard settings.watchlist.count > 1 else { return }
        let t = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.advanceBarCycle()
        }
        RunLoop.main.add(t, forMode: .common)
        barCycleTimer = t
    }

    var barTooltip: String {
        if settings.watchlist.isEmpty { return t("plugin.quotes.tooltip.empty") }
        var lines: [String] = []
        for q in settings.watchlist.prefix(8) {
            if let p = q.currentPrice {
                let price = QuotesFormat.price(p, kind: q.kind, vs: q.quote, decimals: decimals(for: q.kind))
                var line = "• \(q.pairLabel) \(price)"
                if let ch = q.change24h {
                    line += " (\(QuotesFormat.change(ch)))"
                }
                lines.append(line)
            } else {
                lines.append("• \(q.pairLabel) —")
            }
        }
        if !onTarget.isEmpty {
            lines.insert(t("plugin.quotes.tooltip.on_target_header"), at: 0)
        }
        lines.append(t("plugin.common.click_to_open"))
        return lines.joined(separator: "\n")
    }

    func refresh(notify: Bool) async {
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
            lastRefresh = Date()
            emitChange()
        }

        var updated = settings.watchlist
        let fxPairs = updated.filter { $0.kind == .fx }.map { (base: $0.base, quote: $0.quote) }
        let fxRates = await QuotesAPI.fetchFXBatch(pairs: fxPairs)

        let cryptos = updated.filter { $0.kind == .crypto }
        var cryptoMap: [String: [String: Double]] = [:]
        if !cryptos.isEmpty {
            do {
                cryptoMap = try await QuotesAPI.fetchCrypto(
                    ids: cryptos.map(\.base),
                    vs: cryptos.map(\.quote)
                )
            } catch {
                lastError = error.localizedDescription
            }
        }

        var newlyHit: [QuoteItem] = []
        for i in updated.indices {
            switch updated[i].kind {
            case .fx:
                let key = "\(updated[i].base.uppercased())/\(updated[i].quote.uppercased())"
                if let rate = fxRates[key] {
                    updated[i].currentPrice = rate
                    updated[i].change24h = nil
                } else if lastError == nil {
                    lastError = t("plugin.quotes.error.fx")
                }
            case .crypto:
                if let fields = cryptoMap[updated[i].base.lowercased()] {
                    let vs = updated[i].quote.lowercased()
                    if let price = fields[vs] {
                        updated[i].currentPrice = price
                    }
                    if let ch = fields["\(vs)_24h_change"] {
                        updated[i].change24h = ch
                    }
                }
            }
            if updated[i].isOnTarget {
                newlyHit.append(updated[i])
            }
        }

        settings.watchlist = updated
        save()

        guard notify else { return }
        let locale = loc()
        for item in newlyHit where !settings.notifiedIDs.contains(item.id) {
            QuotesNotifier.notify(item: item, locale: locale)
            settings.notifiedIDs.append(item.id)
        }
        save()
    }

    private func restartTimer() {
        timer?.invalidate()
        let minutes = Double(max(5, settings.checkIntervalMinutes))
        let t = Timer(timeInterval: minutes * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh(notify: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Notifications

enum QuotesNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(item: QuoteItem, locale: String) {
        guard let price = item.currentPrice, let target = item.targetPrice else { return }
        let content = UNMutableNotificationContent()
        content.title = PluginL10n.t("plugin.quotes.notify.title", locale: locale)
        let priceStr = QuotesFormat.price(price, kind: item.kind, vs: item.quote, decimals: QuotesStore.shared.decimals(for: item.kind))
        let targetStr = QuotesFormat.price(target, kind: item.kind, vs: item.quote, decimals: QuotesStore.shared.decimals(for: item.kind))
        content.body = PluginL10n.tf(
            "plugin.quotes.notify.body",
            locale: locale,
            item.pairLabel,
            priceStr,
            targetStr
        )
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "quotes-\(item.id)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
