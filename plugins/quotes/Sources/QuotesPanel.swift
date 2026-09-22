import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

private final class QuotesKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum QuotesPanelController {
    private static var window: QuotesKeyPanel?

    static func close() {
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        if let window, window.isVisible {
            PluginPanelOutsideClick.stop(for: window)
            window.orderOut(nil)
            return
        }
        open(anchoredTo: geometry)
    }

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.quotes")
        let width: CGFloat = 440
        let height: CGFloat = 680
        let root = QuotesPanelView()
            .pluginLocalized()
            .frame(width: width, height: height)
        let hosting = NSHostingController(rootView: root)
        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }
        let win = QuotesKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.becomesKeyOnlyIfNeeded = false
        win.isFloatingPanel = true
        win.hidesOnDeactivate = false
        window = win
        PluginPanelAnchor.attachBeforePresenting(win, size: NSSize(width: width, height: height), to: geo)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PluginPanelAnchor.attachAfterPresenting(win, size: NSSize(width: width, height: height), to: geo)
        PluginPanelOutsideClick.watch(win)
    }
}

struct QuotesPanelView: View {
    @ObservedObject private var store = QuotesStore.shared
    @State private var addMode: AddMode = .fx
    @State private var fxBase = "USD"
    @State private var fxQuote = "BRL"
    @State private var cryptoPreset: CryptoPreset = QuotesCatalog.cryptoPresets[0]
    @State private var cryptoVs = "usd"
    @State private var editItem: QuoteItem?
    @State private var editTarget = ""

    private enum AddMode: String, CaseIterable {
        case fx, crypto
    }

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsBlock
                    addBlock
                    watchlistBlock
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 680)
        .pluginPanelChrome(cornerRadius: 14)
        .sheet(item: $editItem) { item in
            editSheet(item)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.tint)
            Text(t("plugin.quotes.title"))
                .font(.headline)
            Spacer()
            if store.isChecking {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refresh(notify: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(t("plugin.quotes.refresh.help"))
            .disabled(store.isChecking || store.settings.watchlist.isEmpty)
        }
        .padding(14)
    }

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("plugin.quotes.settings.title")).font(.subheadline.weight(.semibold))

            Text(t("plugin.common.interval_minutes"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(store.settings.checkIntervalMinutes) },
                        set: { store.setInterval(Int($0.rounded())) }
                    ),
                    in: 5...360,
                    step: 5
                )
                Text("\(store.settings.checkIntervalMinutes)")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            Text(t("plugin.common.bar_cycle_seconds"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(store.settings.barCycleSeconds) },
                        set: { store.setBarCycleSeconds(Int($0.rounded())) }
                    ),
                    in: 2...30,
                    step: 1
                )
                Text("\(store.settings.barCycleSeconds)s")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            Text(t("plugin.quotes.decimals.fx"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(store.settings.fxDecimals) },
                        set: { store.setFXDecimals(Int($0.rounded())) }
                    ),
                    in: 0...8,
                    step: 1
                )
                Text("\(store.settings.fxDecimals)")
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }

            Text(t("plugin.quotes.decimals.crypto"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(store.settings.cryptoDecimals) },
                        set: { store.setCryptoDecimals(Int($0.rounded())) }
                    ),
                    in: 0...8,
                    step: 1
                )
                Text("\(store.settings.cryptoDecimals)")
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }

            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var addBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("plugin.quotes.add.title")).font(.subheadline.weight(.semibold))

            Picker("", selection: $addMode) {
                Text(t("plugin.quotes.kind.fx")).tag(AddMode.fx)
                Text(t("plugin.quotes.kind.crypto")).tag(AddMode.crypto)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if addMode == .fx {
                HStack {
                    Picker(t("plugin.quotes.fx.base"), selection: $fxBase) {
                        ForEach(QuotesCatalog.fxCurrencies, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    .labelsHidden()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Picker(t("plugin.quotes.fx.quote"), selection: $fxQuote) {
                        ForEach(QuotesCatalog.fxCurrencies, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    .labelsHidden()
                    Button(t("plugin.quotes.add.action")) {
                        store.addFX(base: fxBase, quote: fxQuote)
                    }
                    .disabled(fxBase == fxQuote)
                }
            } else {
                HStack {
                    Picker(t("plugin.quotes.crypto.coin"), selection: $cryptoPreset) {
                        ForEach(QuotesCatalog.cryptoPresets) { p in
                            Text("\(p.symbol) — \(p.name)").tag(p)
                        }
                    }
                    .labelsHidden()
                    Picker(t("plugin.quotes.crypto.vs"), selection: $cryptoVs) {
                        ForEach(QuotesCatalog.vsCurrencies, id: \.self) { v in
                            Text(v.uppercased()).tag(v)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 72)
                    Button(t("plugin.quotes.add.action")) {
                        store.addCrypto(preset: cryptoPreset, vs: cryptoVs)
                    }
                }
            }
        }
    }

    private var watchlistBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("plugin.quotes.watchlist.title")).font(.subheadline.weight(.semibold))

            if store.settings.watchlist.isEmpty {
                Text(t("plugin.quotes.watchlist.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.settings.watchlist) { item in
                    quoteRow(item)
                }
            }
        }
    }

    private func quoteRow(_ item: QuoteItem) -> some View {
        let onTarget = item.isOnTarget
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .fx ? "coloncurrencysign.circle" : "bitcoinsign.circle")
                        .foregroundStyle(item.kind == .fx ? Color.teal : Color.orange)
                    Text(item.pairLabel)
                        .font(.subheadline.weight(.semibold))
                    if onTarget {
                        Text(t("plugin.quotes.badge.target"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                if item.kind == .crypto {
                    Text(item.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let p = item.currentPrice {
                    Text(store.formatPrice(p, kind: item.kind, vs: item.quote))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
                if let ch = item.change24h {
                    Text(QuotesFormat.change(ch))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ch >= 0 ? Color.green : Color.red)
                } else if let target = item.targetPrice {
                    Text(PluginL10n.tf(
                        "plugin.quotes.target.label",
                        locale: loc,
                        store.formatPrice(target, kind: item.kind, vs: item.quote)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                editTarget = item.targetPrice.map { String(format: "%g", $0) } ?? ""
                editItem = item
            } label: {
                Image(systemName: "target")
            }
            .buttonStyle(.borderless)
            .help(t("plugin.quotes.target.help"))
            Button(role: .destructive) {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(t("plugin.quotes.remove.help"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(onTarget ? Color.red.opacity(0.12) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(onTarget ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private func editSheet(_ item: QuoteItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PluginL10n.tf("plugin.quotes.target.sheet_title", locale: loc, item.pairLabel))
                .font(.headline)
            Text(t("plugin.quotes.target.sheet_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(t("plugin.quotes.target.placeholder"), text: $editTarget)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(t("plugin.quotes.target.clear")) {
                    store.setTarget(id: item.id, target: nil)
                    editItem = nil
                }
                Spacer()
                Button(t("plugin.common.save")) {
                    let cleaned = editTarget.replacingOccurrences(of: ",", with: ".")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.isEmpty {
                        store.setTarget(id: item.id, target: nil)
                    } else if let v = Double(cleaned), v > 0 {
                        store.setTarget(id: item.id, target: v)
                    }
                    editItem = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
