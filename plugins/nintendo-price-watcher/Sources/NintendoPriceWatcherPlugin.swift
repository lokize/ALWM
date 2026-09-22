import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// Nintendo eShop price watcher via Deku Deals (same UX as Steam Price Watcher).
public final class NintendoPriceWatcherPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.nintendo-price-watcher"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = NintendoWatcherStore.shared
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
        let store = NintendoWatcherStore.shared
        store.stopMonitoring()
        store.onChange = nil
        store.localeCode = { PluginL10n.currentCode }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        Task { @MainActor in
            NintendoPanelController.close()
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = NintendoWatcherStore.shared
        let scale = context?.barScale ?? 1
        return NintendoBarChipView(
            game: store.barGame,
            cycleCount: store.barCycleGames.count,
            onTargetCount: store.gamesOnTarget.count,
            watchCount: store.settings.watchlist.count,
            isChecking: store.isChecking,
            currencySymbol: store.settings.currencySymbol,
            scale: scale,
            tooltip: store.barTooltip
        )
    }

    public func barSignature() -> String {
        let store = NintendoWatcherStore.shared
        let g = store.barGame
        let price = g?.currentPrice.map { String(format: "%.2f", $0) } ?? "-"
        return "nintendo:\(PluginL10n.currentCode):\(store.barCycleIndex):\(g?.slug ?? ""):\(price):\(store.barCycleGames.count):\(store.gamesOnTarget.count):\(store.isChecking):\(store.settings.barCycleSeconds)"
    }
}

// MARK: - Bar chip

/// Rotating watchlist / on-target game (store advances every few seconds).
private final class NintendoBarChipView: NSView {
    private let game: NintendoGame?
    private let cycleCount: Int
    private let onTargetCount: Int
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

    init(
        game: NintendoGame?,
        cycleCount: Int,
        onTargetCount: Int,
        watchCount: Int,
        isChecking: Bool,
        currencySymbol: String,
        scale: CGFloat,
        tooltip: String
    ) {
        self.game = game
        self.cycleCount = cycleCount
        self.onTargetCount = onTargetCount
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
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let geometry = PluginPanelAnchor.geometry(of: self)
        Task { @MainActor in
            PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.nintendo-price-watcher")
            NintendoPanelController.toggle(anchoredTo: geometry)
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
        thumb.layer?.cornerRadius = 3
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        let thumbW = PluginBarChipLayout.nintendoThumbWidth(scale: scale)
        let thumbH = PluginBarChipLayout.nintendoThumbHeight(scale: scale)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: thumbW),
            thumb.heightAnchor.constraint(equalToConstant: thumbH)
        ])

        nameField.font = .systemFont(ofSize: fontSize, weight: .semibold)
        nameField.textColor = .systemRed
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

    private func render() {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }

        guard let game else {
            let symbol = NSImage(
                systemSymbolName: isChecking ? "arrow.triangle.2.circlepath" : "gamecontroller.fill",
                accessibilityDescription: PluginL10n.t("plugin.nintendo.title")
            )
            idleIcon.image = symbol
            idleIcon.contentTintColor = .secondaryLabelColor
            let loc = PluginL10n.currentCode
            idleLabel.stringValue = isChecking
                ? PluginL10n.t("plugin.nintendo.bar.checking", locale: loc)
                : (watchCount == 0 ? PluginL10n.t("plugin.nintendo.bar.idle", locale: loc) : "\(watchCount)")
            idleLabel.textColor = .labelColor
            row.addArrangedSubview(idleIcon)
            row.addArrangedSubview(idleLabel)
            return
        }

        if onTargetCount > 0 {
            badgeField.stringValue = onTargetCount > 99 ? "99+" : "\(onTargetCount)"
            row.addArrangedSubview(badgeField)
        }
        row.addArrangedSubview(thumb)
        row.addArrangedSubview(nameField)
        row.addArrangedSubview(priceField)

        nameField.stringValue = PluginBarChipLayout.short(game.name, max: 12)
        if let price = game.currentPrice {
            priceField.stringValue = String(format: "%@ %.2f", currencySymbol, price)
        } else {
            priceField.stringValue = isChecking ? "…" : "—"
        }
        NintendoCoverCache.load(
            urlString: game.imageURL,
            into: thumb,
            targetSize: NSSize(
                width: PluginBarChipLayout.nintendoThumbWidth(scale: scale),
                height: PluginBarChipLayout.nintendoThumbHeight(scale: scale)
            )
        )
        _ = cycleCount
    }
}

// MARK: - Cover image cache

private enum NintendoCoverCache {
    nonisolated(unsafe) private static var memory: [String: NSImage] = [:]
    nonisolated(unsafe) private static var inflight: Set<String> = []

    static func load(urlString: String?, into imageView: NSImageView, targetSize: NSSize) {
        guard let urlString, let url = URL(string: urlString) else {
            imageView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
            imageView.contentTintColor = .systemRed
            return
        }
        let cacheKey = "\(urlString)|\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let img = memory[cacheKey] {
            imageView.image = img
            imageView.contentTintColor = nil
            return
        }
        imageView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
        imageView.contentTintColor = .systemRed
        guard !inflight.contains(cacheKey) else { return }
        inflight.insert(cacheKey)
        Task.detached {
            let data = try? await URLSession.shared.data(from: url).0
            let raw = data.flatMap { NSImage(data: $0) }
            let filled = raw.map { aspectFill($0, size: targetSize) }
            await MainActor.run {
                inflight.remove(cacheKey)
                guard let filled else { return }
                memory[cacheKey] = filled
                imageView.image = filled
                imageView.contentTintColor = nil
            }
        }
    }

    /// Crop-zoom so box art / logos fill the bar thumb (Steam capsules already do).
    private nonisolated static func aspectFill(_ image: NSImage, size: NSSize) -> NSImage {
        let src = image.size
        guard src.width > 0, src.height > 0, size.width > 0, size.height > 0 else { return image }
        let scale = max(size.width / src.width, size.height / src.height)
        let scaled = NSSize(width: src.width * scale, height: src.height * scale)
        let origin = NSPoint(
            x: (size.width - scaled.width) / 2,
            y: (size.height - scaled.height) / 2
        )
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: origin, size: scaled),
            from: NSRect(origin: .zero, size: src),
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: NintendoPriceWatcherPlugin())
}
