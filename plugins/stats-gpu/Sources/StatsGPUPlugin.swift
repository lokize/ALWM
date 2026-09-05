import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// GPU chip + Stats-like popover for the ALWM workspace bar.
public final class StatsGPUPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-gpu"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = GPUStore.shared
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
        GPUStore.shared.stop()
        GPUStore.shared.onChange = nil
        GPUStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            GPUPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        guard GPUStore.shared.isPresent else { return nil }
        let scale = context?.barScale ?? 1
        return GPUBarChipView(
            label: GPUStore.shared.barLabel,
            scale: scale,
            tooltip: GPUStore.shared.tooltip
        )
    }

    public func barSignature() -> String {
        let store = GPUStore.shared
        if !store.isPresent {
            return "gpu:absent:\(PluginL10n.currentCode)"
        }
        let pct = Int((store.snapshot.utilization * 100).rounded())
        return "gpu:\(pct):\(PluginL10n.currentCode)"
    }
}

// MARK: - Chip

private final class GPUBarChipView: NSView {
    private let label: String
    private let scale: CGFloat

    init(label: String, scale: CGFloat, tooltip: String) {
        self.label = label
        self.scale = scale
        super.init(frame: .zero)
        toolTip = tooltip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        Task { @MainActor in
            GPUPanelController.toggle(relativeTo: self)
        }
    }

    private func build() {
        let fontSize = max(9, 10 * scale)
        let padX = max(5, 6 * scale)
        let field = NSTextField(labelWithString: label)
        field.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        field.textColor = .labelColor
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: max(14, 16 * scale))
        ])
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsGPUPlugin())
}
