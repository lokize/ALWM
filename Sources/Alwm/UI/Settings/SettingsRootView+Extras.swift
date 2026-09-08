import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - SettingsRootView — Quake / Capture / Notepad

extension SettingsRootView {

    var quakePane: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $config.settings.quake.enabled)
                    .toggleStyle(.switch)
                TextField("Bundle ID (empty = Ghostty → Terminal)", text: $config.settings.quake.bundleID)
            }
            Section("Placement") {
                Picker("Edge", selection: $config.settings.quake.edge) {
                    ForEach(QuakeEdge.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                labeledSlider("Size (thickness)", value: $config.settings.quake.sizeRatio, range: 0.15...0.9)
                Text(config.settings.quake.edge == .left || config.settings.quake.edge == .right
                     ? "Largura do painel em relação à tela."
                     : "Altura do painel em relação à tela.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledSlider("Length along edge", value: $config.settings.quake.lengthRatio, range: 0.2...1.0)
                labeledNumber("Inset", value: $config.settings.quake.inset)
                labeledSlider("Animation (s)", value: $config.settings.quake.animationDuration, range: 0...0.5)
            }
            Section {
                Toggle(L10n.t("quake.blur"), isOn: Binding(
                    get: { config.settings.quake.blur },
                    set: { on in
                        config.settings.quake.blur = on
                        // Blur is only visible through a translucent terminal.
                        if on, config.settings.quake.opacity > 0.94 {
                            config.settings.quake.opacity = 0.8
                        }
                    }
                ))
                .toggleStyle(.switch)
                if config.settings.quake.blur {
                    labeledSlider(
                        L10n.t("quake.blur.intensity"),
                        value: $config.settings.quake.blurIntensity,
                        range: 0.05...1.0
                    )
                }
                labeledSlider(
                    L10n.t("quake.opacity"),
                    value: Binding(
                        get: { config.settings.quake.opacity },
                        set: { config.settings.quake.opacity = min(1, max(0.25, $0)) }
                    ),
                    range: 0.25...1.0
                )
                Text(L10n.t("quake.opacity.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("quake.blur.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("quake.shortcut.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("quake.appearance"))
            }
        }
        .formStyle(.grouped)
    }


    var capturePane: some View {
        Form {
            Section {
                LabeledContent(L10n.t("capture.settings.screenshots")) {
                    Text(CaptureIO.picturesDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(L10n.t("capture.settings.open_screenshots")) {
                    CaptureIO.revealFolder(CaptureIO.picturesDir)
                }
            } header: {
                Text(L10n.t("capture.settings.screenshots"))
            } footer: {
                Text(L10n.t("capture.settings.screenshots.help"))
            }

            Section {
                LabeledContent(L10n.t("capture.settings.recordings")) {
                    Text(CaptureIO.moviesDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(L10n.t("capture.settings.open_recordings")) {
                    CaptureIO.revealFolder(CaptureIO.moviesDir)
                }
            } header: {
                Text(L10n.t("capture.settings.recordings"))
            } footer: {
                Text(L10n.t("capture.settings.recordings.help"))
            }

            Section {
                Text(L10n.t("capture.settings.hotkeys.help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("capture.settings.hotkeys"))
            }
        }
        .formStyle(.grouped)
    }


    var notepadPane: some View {
        Form {
            Section {
                Toggle(L10n.t("notepad.enabled"), isOn: $config.settings.notepad.enabled)
                    .toggleStyle(.switch)
                Button(L10n.t("notepad.open_folder")) {
                    CaptureIO.revealFolder(NotesPaths.root)
                }
            }
            Section(L10n.t("notepad.placement")) {
                Picker(L10n.t("quake.edge"), selection: $config.settings.notepad.edge) {
                    ForEach(QuakeEdge.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                labeledSlider(L10n.t("notepad.size"), value: $config.settings.notepad.sizeRatio, range: 0.25...0.95)
                labeledSlider(L10n.t("notepad.length"), value: $config.settings.notepad.lengthRatio, range: 0.2...1.0)
                labeledNumber(L10n.t("notepad.inset"), value: $config.settings.notepad.inset)
                labeledSlider(L10n.t("notepad.animation"), value: $config.settings.notepad.animationDuration, range: 0...0.5)
            }
            Section {
                Toggle(L10n.t("quake.blur"), isOn: $config.settings.notepad.blur)
                    .toggleStyle(.switch)
                if config.settings.notepad.blur {
                    labeledSlider(
                        L10n.t("quake.blur.intensity"),
                        value: $config.settings.notepad.blurIntensity,
                        range: 0.05...1.0
                    )
                }
                labeledSlider(
                    L10n.t("quake.opacity"),
                    value: Binding(
                        get: { config.settings.notepad.opacity },
                        set: { config.settings.notepad.opacity = min(1, max(0.25, $0)) }
                    ),
                    range: 0.25...1.0
                )
                Text(L10n.t("notepad.shortcut.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("notepad.appearance"))
            }
        }
        .formStyle(.grouped)
    }
}
