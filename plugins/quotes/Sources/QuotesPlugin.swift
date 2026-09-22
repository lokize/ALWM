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
            quote: store.barQuote,
            watchCount: store.settings.watchlist.count,
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
        let q = store.barQuote
        let price = q?.currentPrice.map { String(format: "%.6f", $0) } ?? "-"
        return "quotes:\(PluginL10n.currentCode):\(store.barCycleIndex):\(q?.id ?? ""):\(price):\(store.settings.watchlist.count):\(store.isChecking):\(store.onTarget.count):\(store.settings.fxDecimals):\(store.settings.cryptoDecimals)"
    }
}

// MARK: - Bar chip

/// Shows the current rotating quote from the store (store advances every few seconds).
private final class QuotesBarChipView: NSView {
    private let quote: QuoteItem?
    private let watchCount: Int
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

    init(
        quote: QuoteItem?,
        watchCount: Int,
        onTargetCount: Int,
        isChecking: Bool,
        fxDecimals: Int,
        cryptoDecimals: Int,
        scale: CGFloat,
        tooltip: String
    ) {
        self.quote = quote
        self.watchCount = watchCount
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
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    private func render() {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }

        guard let item = quote else {
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
            return
        }

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

        pairField.stringValue = PluginBarChipLayout.short(item.pairLabel, max: 10)
        if let price = item.currentPrice {
            let decimals = item.kind == .fx ? fxDecimals : cryptoDecimals
            priceField.stringValue = QuotesFormat.compactPrice(
                price,
                kind: item.kind,
                vs: item.quote,
                decimals: decimals
            )
        } else {
            priceField.stringValue = isChecking ? "…" : "—"
        }
        _ = watchCount
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: QuotesPlugin())
}
