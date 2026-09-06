import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Battery chip + Stats-like popover. Hidden on desktop Macs without a battery.
public final class StatsBatteryPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-battery"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = BatteryStore.shared
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
        BatteryStore.shared.stop()
        BatteryStore.shared.onChange = nil
        BatteryStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            BatteryPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        guard BatteryStore.shared.isPresent else { return nil }
        let scale = context?.barScale ?? 1
        let store = BatteryStore.shared
        let chip = StatsBarChipView(
            symbolName: store.chipSymbol,
            value: store.barLabel,
            tint: store.chipTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                BatteryPanelController.toggle(relativeTo: chip)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = BatteryStore.shared
        if !store.isPresent {
            return "bat:absent:\(PluginL10n.currentCode)"
        }
        let pct = Int((store.snapshot.percent * 100).rounded())
        let ch = store.snapshot.isCharging ? 1 : 0
        return "bat:\(pct):\(ch):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsBatteryPlugin())
}
