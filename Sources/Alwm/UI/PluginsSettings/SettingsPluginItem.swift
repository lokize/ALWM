import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Settings plugin item model

struct SettingsPluginItem: Identifiable, Equatable {
    var id: String
    var manifest: PluginManifest
    var discovered: DiscoveredPlugin?
    var isInstalled: Bool
    var isEnabled: Bool
    var isBusy: Bool
}
