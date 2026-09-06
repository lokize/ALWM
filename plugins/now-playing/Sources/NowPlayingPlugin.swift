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
        let snap = NowPlayingStore.shared.snapshot
        let progress: CGFloat? = {
            guard snap.present, let duration = snap.duration, duration > 0 else { return nil }
            return CGFloat(snap.progress)
        }()
        return NowPlayingBarChipView(
            label: NowPlayingStore.shared.barLabel,
            progress: progress,
            scale: scale,
            tooltip: NowPlayingStore.shared.tooltip
        )
    }

    public func barSignature() -> String {
        let snap = NowPlayingStore.shared.snapshot
        let title = snap.title ?? ""
        let playing = snap.isPlaying ? 1 : 0
        // Bucket progress so the chip timeline advances without rebuilding every pixel.
        let prog = Int((snap.progress * 40).rounded())
        return "np:\(playing):\(prog):\(title.hashValue):\(PluginL10n.currentCode)"
    }
}

// MARK: - Chip

private final class NowPlayingBarChipView: NSView {
    private let label: String
    private let progress: CGFloat?
    private let scale: CGFloat

    init(label: String, progress: CGFloat?, scale: CGFloat, tooltip: String) {
        self.label = label
        self.progress = progress
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
        let iconSize = max(10, 11 * scale)
        let padX = max(4, 5 * scale)
        let gap = max(3, 3.5 * scale)
        // Keep the same single-line height as other chips — progress sits as a bottom overlay
        // so the label is never clipped by the workspace-bar pill.
        let chipH = max(14, 16 * scale)
        let trackH = max(1.5, 2 * scale)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = gap
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: iconSize + 1),
            icon.heightAnchor.constraint(equalToConstant: iconSize + 1)
        ])
        row.addArrangedSubview(icon)

        let field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = .labelColor
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(field)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: progress == nil ? 0 : -0.5),
            heightAnchor.constraint(equalToConstant: chipH),
            widthAnchor.constraint(lessThanOrEqualToConstant: max(148, 164 * scale))
        ])

        guard let progress else { return }

        let track = NSView()
        track.wantsLayer = true
        track.layer?.cornerRadius = trackH / 2
        track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.cornerRadius = trackH / 2
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let clamped = min(max(progress, 0), 1)
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            track.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            track.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            track.heightAnchor.constraint(equalToConstant: trackH),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(clamped, 0.02))
        ])
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: NowPlayingPlugin())
}
