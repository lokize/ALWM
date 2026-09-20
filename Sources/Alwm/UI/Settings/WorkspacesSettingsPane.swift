import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Workspaces settings list

struct WorkspacesSettingsPane: View {
    @Binding var config: AlwmConfig
    let monitors: [MonitorInfo]
    let runningApps: [AppRuleRunningApp]

    var body: some View {
        Form {
            Section {
                ForEach($config.workspaces) { $ws in
                    WorkspaceSettingsRow(
                        workspace: $ws,
                        monitors: monitors,
                        runningApps: runningApps,
                        onDelete: { id in
                            config.workspaces.removeAll { $0.id == id }
                        }
                    )
                }
                Button(action: addWorkspace) {
                    Label(L10n.t("workspaces.add"), systemImage: "plus")
                }
            } footer: {
                Text(L10n.t("workspaces.footer"))
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
    let runningApps: [AppRuleRunningApp]
    var onDelete: (String) -> Void

    @State private var manualBundleID = ""

    var monitorSelection: Binding<String> {
        Binding(
            get: { workspace.monitorIndex.map(String.init) ?? "auto" },
            set: { workspace.monitorIndex = $0 == "auto" ? nil : Int($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.t("workspaces.id"), text: $workspace.id).frame(width: 72)
                TextField(L10n.t("workspaces.name"), text: $workspace.name)
                Button(role: .destructive) {
                    onDelete(workspace.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Picker(L10n.t("workspaces.layout"), selection: $workspace.layout) {
                ForEach(WorkspaceLayoutStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Picker(L10n.t("workspaces.monitor"), selection: monitorSelection) {
                Text(L10n.t("workspaces.monitor.primary")).tag("auto")
                ForEach(Array(monitors.enumerated()), id: \.offset) { idx, mon in
                    Text(monitorLabel(idx: idx, mon: mon)).tag(String(idx))
                }
            }

            Divider().padding(.vertical, 2)

            Text(L10n.t("workspaces.session"))
                .font(.headline)
            Text(L10n.t("workspaces.session.help"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if workspace.sessionApps.isEmpty {
                Text(L10n.t("workspaces.session.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowSessionApps(apps: workspace.sessionApps, runningApps: runningApps) { bid in
                    workspace.sessionApps.removeAll { $0 == bid }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    if addableRunningApps.isEmpty {
                        Text(L10n.t("workspaces.session.no_running"))
                    } else {
                        ForEach(addableRunningApps) { app in
                            Button {
                                addSessionApp(app.bundleID)
                            } label: {
                                Label(app.name, systemImage: "plus")
                            }
                        }
                    }
                } label: {
                    Label(L10n.t("workspaces.session.add_running"), systemImage: "plus.circle")
                }

                TextField(L10n.t("workspaces.session.bundle_placeholder"), text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManualBundle)
                Button(L10n.t("workspaces.session.add")) {
                    addManualBundle()
                }
                .disabled(manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Toggle(L10n.t("workspaces.session.quit_others"), isOn: $workspace.sessionQuitOthers)
                .help(L10n.t("workspaces.session.quit_others.help"))
        }
        .padding(.vertical, 4)
    }

    private var addableRunningApps: [AppRuleRunningApp] {
        let existing = Set(workspace.sessionApps)
        return runningApps.filter { !existing.contains($0.bundleID) }
    }

    private func addSessionApp(_ bundleID: String) {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty, !workspace.sessionApps.contains(bid) else { return }
        workspace.sessionApps.append(bid)
    }

    private func addManualBundle() {
        addSessionApp(manualBundleID)
        manualBundleID = ""
    }

    func monitorLabel(idx: Int, mon: MonitorInfo) -> String {
        let name = mon.name.isEmpty ? L10n.tf("workspaces.monitor.unnamed", idx) : mon.name
        return L10n.tf("workspaces.monitor.only", idx, name)
    }
}

private struct FlowSessionApps: View {
    let apps: [String]
    let runningApps: [AppRuleRunningApp]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(apps, id: \.self) { bid in
                HStack(spacing: 8) {
                    if let icon = appIcon(for: bid) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName(for: bid))
                            .font(.body)
                        Text(bid)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        onRemove(bid)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func displayName(for bundleID: String) -> String {
        if let hit = runningApps.first(where: { $0.bundleID == bundleID }) {
            return hit.name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return bundleID
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
