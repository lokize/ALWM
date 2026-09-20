import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Plugin order helpers

struct PluginOrderRowData: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
enum PluginOrderInline {
    static func loadRows() -> [PluginOrderRowData] {
        PluginManager.shared.refreshCatalog()
        let settings = PluginManager.shared.settings
        let catalog = PluginManager.shared.catalog
        let enabledIDs = catalog.map(\.id).filter { settings.state(for: $0).enabled }
        let loadedIDs = PluginManager.shared.barItemsSnapshot().map(\.id)
        let sourceIDs = !enabledIDs.isEmpty ? enabledIDs : loadedIDs
        let fallbackIDs: [String] = {
            guard sourceIDs.isEmpty else { return [] }
            return settings.states.values
                .filter(\.enabled)
                .sorted { $0.order < $1.order }
                .map(\.id)
        }()
        let ids = sourceIDs.isEmpty ? fallbackIDs : sourceIDs
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.manifest.name) })
        return settings.orderedIDs(catalogIDs: ids).map { id in
            PluginOrderRowData(id: id, name: byName[id] ?? id)
        }
    }

    static func move(id: String, delta: Int) {
        var rows = loadRows()
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + delta
        guard rows.indices.contains(newIndex) else { return }
        let pin = FormScrollPin.capture()
        rows.swapAt(index, newIndex)
        PluginManager.shared.reorderBarPlugins(rows.map(\.id), refreshBar: false)
        FormScrollPin.restoreAcrossLayout(pin)
        NotificationCenter.default.post(name: .alwmPluginOrderDidChange, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            PluginManager.shared.requestBarRefresh()
        }
    }
}

extension Notification.Name {
    static let alwmPluginOrderDidChange = Notification.Name("alwmPluginOrderDidChange")
}

struct PluginOrderRow: View {
    let index: Int
    let total: Int
    let name: String
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= total - 1)
        }
        .padding(.vertical, 4)
    }
}
