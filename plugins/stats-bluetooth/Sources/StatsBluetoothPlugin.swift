import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

/// Bluetooth devices chip + Stats-like battery cards for the ALWM workspace bar.
public final class StatsBluetoothPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-bluetooth"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = BluetoothStore.shared
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
        BluetoothStore.shared.stop()
        BluetoothStore.shared.onChange = nil
        BluetoothStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            BluetoothPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        guard BluetoothStore.shared.isPresent else { return nil }
        let scale = context?.barScale ?? 1
        return BluetoothBarChipView(
            label: BluetoothStore.shared.barLabel,
            scale: scale,
            tooltip: BluetoothStore.shared.tooltip
        )
    }

    public func barSignature() -> String {
        let store = BluetoothStore.shared
        if !store.isPresent {
            return "bt:off:\(PluginL10n.currentCode)"
        }
        let bat = Int(((store.snapshot.primaryBattery ?? -1) * 100).rounded())
        let n = store.snapshot.connected.count
        return "bt:\(bat):\(n):\(PluginL10n.currentCode)"
    }
}

// MARK: - Chip

private final class BluetoothBarChipView: NSView {
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
            BluetoothPanelController.toggle(relativeTo: self)
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
    AlwmPluginExport.makeVTable(plugin: StatsBluetoothPlugin())
}
