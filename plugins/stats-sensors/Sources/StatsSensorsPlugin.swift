import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

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
        let store = SensorsStore.shared
        let chip = StatsBarChipView(
            symbolName: "thermometer",
            value: store.barLabel,
            tint: store.chipTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                SensorsPanelController.toggle(relativeTo: chip)
            }
        }
        return chip
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

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsSensorsPlugin())
}
