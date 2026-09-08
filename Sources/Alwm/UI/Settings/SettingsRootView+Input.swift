import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - SettingsRootView — Gestures / Hotkeys

extension SettingsRootView {

    var gesturesFocusPane: some View {
        Form {
            Section {
                Toggle(L10n.t("gestures.enabled"), isOn: $config.settings.gestures.enabled)
                    .toggleStyle(.switch)
                Toggle(L10n.t("gestures.scroll_snap"), isOn: $config.settings.gestures.scrollSnap)
                    .toggleStyle(.switch)
                Toggle(L10n.t("gestures.invert"), isOn: $config.settings.gestures.invertScroll)
                    .toggleStyle(.switch)
                labeledSlider(L10n.t("gestures.swipe_factor"), value: $config.settings.gestures.swipeScrollFactor, range: 0.4...5)
            } header: {
                Text(L10n.t("gestures.title"))
            }

            Section {
                if config.settings.gestures.bindings.isEmpty {
                    Text(L10n.t("gestures.bindings.empty"))
                        .foregroundStyle(.secondary)
                    Button {
                        config.settings.gestures.bindings = GestureBinding.default
                    } label: {
                        Label(L10n.t("gestures.bindings.restore"), systemImage: "arrow.counterclockwise")
                    }
                }
                ForEach(Array(config.settings.gestures.bindings.enumerated()), id: \.element.id) { index, binding in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Picker("", selection: $config.settings.gestures.bindings[index].action) {
                                ForEach(HotkeyActions.gestureActions, id: \.self) { action in
                                    Text(HotkeyActions.title(for: action)).tag(action)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle("", isOn: $config.settings.gestures.bindings[index].enabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(binding.enabled ? L10n.t("menu.on") : L10n.t("menu.off"))

                            Button(role: .destructive) {
                                config.settings.gestures.bindings.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.t("common.remove"))
                        }

                        Text(HotkeyActions.detail(for: binding.action))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("common.fingers"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $config.settings.gestures.bindings[index].fingers) {
                                    Text("3").tag(3)
                                    Text("4").tag(4)
                                    Text("2").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 160)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("common.direction"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $config.settings.gestures.bindings[index].direction) {
                                    ForEach(GestureDirection.allCases) { dir in
                                        Text(dir.label).tag(dir)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220, alignment: .leading)
                            }
                            Spacer(minLength: 0)
                        }

                        Text(gestureBindingSummary(binding))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .opacity(binding.enabled ? 1 : 0.55)
                }
                Button {
                    config.settings.gestures.bindings.append(
                        GestureBinding(
                            enabled: true,
                            fingers: 3,
                            direction: .left,
                            action: "workspace.prev"
                        )
                    )
                } label: {
                    Label(L10n.t("gestures.add"), systemImage: "plus")
                }
            } header: {
                Text(L10n.t("gestures.bindings"))
            } footer: {
                Text(L10n.t("gestures.bindings.help"))
            }

            Section {
                Label(L10n.t("gestures.mission_control.tip"), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("gestures.open_trackpad_settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.trackpad") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }

            Section {
                Toggle(L10n.t("focus.follows_mouse"), isOn: $config.settings.focusFollowsMouse)
                    .toggleStyle(.switch)
                Toggle(L10n.t("focus.move_mouse"), isOn: $config.settings.moveMouseToFocusedWindow)
                    .toggleStyle(.switch)
                Toggle(L10n.t("focus.warp"), isOn: $config.settings.warpCursorOnEmptyWorkspace)
                    .toggleStyle(.switch)
            } header: {
                Text(L10n.t("focus.title"))
            } footer: {
                Text(L10n.t("focus.warp.help"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if config.settings.gestures.bindings.isEmpty {
                config.settings.gestures.bindings = GestureBinding.default
            }
        }
    }


    var hotkeysPane: some View {
        Form {
            Section {
                if filteredHotkeyIndices.isEmpty {
                    Text(L10n.t("hotkeys.search.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(filteredHotkeyIndices, id: \.self) { index in
                    let binding = config.hotkeys[index]
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $config.hotkeys[index].action) {
                            ForEach(HotkeyActions.catalog(workspaces: config.workspaces), id: \.self) { action in
                                Text("\(HotkeyActions.title(for: action))  ·  \(action)").tag(action)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Text(HotkeyActions.detail(for: binding.action))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Text(L10n.t("hotkeys.shortcut"))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            HotkeyRecorderField(
                                key: $config.hotkeys[index].key,
                                modifiers: $config.hotkeys[index].modifiers
                            )
                            Spacer(minLength: 8)
                            Text(chord(binding))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                            Button(role: .destructive) {
                                config.hotkeys.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    config.hotkeys.append(
                        HotkeyBinding(action: "relayout", key: "r", modifiers: ["option"])
                    )
                } label: {
                    Label(L10n.t("hotkeys.add"), systemImage: "plus")
                }
            } footer: {
                Text(L10n.t("hotkeys.record.help"))
            }
        }
        .formStyle(.grouped)
    }


    func gestureBindingSummary(_ binding: GestureBinding) -> String {
        let fingers = "\(binding.fingers)"
        return "\(fingers) · \(binding.direction.label) → \(HotkeyActions.title(for: binding.action))"
    }


    var hotkeySearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t("hotkeys.search"), text: $hotkeySearch)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !hotkeySearch.isEmpty {
                Button {
                    hotkeySearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }


    var filteredHotkeyIndices: [Int] {
        let q = hotkeySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(config.hotkeys.indices) }
        return config.hotkeys.indices.filter { index in
            let binding = config.hotkeys[index]
            let haystack = [
                binding.action,
                HotkeyActions.title(for: binding.action),
                HotkeyActions.detail(for: binding.action),
                binding.key,
                chord(binding),
                binding.modifiers.joined(separator: "+")
            ].joined(separator: " ").lowercased()
            return haystack.contains(q)
        }
    }
}
