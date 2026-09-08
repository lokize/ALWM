import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - SettingsRootView — Persist helpers

extension SettingsRootView {

    // MARK: Helpers

    func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            persist()
        }
    }


    func persist() {
        var synced = config
        synced.hotkeys = ConfigStore.syncWorkspaceHotkeys(
            workspaces: synced.workspaces,
            hotkeys: synced.hotkeys
        )
        if synced.hotkeys.count != config.hotkeys.count {
            config = synced
        }
        ConfigWriter.write(synced)
        onSave(synced)
    }


    func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        id: String? = nil
    ) -> some View {
        let sliderID = id ?? "slider.\(title).\(range.lowerBound).\(range.upperBound)"
        return LabeledContent {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { newValue in
                            let clamped = min(range.upperBound, max(range.lowerBound, newValue))
                            value.wrappedValue = (clamped * 1000).rounded() / 1000
                        }
                    ),
                    in: range
                )
                .id(sliderID)
                .controlSize(.small)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 220)
        } label: {
            Text(title)
        }
        .id(sliderID + ".row")
    }


    func labeledNumber(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
        }
    }


    func chord(_ b: HotkeyBinding) -> String {
        HotkeyActions.chord(key: b.key, modifiers: b.modifiers)
    }


    func modifiersText(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.joined(separator: ", ") },
            set: {
                binding.wrappedValue = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            }
        )
    }


    func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        SettingsBindings.optionalString(binding)
    }


    func optionalDouble(_ binding: Binding<Double?>) -> Binding<String> {
        SettingsBindings.optionalDouble(binding)
    }
}
