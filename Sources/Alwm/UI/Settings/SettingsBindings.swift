import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Settings binding helpers

enum SettingsBindings {
    static func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    static func optionalDouble(_ binding: Binding<Double?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.map { String(Int($0)) } ?? "" },
            set: { binding.wrappedValue = Double($0) }
        )
    }
}

