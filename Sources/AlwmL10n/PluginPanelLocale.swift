import SwiftUI

/// Keeps plugin SwiftUI panels in sync with ALWM language changes.
public struct PluginPanelLocaleModifier: ViewModifier {
    @State private var revision = 0

    public init() {}

    public func body(content: Content) -> some View {
        content
            .environment(\.locale, Locale(identifier: PluginL10n.currentCode))
            .id(revision)
            .onReceive(NotificationCenter.default.publisher(for: .alwmLanguageDidChange)) { _ in
                revision += 1
            }
    }
}

public extension View {
    /// Bind panel copy to ALWM Settings → Language.
    func pluginLocalized() -> some View {
        modifier(PluginPanelLocaleModifier())
    }

    @available(*, deprecated, message: "Use pluginLocalized() — language always follows the app.")
    func pluginLocalized(localeCode: @escaping () -> String) -> some View {
        modifier(PluginPanelLocaleModifier())
    }
}
