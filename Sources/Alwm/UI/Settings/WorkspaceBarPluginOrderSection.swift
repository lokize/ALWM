import AppKit
import SwiftUI
import AlwmPluginAPI

/// Active plugin chip order for Settings → Workspace bar.
struct WorkspaceBarPluginOrderSection: View {
    @ObservedObject private var loc = LocalizationController.shared
    @State private var rows: [Row] = []

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text(L10n.t("wsbar.plugins_order.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(row.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            move(from: index, to: index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .focusEffectDisabled()
                        .disabled(index == 0)
                        .help(L10n.t("plugins.order.move_up"))

                        Button {
                            move(from: index, to: index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .focusEffectDisabled()
                        .disabled(index >= rows.count - 1)
                        .help(L10n.t("plugins.order.move_down"))
                    }
                }
            }
        } header: {
            Text(L10n.t("wsbar.plugins_order"))
        } footer: {
            Text(L10n.t("wsbar.plugins_order.help"))
                .font(.caption)
        }
        .id(loc.revision)
        .onAppear(perform: reload)
    }

    func reload() {
        PluginManager.shared.refreshCatalog()
        let settings = PluginManager.shared.settings
        let loaded = PluginManager.shared.barItemsSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: PluginManager.shared.catalog.map { ($0.id, $0) })
        let orderedIDs = settings.orderedIDs(catalogIDs: loaded.map(\.id))
        let next = orderedIDs.compactMap { id -> Row? in
            guard loaded.contains(where: { $0.id == id }) else { return nil }
            let name = byID[id]?.manifest.name ?? id
            return Row(id: id, name: name)
        }
        guard next != rows else { return }
        rows = next
    }

    func move(from index: Int, to newIndex: Int) {
        guard rows.indices.contains(index),
              rows.indices.contains(newIndex)
        else { return }
        // Pin Form scroll before SwiftUI re-lays out the section.
        let pin = FormScrollPin.capture()
        var next = rows
        let item = next.remove(at: index)
        next.insert(item, at: newIndex)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rows = next
        }
        PluginManager.shared.reorderBarPlugins(next.map(\.id), refreshBar: false)
        FormScrollPin.restoreAcrossLayout(pin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            PluginManager.shared.requestBarRefresh()
        }
    }
}
