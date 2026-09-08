import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Plugins settings helpers

func isUserInstalledBundle(_ url: URL) -> Bool {
    PluginInstallService.isPath(url, under: PluginInstallService.userPlugInsURL)
}

func resolveInstalled(
    onDisk: Bool,
    bundleURL: URL?,
    state: PluginUserState,
    hasPersistedState: Bool
) -> Bool {
    if let bundleURL, isUserInstalledBundle(bundleURL) {
        return onDisk
    }
    if onDisk {
        // Bundled / dist copy: honor soft-uninstall (`installed = false` in plugins.toml).
        if hasPersistedState { return state.installed }
        return true
    }
    return state.installed
}
