import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

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
        let store = GPUStore.shared
        let chip = StatsBarChipView(
            symbolName: "rectangle.3.group",
            value: store.barLabel,
            tint: store.chipTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                GPUPanelController.toggle(relativeTo: chip)
            }
        }
        return chip
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

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsGPUPlugin())
}
