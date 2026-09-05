import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// Now Playing chip + transport/artwork popover for the ALWM workspace bar.
public final class NowPlayingPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.now-playing"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = NowPlayingStore.shared
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
        store.start()
    }

    public func unload() {
        NowPlayingStore.shared.stop()
        NowPlayingStore.shared.onChange = nil
        NowPlayingStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            NowPlayingPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        // Keep chip visible even when idle so users can open the panel.
        let scale = context?.barScale ?? 1
        return NowPlayingBarChipView(
            label: NowPlayingStore.shared.barLabel,
            scale: scale,
            tooltip: NowPlayingStore.shared.tooltip
        )
    }

    public func barSignature() -> String {
        let snap = NowPlayingStore.shared.snapshot
        let title = snap.title ?? ""
        let playing = snap.isPlaying ? 1 : 0
        return "np:\(playing):\(title.hashValue):\(PluginL10n.currentCode)"
    }
}

// MARK: - Chip

private final class NowPlayingBarChipView: NSView {
    private let label: String
    private let scale: CGFloat

    init(label: String, scale: CGFloat, tooltip: String) {
        self.label = label
        self.scale = scale
        super.init(frame: .zero)
        toolTip = tooltip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        Task { @MainActor in
            NowPlayingPanelController.toggle(relativeTo: self)
        }
    }

    private func build() {
        let fontSize = max(9, 10 * scale)
        let padX = max(5, 6 * scale)
        let field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.textColor = .labelColor
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: max(14, 16 * scale)),
            widthAnchor.constraint(lessThanOrEqualToConstant: max(160, 180 * scale))
        ])
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: NowPlayingPlugin())
}
