import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// FX + crypto quotes on the ALWM workspace bar.
public final class QuotesPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.quotes"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = QuotesStore.shared
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
        let store = QuotesStore.shared
        store.stopMonitoring()
        store.onChange = nil
        store.localeCode = { PluginL10n.currentCode }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        Task { @MainActor in
            QuotesPanelController.close()
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = QuotesStore.shared
        let scale = context?.barScale ?? 1
        return QuotesBarChipView(
            quotes: store.settings.watchlist,
            onTargetCount: store.onTarget.count,
            isChecking: store.isChecking,
            fxDecimals: store.settings.fxDecimals,
            cryptoDecimals: store.settings.cryptoDecimals,
            scale: scale,
            tooltip: store.barTooltip
        )
    }

    public func barSignature() -> String {
        let store = QuotesStore.shared
        let sig = store.settings.watchlist
            .map { "\($0.id):\($0.currentPrice.map { String(format: "%.4f", $0) } ?? "-"):\($0.change24h.map { String(format: "%.2f", $0) } ?? "")" }
            .joined(separator: ",")
        return "quotes:\(PluginL10n.currentCode):\(sig):\(store.isChecking):\(store.onTarget.count):\(store.settings.fxDecimals):\(store.settings.cryptoDecimals)"
    }
}

// MARK: - Bar chip

/// Cycles through watchlist: pair + price (badge when any target hit).
private final class QuotesBarChipView: NSView {
    private let quotes: [QuoteItem]
    private let onTargetCount: Int
    private let isChecking: Bool
    private let fxDecimals: Int
    private let cryptoDecimals: Int
    private let scale: CGFloat

    private let row = NSStackView()
    private let badgeField = NSTextField(labelWithString: "")
    private let symbolIcon = NSImageView()
    private let pairField = NSTextField(labelWithString: "")
    private let priceField = NSTextField(labelWithString: "")
    private let idleIcon = NSImageView()
    private let idleLabel = NSTextField(labelWithString: "")

    private var index = 0
    nonisolated(unsafe) private var cycleTimer: Timer?
    private var tracking: NSTrackingArea?

    init(
        quotes: [QuoteItem],
        onTargetCount: Int,
        isChecking: Bool,
        fxDecimals: Int,
        cryptoDecimals: Int,
        scale: CGFloat,
        tooltip: String
    ) {
        self.quotes = quotes
        self.onTargetCount = onTargetCount
        self.isChecking = isChecking
        self.fxDecimals = fxDecimals
        self.cryptoDecimals = cryptoDecimals
        self.scale = scale
        super.init(frame: .zero)
        toolTip = tooltip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        build()
        render(animated: false)
        if quotes.count > 1 {
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
        guard quotes.count > 1 else { return }
        startCycle()
    }

    override func mouseExited(with event: NSEvent) {
        if quotes.count > 1, index != 0 {
            index = 0
            renderQuote(animated: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let geometry = PluginPanelAnchor.geometry(of: self)
        Task { @MainActor in
            PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.quotes")
            QuotesPanelController.toggle(anchoredTo: geometry)
        }
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
            idleIcon.heightAnchor.constraint(equalToConstant: iconSide),
            symbolIcon.widthAnchor.constraint(equalToConstant: iconSide),
            symbolIcon.heightAnchor.constraint(equalToConstant: iconSide)
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

        pairField.font = .systemFont(ofSize: fontSize, weight: .semibold)
        pairField.textColor = .systemTeal
        pairField.isEditable = false
        pairField.isBezeled = false
        pairField.drawsBackground = false
        pairField.lineBreakMode = .byTruncatingTail
        pairField.maximumNumberOfLines = 1
        pairField.widthAnchor.constraint(equalToConstant: PluginBarChipLayout.titleWidth(scale: scale)).isActive = true

        priceField.font = .monospacedDigitSystemFont(ofSize: max(8, fontSize - 1), weight: .semibold)
        priceField.textColor = .labelColor
        priceField.isEditable = false
        priceField.isBezeled = false
        priceField.drawsBackground = false
        priceField.lineBreakMode = .byTruncatingTail
        priceField.maximumNumberOfLines = 1
        priceField.widthAnchor.constraint(equalToConstant: PluginBarChipLayout.subtitleWidth(scale: scale)).isActive = true

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

    private func render(animated: Bool) {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        if quotes.isEmpty {
            let symbol = NSImage(
                systemSymbolName: isChecking ? "arrow.triangle.2.circlepath" : "chart.line.uptrend.xyaxis",
                accessibilityDescription: PluginL10n.t("plugin.quotes.title")
            )
            idleIcon.image = symbol
            idleIcon.contentTintColor = .secondaryLabelColor
            let loc = PluginL10n.currentCode
            idleLabel.stringValue = isChecking
                ? PluginL10n.t("plugin.quotes.bar.checking", locale: loc)
                : PluginL10n.t("plugin.quotes.bar.idle", locale: loc)
            idleLabel.textColor = .labelColor
            row.addArrangedSubview(idleIcon)
            row.addArrangedSubview(idleLabel)
        } else {
            renderQuote(animated: animated)
        }
    }

    private func renderQuote(animated: Bool) {
        guard !quotes.isEmpty else { return }
        let item = quotes[index % quotes.count]

        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        if onTargetCount > 0 {
            badgeField.stringValue = onTargetCount > 99 ? "99+" : "\(onTargetCount)"
            row.addArrangedSubview(badgeField)
        }
        let iconName = item.kind == .fx ? "coloncurrencysign.circle.fill" : "bitcoinsign.circle.fill"
        symbolIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        symbolIcon.contentTintColor = item.kind == .fx ? .systemTeal : .systemOrange
        row.addArrangedSubview(symbolIcon)
        row.addArrangedSubview(pairField)
        row.addArrangedSubview(priceField)

        let apply = { [weak self] in
            guard let self else { return }
            self.pairField.stringValue = PluginBarChipLayout.short(item.pairLabel, max: 10)
            if let price = item.currentPrice {
                let decimals = item.kind == .fx ? self.fxDecimals : self.cryptoDecimals
                self.priceField.stringValue = QuotesFormat.compactPrice(
                    price,
                    kind: item.kind,
                    vs: item.quote,
                    decimals: decimals
                )
            } else {
                self.priceField.stringValue = self.isChecking ? "…" : "—"
            }
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
                guard let self, self.quotes.count > 1 else { return }
                self.index = (self.index + 1) % self.quotes.count
                self.renderQuote(animated: true)
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

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: QuotesPlugin())
}
