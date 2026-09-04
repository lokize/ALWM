import AppKit
import SwiftUI

struct AppRulesSettingsPane: View {
    @Binding var config: AlwmConfig
    let monitors: [MonitorInfo]
    let runningApps: [AppRuleRunningApp]
    let onCaptureFrame: (String?) -> AppRuleCapturedGeometry?
    let onApplyNow: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(Array(config.rules.enumerated()), id: \.offset) { index, _ in
                    AppRuleSettingsRowContainer(
                        rule: $config.rules[index],
                        workspaces: config.workspaces,
                        monitors: monitors,
                        runningApps: runningApps,
                        onCaptureFrame: onCaptureFrame,
                        onDelete: { config.rules.remove(at: index) }
                    )
                }
                Button {
                    config.rules.append(AppRule(mode: .tile))
                } label: {
                    Label(L10n.t("rules.add"), systemImage: "plus")
                }
            } footer: {
                Text(L10n.t("rules.footer"))
                    .font(.caption)
            }

            Section {
                Button {
                    onApplyNow()
                } label: {
                    Label(L10n.t("rules.apply_now"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(L10n.t("rules.apply_now.help"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppRuleSettingsRowContainer: View {
    @Binding var rule: AppRule
    let workspaces: [WorkspaceDefinition]
    let monitors: [MonitorInfo]
    let runningApps: [AppRuleRunningApp]
    let onCaptureFrame: (String?) -> AppRuleCapturedGeometry?
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppRuleSettingsRow(
                rule: $rule,
                workspaces: workspaces,
                monitors: monitors,
                runningApps: runningApps,
                onCaptureFrame: onCaptureFrame
            )
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
        }
        .padding(.vertical, 4)
    }
}

private struct AppRuleSettingsRow: View {
    @Binding var rule: AppRule
    let workspaces: [WorkspaceDefinition]
    let monitors: [MonitorInfo]
    let runningApps: [AppRuleRunningApp]
    let onCaptureFrame: (String?) -> AppRuleCapturedGeometry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            appPicker

            Picker(L10n.t("rules.mode"), selection: $rule.mode) {
                Text(L10n.t("rules.mode.tile")).tag(AppRuleMode.tile)
                Text(L10n.t("rules.mode.float")).tag(AppRuleMode.float)
                Text(L10n.t("rules.mode.ignore")).tag(AppRuleMode.ignore)
            }
            .pickerStyle(.segmented)

            Picker(L10n.t("rules.workspace"), selection: workspaceSelection) {
                Text(L10n.t("rules.workspace.any")).tag("")
                ForEach(workspaces) { ws in
                    Text("\(ws.name) (\(ws.id))").tag(ws.id)
                }
            }

            Picker(L10n.t("rules.monitor"), selection: monitorSelection) {
                Text(L10n.t("rules.monitor.auto")).tag("auto")
                ForEach(Array(monitors.enumerated()), id: \.offset) { idx, mon in
                    Text(monitorLabel(idx: idx, mon: mon)).tag(String(idx))
                }
            }

            Group {
                Text(L10n.t("rules.frame"))
                    .font(.subheadline.weight(.semibold))
                HStack {
                    frameField(L10n.t("rules.frame.w"), value: $rule.width)
                    frameField(L10n.t("rules.frame.h"), value: $rule.height)
                    frameField("X", value: $rule.x)
                    frameField("Y", value: $rule.y)
                }
                HStack {
                    frameField(L10n.t("rules.min_w"), value: $rule.minWidth)
                    frameField(L10n.t("rules.min_h"), value: $rule.minHeight)
                }
                Button {
                    captureFromOpenWindow()
                } label: {
                    Label(L10n.t("rules.capture_frame"), systemImage: "viewfinder")
                }
            }
        }
    }

    @ViewBuilder
    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("rules.app"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                if runningApps.isEmpty {
                    Text(L10n.t("rules.no_running_apps"))
                } else {
                    ForEach(runningApps) { app in
                        Button {
                            selectApp(app)
                        } label: {
                            Text("\(app.name) — \(app.bundleID)")
                        }
                    }
                }
                Divider()
                Button(L10n.t("rules.clear_app")) {
                    rule.bundleID = nil
                    rule.appName = nil
                }
            } label: {
                HStack(spacing: 8) {
                    appIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .lineLimit(1)
                        if let bid = rule.bundleID {
                            Text(bid)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(L10n.t("rules.bundle_id"), text: SettingsBindings.optionalString($rule.bundleID))
                .textFieldStyle(.roundedBorder)
            TextField(L10n.t("rules.app_name"), text: SettingsBindings.optionalString($rule.appName))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var displayName: String {
        if let name = rule.appName, !name.isEmpty { return name }
        if let bid = rule.bundleID { return bid }
        return L10n.t("rules.pick_app")
    }

    @ViewBuilder
    private var appIcon: some View {
        if let bid = rule.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceSelection: Binding<String> {
        Binding(
            get: { rule.workspace ?? "" },
            set: { rule.workspace = $0.isEmpty ? nil : $0 }
        )
    }

    private var monitorSelection: Binding<String> {
        Binding(
            get: {
                guard let idx = rule.monitorIndex else { return "auto" }
                return String(idx)
            },
            set: {
                if $0 == "auto" {
                    rule.monitorIndex = nil
                } else {
                    rule.monitorIndex = Int($0)
                }
            }
        )
    }

    private func frameField(_ label: String, value: Binding<Double?>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            TextField("", text: SettingsBindings.optionalDouble(value))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
        }
    }

    private func monitorLabel(idx: Int, mon: MonitorInfo) -> String {
        let name = mon.name.isEmpty ? L10n.tf("rules.monitor.unnamed", idx) : mon.name
        return "\(idx): \(name)"
    }

    private func selectApp(_ app: AppRuleRunningApp) {
        rule.bundleID = app.bundleID
        rule.appName = app.name
        if let captured = onCaptureFrame(app.bundleID) {
            AppRules.applyCapture(captured, to: &rule)
        }
    }

    private func captureFromOpenWindow() {
        guard let captured = onCaptureFrame(rule.bundleID) else { return }
        AppRules.applyCapture(captured, to: &rule)
    }
}
