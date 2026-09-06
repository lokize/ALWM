import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// ALWM port of https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher
public final class SteamPriceWatcherPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.steam-price-watcher"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = SteamWatcherStore.shared
        store.localeCode = { [weak self] in
            if let id = self?.context?.localeIdentifier, !id.isEmpty {
                return PluginL10n.resolveCode(id)
            }
            return PluginL10n.currentCode
        }
        store.onChange = { [weak self] in
            self?.context?.requestBarRefresh()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .alwmLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.context?.requestBarRefresh()
        }
        store.startMonitoring()
    }

    public func unload() {
        let store = SteamWatcherStore.shared
        store.stopMonitoring()
        store.onChange = nil
        store.localeCode = { PluginL10n.currentCode }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        Task { @MainActor in
            SteamPanelController.close()
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = SteamWatcherStore.shared
        let scale = context?.barScale ?? 1
        return SteamBarChipView(
            hits: store.gamesOnTarget,
            watchCount: store.settings.watchlist.count,
            isChecking: store.isChecking,
            currencySymbol: store.settings.currencySymbol,
            scale: scale,
            tooltip: store.barTooltip
        )
    }

    public func barSignature() -> String {
        let store = SteamWatcherStore.shared
        let hits = store.gamesOnTarget
            .map { "\($0.appId):\($0.currentPrice.map { String(format: "%.2f", $0) } ?? "-")" }
            .joined(separator: ",")
        return "steam:\(PluginL10n.currentCode):\(hits):\(store.settings.watchlist.count):\(store.isChecking)"
    }
}

// MARK: - Bar chip

/// Bar chip: idle count, or cover + name + price (hover cycles multiple hits).
private final class SteamBarChipView: NSView {
    private let hits: [SteamGame]
    private let watchCount: Int
    private let isChecking: Bool
    private let currencySymbol: String
    private let scale: CGFloat

    private let row = NSStackView()
    private let thumb = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let priceField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private let idleIcon = NSImageView()
    private let idleLabel = NSTextField(labelWithString: "")

    private var index = 0
    nonisolated(unsafe) private var cycleTimer: Timer?
    private var tracking: NSTrackingArea?

    init(
        hits: [SteamGame],
        watchCount: Int,
        isChecking: Bool,
        currencySymbol: String,
        scale: CGFloat,
        tooltip: String
    ) {
        self.hits = hits
        self.watchCount = watchCount
        self.isChecking = isChecking
        self.currencySymbol = currencySymbol
        self.scale = scale
        super.init(frame: .zero)
        toolTip = tooltip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        build()
        renderIdleOrHit(animated: false)
        if hits.count > 1 {
            startCycle()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        cycleTimer?.invalidate()
        cycleTimer = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard hits.count > 1 else { return }
        startCycle()
    }

    override func mouseExited(with event: NSEvent) {
        if hits.count > 1, index != 0 {
            index = 0
            renderHit(animated: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        SteamPanelController.toggle(relativeTo: self)
    }

    private func build() {
        let fontSize = max(9, 10 * scale)
        let padX = max(4, 5 * scale)
        let chipW = PluginBarChipLayout.chipWidth(scale: scale)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = max(3, 3.5 * scale)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)

        idleIcon.translatesAutoresizingMaskIntoConstraints = false
        let iconSide = PluginBarChipLayout.iconSide(scale: scale)
        NSLayoutConstraint.activate([
            idleIcon.widthAnchor.constraint(equalToConstant: iconSide),
            idleIcon.heightAnchor.constraint(equalToConstant: iconSide)
        ])
        idleLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        idleLabel.textColor = .labelColor
        idleLabel.isEditable = false
        idleLabel.isBezeled = false
        idleLabel.drawsBackground = false
        idleLabel.lineBreakMode = .byTruncatingTail
        idleLabel.maximumNumberOfLines = 1
        idleLabel.widthAnchor.constraint(
            equalToConstant: PluginBarChipLayout.titleWidth(scale: scale) + PluginBarChipLayout.subtitleWidth(scale: scale)
        ).isActive = true

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 2
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        let thumbW = PluginBarChipLayout.steamThumbWidth(scale: scale)
        let thumbH = PluginBarChipLayout.steamThumbHeight(scale: scale)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: thumbW),
            thumb.heightAnchor.constraint(equalToConstant: thumbH)
        ])

        nameField.font = .systemFont(ofSize: fontSize, weight: .semibold)
        nameField.textColor = .systemTeal
        nameField.isEditable = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.widthAnchor.constraint(equalToConstant: PluginBarChipLayout.steamNameWidth(scale: scale)).isActive = true

        priceField.font = .monospacedDigitSystemFont(ofSize: max(8, fontSize - 1), weight: .semibold)
        priceField.textColor = .labelColor
        priceField.isEditable = false
        priceField.isBezeled = false
        priceField.drawsBackground = false
        priceField.lineBreakMode = .byTruncatingTail
        priceField.maximumNumberOfLines = 1
        priceField.widthAnchor.constraint(equalToConstant: PluginBarChipLayout.steamPriceWidth(scale: scale)).isActive = true

        let badgeW = PluginBarChipLayout.badgeWidth(scale: scale)
        badgeField.font = .monospacedDigitSystemFont(ofSize: max(8, fontSize - 1), weight: .bold)
        badgeField.textColor = .white
        badgeField.isEditable = false
        badgeField.isBezeled = false
        badgeField.drawsBackground = true
        badgeField.backgroundColor = .systemRed
        badgeField.wantsLayer = true
        badgeField.layer?.cornerRadius = max(5, 5.5 * scale)
        badgeField.layer?.cornerCurve = .continuous
        badgeField.alignment = .center
        badgeField.widthAnchor.constraint(equalToConstant: badgeW).isActive = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: chipW),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padX),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: max(14, 16 * scale))
        ])
    }

    private func renderIdleOrHit(animated: Bool) {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        if hits.isEmpty {
            let symbol = NSImage(
                systemSymbolName: isChecking ? "arrow.triangle.2.circlepath" : "gamecontroller.fill",
                accessibilityDescription: PluginL10n.t("plugin.steam.title")
            )
            idleIcon.image = symbol
            idleIcon.contentTintColor = .secondaryLabelColor
            let loc = PluginL10n.currentCode
            idleLabel.stringValue = isChecking
                ? PluginL10n.t("plugin.steam.bar.checking", locale: loc)
                : (watchCount == 0 ? PluginL10n.t("plugin.steam.bar.idle", locale: loc) : "\(watchCount)")
            idleLabel.textColor = .labelColor
            row.addArrangedSubview(idleIcon)
            row.addArrangedSubview(idleLabel)
        } else {
            renderHit(animated: animated)
        }
    }

    private func renderHit(animated: Bool) {
        guard !hits.isEmpty else { return }
        let game = hits[index % hits.count]

        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        badgeField.stringValue = hits.count > 99 ? "99+" : "\(hits.count)"
        badgeField.alphaValue = 1
        row.addArrangedSubview(badgeField)
        row.addArrangedSubview(thumb)
        row.addArrangedSubview(nameField)
        row.addArrangedSubview(priceField)

        let apply = { [weak self] in
            guard let self else { return }
            self.nameField.stringValue = PluginBarChipLayout.short(game.name, max: 12)
            if let price = game.currentPrice {
                self.priceField.stringValue = String(format: "%@ %.2f", self.currencySymbol, price)
            } else {
                self.priceField.stringValue = "—"
            }
            SteamCapsuleCache.load(appId: game.appId, into: self.thumb)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                row.animator().alphaValue = 0.15
            } completionHandler: { [weak self] in
                apply()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    self?.row.animator().alphaValue = 1
                }
            }
        } else {
            row.alphaValue = 1
            apply()
        }
    }

    private func startCycle() {
        stopCycle()
        let t = Timer(timeInterval: PluginBarChipLayout.cycleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hits.count > 1 else { return }
                self.index = (self.index + 1) % self.hits.count
                self.renderHit(animated: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        cycleTimer = t
    }

    private func stopCycle() {
        cycleTimer?.invalidate()
        cycleTimer = nil
    }
}

// MARK: - Capsule image cache

private enum SteamCapsuleCache {
    nonisolated(unsafe) private static var memory: [Int: NSImage] = [:]
    nonisolated(unsafe) private static var inflight: Set<Int> = []

    static func load(appId: Int, into imageView: NSImageView) {
        if let img = memory[appId] {
            imageView.image = img
            return
        }
        imageView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
        imageView.contentTintColor = .systemTeal
        guard !inflight.contains(appId) else { return }
        inflight.insert(appId)
        let url = SteamStoreAPI.capsuleURL(appId: appId)
        Task.detached {
            let data = try? await URLSession.shared.data(from: url).0
            let img = data.flatMap { NSImage(data: $0) }
            await MainActor.run {
                inflight.remove(appId)
                guard let img else { return }
                memory[appId] = img
                imageView.image = img
                imageView.contentTintColor = nil
            }
        }
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: SteamPriceWatcherPlugin())
}
