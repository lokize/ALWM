import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Uptime chip + boot-time detail popover for the ALWM workspace bar.
public final class StatsUptimePlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-uptime"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = UptimeStore.shared
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
        UptimeStore.shared.stop()
        UptimeStore.shared.onChange = nil
        UptimeStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            UptimePanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let scale = context?.barScale ?? 1
        let store = UptimeStore.shared
        let chip = StatsBarChipView(
            symbolName: "clock",
            value: store.barLabel,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                UptimePanelController.toggle(relativeTo: chip)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let minutes = Int(UptimeStore.shared.snapshot.uptimeSeconds / 60)
        return "up:\(minutes):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsUptimePlugin())
}
