import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

public final class DownloadsPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.downloads"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = DownloadsStore.shared
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
        DownloadsStore.shared.stop()
        DownloadsStore.shared.onChange = nil
        DownloadsStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in DownloadsPanelController.close() }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = DownloadsStore.shared
        let scale = context?.barScale ?? 1
        let chip = StatsBarChipView(
            symbolName: "arrow.down.circle.fill",
            value: store.barLabel,
            tint: store.barTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = {
            Task { @MainActor in
                DownloadsPanelController.toggle(relativeTo: nil)
            }
        }
        return chip
    }

    public func barSignature() -> String {
        let store = DownloadsStore.shared
        return "dl:\(store.downloads.itemCount):\(store.trash.itemCount):\(PluginL10n.currentCode)"
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: DownloadsPlugin())
}
