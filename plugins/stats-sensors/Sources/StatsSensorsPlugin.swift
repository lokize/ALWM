import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// Temperature sensors chip + Stats-like grouped list for the ALWM workspace bar.
public final class StatsSensorsPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-sensors"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = SensorsStore.shared
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
        SensorsStore.shared.stop()
        SensorsStore.shared.onChange = nil
        SensorsStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            SensorsPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        guard SensorsStore.shared.isPresent else { return nil }
        let scale = context?.barScale ?? 1
        return SensorsBarChipView(
            label: SensorsStore.shared.barLabel,
            scale: scale,
            tooltip: SensorsStore.shared.tooltip
        )
    }

    public func barSignature() -> String {
        let store = SensorsStore.shared
        if !store.isPresent {
            return "sens:absent:\(PluginL10n.currentCode)"
        }
        let chip = Int((store.snapshot.primaryCelsius ?? 0).rounded())
        return "sens:\(chip):\(PluginL10n.currentCode)"
    }
}

// MARK: - Chip

private final class SensorsBarChipView: NSView {
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
            SensorsPanelController.toggle(relativeTo: self)
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
    AlwmPluginExport.makeVTable(plugin: StatsSensorsPlugin())
}
