import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Plugins catalog grid

struct PluginsCatalogGrid: View {
    let items: [SettingsPluginItem]
    let cardGap: CGFloat
    let onToggle: (SettingsPluginItem, Bool) -> Void
    let onDownload: (SettingsPluginItem) -> Void
    let onUninstall: (SettingsPluginItem) -> Void
    let onOpen: (SettingsPluginItem) -> Void

    var body: some View {
        // Non-lazy grid: LazyVGrid inside ScrollView often under/over-reports height
        // on macOS, which breaks scrolling in Settings.
        Grid(horizontalSpacing: cardGap, verticalSpacing: cardGap) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                GridRow {
                    card(items[start])
                    if start + 1 < items.count {
                        card(items[start + 1])
                    } else {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    func card(_ item: SettingsPluginItem) -> some View {
        PluginCardRow(
            item: item,
            onToggle: { onToggle(item, $0) },
            onDownload: { onDownload(item) },
            onUninstall: { onUninstall(item) },
            onOpen: { onOpen(item) }
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .gridCellColumns(1)
    }
}
