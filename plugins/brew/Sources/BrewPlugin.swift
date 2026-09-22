import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

public final class BrewPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.brew"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = BrewStore.shared
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
        BrewStore.shared.stop()
        BrewStore.shared.onChange = nil
        BrewStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in BrewPanelController.close() }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = BrewStore.shared
        let scale = context?.barScale ?? 1
        let chip = StatsBarChipView(
            symbolName: "mug.fill",
            value: store.barLabel,
            tint: store.barTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            let geometry = PluginPanelAnchor.geometry(of: chip)
            Task { @MainActor in
                PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.brew")
                BrewPanelController.toggle(anchoredTo: geometry)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = BrewStore.shared
        return "brew:\(store.outdatedCount):\(store.isRefreshing):\(store.isUpgrading):\(store.brewAvailable):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: BrewPlugin())
}
