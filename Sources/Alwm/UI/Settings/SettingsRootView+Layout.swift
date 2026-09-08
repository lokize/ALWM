import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - SettingsRootView — Layout / Monitors / Workspaces / Rules

extension SettingsRootView {

    var layoutPane: some View {
        Form {
            Section("Columns") {
                labeledSlider("Inner gap", value: $config.settings.gap, range: 0...40)
                labeledSlider("Outer gap", value: $config.settings.outerGap, range: 0...40)
                labeledSlider("Default column width", value: $config.settings.defaultColumnWidthRatio, range: 0.25...1)
                labeledNumber("Minimum column width", value: $config.settings.minColumnWidth)
            }
            Section("Motion") {
                labeledSlider("Animation duration (s)", value: $config.settings.animationDuration, range: 0...0.6)
                Text("Layout motion stays part of the scrolling model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }


    var monitorsPane: some View {
        Form {
            Section("Detected displays") {
                if monitors.isEmpty {
                    Text("No monitors reported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(monitors.enumerated()), id: \.offset) { _, mon in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mon.name.isEmpty ? "Display \(mon.id)" : mon.name)
                                .font(.headline)
                            Text("id=\(mon.id)  \(Int(mon.frame.width))×\(Int(mon.frame.height)) @ (\(Int(mon.frame.x)), \(Int(mon.frame.y)))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Tips") {
                Text("For scrolling columns across multiple displays, prefer vertical monitor arrangement in System Settings and an auto-hiding Dock so parked windows do not bleed sideways.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }


    var workspacesPane: some View {
        WorkspacesSettingsPane(config: $config, monitors: monitors)
    }


    var rulesPane: some View {
        AppRulesSettingsPane(
            config: $config,
            monitors: monitors,
            runningApps: runningAppsProvider(),
            onCaptureFrame: onCaptureAppRuleFrame,
            onApplyNow: {
                onSave(config)
                onApplyRulesNow()
            }
        )
    }
}
