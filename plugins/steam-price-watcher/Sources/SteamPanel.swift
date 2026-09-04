import AppKit
import SwiftUI
import AlwmL10n

@MainActor
enum SteamPanelController {
    private static var window: NSWindow?

    static func close() {
        window?.orderOut(nil)
    }

    static func toggle(relativeTo view: NSView?) {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        open(relativeTo: view)
    }

    static func open(relativeTo view: NSView?) {
        let store = SteamWatcherStore.shared
        let root = SteamPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let win = window ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.title = PluginL10n.t("plugin.steam.title", locale: store.localeCode())
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 380, height: 460)

        if let view, let screen = view.window?.screen ?? NSScreen.main {
            let rect = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
                ?? NSRect(x: screen.visibleFrame.midX - 230, y: screen.visibleFrame.midY - 310, width: 1, height: 1)
            var origin = NSPoint(x: rect.midX - 230, y: rect.minY - 640)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - 470)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 12), screen.visibleFrame.maxY - 480)
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct SteamPanelView: View {
    @ObservedObject private var store = SteamWatcherStore.shared
    @State private var query = ""
    @State private var searching = false
    @State private var results: [SteamSearchHit] = []
    @State private var pendingHit: SteamSearchHit?
    @State private var pendingPrice: Double?
    @State private var targetText = ""
    @State private var editGame: SteamGame?
    @State private var editTarget = ""
    @State private var importMessage: String?

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsBlock
                    searchBlock
                    watchlistBlock
                }
                .padding(16)
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .sheet(item: $pendingHit) { hit in
            addSheet(hit)
        }
        .sheet(item: $editGame) { game in
            editSheet(game)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(.tint)
            Text(t("plugin.steam.title"))
                .font(.headline)
            Spacer()
            if store.isChecking {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refreshPrices(notify: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(t("plugin.steam.refresh.help"))
            .disabled(store.isChecking || store.settings.watchlist.isEmpty)
        }
        .padding(14)
    }

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("plugin.steam.settings.title")).font(.subheadline.weight(.semibold))

            Text(t("plugin.common.interval_minutes"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(store.settings.checkIntervalMinutes) },
                        set: { store.setInterval(Int($0.rounded())) }
                    ),
                    in: 15...1440,
                    step: 15
                )
                Text("\(store.settings.checkIntervalMinutes)")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            Text(t("plugin.steam.currency"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(
                "",
                selection: Binding(
                    get: { store.settings.currency },
                    set: { store.setCurrency($0) }
                )
            ) {
                ForEach(SteamCurrency.allCases) { cur in
                    Text(cur.label).tag(cur.rawValue)
                }
            }
            .labelsHidden()

            HStack {
                Button(t("plugin.steam.import.noctalia")) {
                    let n = store.importFromNoctalia()
                    importMessage = n > 0
                        ? PluginL10n.tf("plugin.steam.import.success", locale: loc, n)
                        : t("plugin.steam.import.empty")
                }
                .controlSize(.small)
                Spacer()
            }
            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var searchBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("plugin.steam.search.title")).font(.subheadline.weight(.semibold))
            HStack {
                TextField(t("plugin.steam.search.placeholder"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await runSearch() } }
                Button(t("plugin.steam.search.button")) { Task { await runSearch() } }
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if searching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t("plugin.steam.search.loading")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(results) { hit in
                HStack(spacing: 10) {
                    SteamCapsule(appId: hit.appId)
                        .frame(width: 92, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name).lineLimit(1)
                        if let price = hit.price {
                            Text("\(store.settings.currencySymbol) \(price, specifier: "%.2f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(PluginL10n.tf("plugin.steam.app_id", hit.appId))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let already = store.settings.watchlist.contains(where: { $0.appId == hit.appId })
                    Button(already ? t("plugin.steam.in_list") : t("plugin.steam.add")) {
                        Task { await prepareAdd(hit) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(already)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var watchlistBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PluginL10n.tf("plugin.steam.watchlist.title", locale: loc, store.settings.watchlist.count))
                .font(.subheadline.weight(.semibold))
            if store.settings.watchlist.isEmpty {
                Text(t("plugin.steam.watchlist.empty"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(sortedGames) { game in
                    gameRow(game)
                }
            }
        }
    }

    private var sortedGames: [SteamGame] {
        store.settings.watchlist.sorted { a, b in
            if a.isOnTarget != b.isOnTarget { return a.isOnTarget && !b.isOnTarget }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func gameRow(_ game: SteamGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SteamCapsule(appId: game.appId)
                    .frame(width: 92, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if game.isOnTarget {
                            Image(systemName: "scope")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(game.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                    }
                    Text(PluginL10n.tf("plugin.steam.target", locale: loc, store.settings.currencySymbol, game.targetPrice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let price = game.currentPrice {
                        Text("\(store.settings.currencySymbol) \(price, specifier: "%.2f")")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(game.isOnTarget ? Color.accentColor : .primary)
                        if let d = game.discountPercent, d > 0 {
                            Text("-\(d)%")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        if game.isOnTarget {
                            let saved = ((game.targetPrice - price) / max(game.targetPrice, 0.01) * 100)
                            Text(PluginL10n.tf("plugin.steam.below_target", locale: loc, saved))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(t("plugin.steam.edit_target")) {
                    editTarget = String(format: "%.2f", game.targetPrice)
                    editGame = game
                }
                .controlSize(.small)
                Button(t("plugin.steam.open_steam")) {
                    if let url = URL(string: "https://store.steampowered.com/app/\(game.appId)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Spacer()
                Button(role: .destructive) {
                    store.removeGame(appId: game.appId)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(game.isOnTarget ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(game.isOnTarget ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private func addSheet(_ hit: SteamSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("plugin.steam.add_sheet.title")).font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                SteamCapsule(appId: hit.appId).frame(width: 92, height: 34)
                Text(hit.name).font(.headline)
            }
            if let pendingPrice {
                Text(PluginL10n.tf("plugin.steam.add_sheet.current_price", locale: loc, store.settings.currencySymbol, pendingPrice))
                    .foregroundStyle(.secondary)
            } else {
                Text(t("plugin.steam.add_sheet.no_price"))
                    .foregroundStyle(.secondary)
            }
            TextField(PluginL10n.tf("plugin.steam.add_sheet.target_field", locale: loc, store.settings.currencySymbol), text: $targetText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(PluginL10n.t("common.cancel", locale: loc)) { pendingHit = nil }
                Button(t("plugin.steam.add")) {
                    let target = Double(targetText.replacingOccurrences(of: ",", with: "."))
                        ?? (pendingPrice ?? 0) * 0.8
                    store.addGame(hit, targetPrice: target, currentPrice: pendingPrice)
                    pendingHit = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pendingPrice == nil && (Double(targetText.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func editSheet(_ game: SteamGame) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("plugin.steam.edit_sheet.title")).font(.title3.weight(.semibold))
            Text(game.name)
            TextField(PluginL10n.tf("plugin.steam.add_sheet.target_field", locale: loc, store.settings.currencySymbol), text: $editTarget)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(PluginL10n.t("common.cancel", locale: loc)) { editGame = nil }
                Button(PluginL10n.t("plugin.common.save", locale: loc)) {
                    if let v = Double(editTarget.replacingOccurrences(of: ",", with: ".")) {
                        store.updateTarget(appId: game.appId, targetPrice: v)
                    }
                    editGame = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func runSearch() async {
        searching = true
        defer { searching = false }
        do {
            results = try await SteamStoreAPI.searchWithPrices(
                name: query,
                currency: store.settings.currency
            )
        } catch {
            results = []
            store.setError(error.localizedDescription)
        }
    }

    private func prepareAdd(_ hit: SteamSearchHit) async {
        var price = hit.price
        if price == nil {
            price = try? await SteamStoreAPI.fetchPrice(appId: hit.appId, currency: store.settings.currency).price
        }
        pendingPrice = price
        targetText = price.map { String(format: "%.2f", $0 * 0.8) } ?? "0.00"
        pendingHit = hit
    }
}

private struct SteamCapsule: View {
    let appId: Int

    var body: some View {
        AsyncImage(url: SteamStoreAPI.capsuleURL(appId: appId)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                placeholder
            case .empty:
                ProgressView().controlSize(.mini)
            @unknown default:
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        Image(systemName: "gamecontroller")
            .foregroundStyle(.secondary)
    }
}
