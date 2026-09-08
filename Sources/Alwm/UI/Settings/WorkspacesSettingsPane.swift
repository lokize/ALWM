import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Workspaces settings list

struct WorkspacesSettingsPane: View {
    @Binding var config: AlwmConfig
    let monitors: [MonitorInfo]

    var body: some View {
        Form {
            Section {
                ForEach($config.workspaces) { $ws in
                    WorkspaceSettingsRow(
                        workspace: $ws,
                        monitors: monitors,
                        onDelete: { id in
                            config.workspaces.removeAll { $0.id == id }
                        }
                    )
                }
                Button(action: addWorkspace) {
                    Label("Add workspace", systemImage: "plus")
                }
            } footer: {
                Text("Cada monitor mostra só os workspaces dele. \"Principal (0)\" = primeiro display. Para um workspace aparecer só no segundo monitor, escolha \"Só 1: …\". Janelas enviadas a um workspace só aparecem quando ele está ativo.")
            }
        }
        .formStyle(.grouped)
    }

    func addWorkspace() {
        let next = String((config.workspaces.compactMap { Int($0.id) }.max() ?? 0) + 1)
        config.workspaces.append(
            WorkspaceDefinition(id: next, name: next, layout: .niri, monitorIndex: nil)
        )
        config.hotkeys = ConfigStore.syncWorkspaceHotkeys(
            workspaces: config.workspaces,
            hotkeys: config.hotkeys
        )
    }
}

struct WorkspaceSettingsRow: View {
    @Binding var workspace: WorkspaceDefinition
    let monitors: [MonitorInfo]
    var onDelete: (String) -> Void

    var monitorSelection: Binding<String> {
        Binding(
            get: { workspace.monitorIndex.map(String.init) ?? "auto" },
            set: { workspace.monitorIndex = $0 == "auto" ? nil : Int($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("ID", text: $workspace.id).frame(width: 72)
                TextField("Name", text: $workspace.name)
                Button(role: .destructive) {
                    onDelete(workspace.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Picker("Layout", selection: $workspace.layout) {
                ForEach(WorkspaceLayoutStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Picker("Monitor", selection: monitorSelection) {
                Text("Principal (0)").tag("auto")
                ForEach(Array(monitors.enumerated()), id: \.offset) { idx, mon in
                    Text(monitorLabel(idx: idx, mon: mon)).tag(String(idx))
                }
            }
        }
        .padding(.vertical, 4)
    }

    func monitorLabel(idx: Int, mon: MonitorInfo) -> String {
        let name = mon.name.isEmpty ? "Display \(idx)" : mon.name
        return "Só \(idx): \(name)"
    }
}

