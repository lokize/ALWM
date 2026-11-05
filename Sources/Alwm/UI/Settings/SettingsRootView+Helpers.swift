import AppKit
import SwiftUI
import AlwmPluginAPI

enum SettingsPersistencePolicy {
    static func shouldFlushOnDisappear(hasPendingLocalChanges: Bool) -> Bool {
        hasPendingLocalChanges
    }
}

@MainActor
public final class SettingsPersistCoordinator: ObservableObject {
    @Published public var hasPendingChanges: Bool = false
    public var initialConfig: AlwmConfig
    public var liveConfig: AlwmConfig
    public var onSave: ((AlwmConfig) -> Void)?
    public var persistTask: Task<Void, Never>?

    public init(config: AlwmConfig, onSave: ((AlwmConfig) -> Void)? = nil) {
        self.initialConfig = config
        self.liveConfig = config
        self.onSave = onSave
    }

    public func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    public func flushIfNeeded() {
        guard SettingsPersistencePolicy.shouldFlushOnDisappear(hasPendingLocalChanges: hasPendingChanges) else { return }
        persist()
    }

    public func persist() {
        persistTask?.cancel()
        persistTask = nil
        guard hasPendingChanges else { return }
        var synced = liveConfig
        synced.hotkeys = ConfigStore.syncWorkspaceHotkeys(
            workspaces: synced.workspaces,
            hotkeys: synced.hotkeys
        )
        if synced.hotkeys.count != liveConfig.hotkeys.count {
            liveConfig = synced
        }
        ConfigWriter.writeChanges(from: initialConfig, to: synced)
        initialConfig = synced
        onSave?(synced)
        hasPendingChanges = false
    }
}

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
        persistTask?.cancel()
        persistTask = nil
        guard SettingsPersistencePolicy.shouldFlushOnDisappear(hasPendingLocalChanges: hasPendingLocalChanges) else { return }
        var synced = config
        synced.hotkeys = ConfigStore.syncWorkspaceHotkeys(
            workspaces: synced.workspaces,
            hotkeys: synced.hotkeys
        )
        if synced.hotkeys.count != config.hotkeys.count {
            config = synced
        }
        ConfigWriter.writeChanges(from: coordinator.initialConfig, to: synced)
        coordinator.initialConfig = synced
        coordinator.liveConfig = synced
        onSave(synced)
        hasPendingLocalChanges = false
        coordinator.hasPendingChanges = false
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
