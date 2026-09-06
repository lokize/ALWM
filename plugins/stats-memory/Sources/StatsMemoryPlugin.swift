import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Memory usage chip + Stats-like popover on the workspace bar.
public final class StatsMemoryPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.stats-memory"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = MemoryStore.shared
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
        MemoryStore.shared.stop()
        MemoryStore.shared.onChange = nil
        MemoryStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            MemoryPanelController.close()
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
        let store = MemoryStore.shared
        let chip = StatsBarChipView(
            symbolName: "memorychip",
            value: store.barLabel,
            tint: store.chipTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            guard let chip else { return }
            Task { @MainActor in
                MemoryPanelController.toggle(relativeTo: chip)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = MemoryStore.shared
        let pct = Int((store.snapshot.usageFraction * 100).rounded())
        return "ram:\(pct):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: StatsMemoryPlugin())
}
