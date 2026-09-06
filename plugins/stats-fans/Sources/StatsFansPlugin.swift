import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Fans chip + Stats-like popover. Auto-hides on fanless Macs.
public final class StatsFansPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-fans"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = FansStore.shared
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
        FansStore.shared.stop()
        FansStore.shared.onChange = nil
        FansStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            FansPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        guard FansStore.shared.isPresent else { return nil }
        let scale = context?.barScale ?? 1
        let store = FansStore.shared
        let chip = StatsBarChipView(
            symbolName: "fan",
            value: store.barLabel,
            unit: store.chipUnit,
            tint: store.chipTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                FansPanelController.toggle(relativeTo: chip)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = FansStore.shared
        if !store.isPresent {
            return "fans:absent:\(PluginL10n.currentCode)"
        }
        let rpm = Int((store.snapshot.primaryRPM ?? 0).rounded())
        return "fans:\(rpm):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsFansPlugin())
}
