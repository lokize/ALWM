import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

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
        let store = BluetoothStore.shared
        let chip = StatsBarChipView(
            symbolName: "antenna.radiowaves.left.and.right",
            value: store.barLabel,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                BluetoothPanelController.toggle(relativeTo: chip)
            }
        }
        return chip
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

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsBluetoothPlugin())
}
