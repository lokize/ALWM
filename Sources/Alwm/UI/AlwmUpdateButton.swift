import SwiftUI

/// Shared “Update” CTA — vivid green with white label for clear contrast in dark menus/settings.
enum AlwmUpdateChrome {
    static let green = Color(red: 0.14, green: 0.72, blue: 0.40) // #24B866
    static let greenPressed = Color(red: 0.10, green: 0.58, blue: 0.32)
}

struct AlwmUpdateButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                    .fill(configuration.isPressed ? AlwmUpdateChrome.greenPressed : AlwmUpdateChrome.green)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(
                color: AlwmUpdateChrome.green.opacity(configuration.isPressed ? 0.15 : 0.45),
                radius: configuration.isPressed ? 1 : 6,
                y: configuration.isPressed ? 0 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AlwmUpdateButton: View {
    var title: String = L10n.t("about.update.button")
    var compact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(AlwmUpdateButtonStyle(compact: compact))
    }
}
