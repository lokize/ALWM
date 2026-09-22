import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Calculator with history + notes for the ALWM workspace bar.
public final class CalculatorPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.calculator"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = CalculatorStore.shared
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
    }

    public func unload() {
        CalculatorStore.shared.onChange = nil
        CalculatorStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            CalculatorPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = CalculatorStore.shared
        let scale = context?.barScale ?? 1
        let chip = StatsBarChipView(
            symbolName: "function",
            value: store.barLabel,
            tint: store.barTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            let geometry = PluginPanelAnchor.geometry(of: chip)
            Task { @MainActor in
                PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.calculator")
                CalculatorPanelController.toggle(anchoredTo: geometry)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = CalculatorStore.shared
        let preview = store.livePreview ?? store.display
        return "calc:\(preview):\(store.history.count):\(store.hasMemory):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: CalculatorPlugin())
}
