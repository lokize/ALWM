import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Calendar day chip + agenda / quick-add popover for the workspace bar.
public final class CalendarPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.calendar"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = CalendarStore.shared
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
        CalendarStore.shared.stop()
        CalendarStore.shared.onChange = nil
        CalendarStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            CalendarPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = CalendarStore.shared
        let scale = context?.barScale ?? 1
        let chip = StatsBarChipView(
            symbolName: store.barSymbol,
            value: store.barLabel,
            unit: store.barUnit,
            tint: store.barTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = { [weak chip] in
            let geometry = PluginPanelAnchor.geometry(of: chip)
            Task { @MainActor in
                PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.calendar")
                CalendarPanelController.toggle(anchoredTo: geometry)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = CalendarStore.shared
        let temp = store.weather?.currentTemp.map { Int($0.rounded()) } ?? -999
        let code = store.weather?.currentCode ?? -1
        return "cal:\(store.barLabel):\(store.todayEventCount):\(temp):\(code):\(store.authorizationStatus.rawValue):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: CalendarPlugin())
}
