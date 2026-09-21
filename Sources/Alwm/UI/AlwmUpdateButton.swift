import SwiftUI

/// Shared “Update” CTA — vivid green with white label for clear contrast in dark menus/settings.
enum AlwmUpdateChrome {
    static let green = Color(red: 0.14, green: 0.72, blue: 0.40) // #24B866
    static let greenPressed = Color(red: 0.10, green: 0.58, blue: 0.32)
}

struct AlwmUpdateButtonStyle: ButtonStyle {
    /// `0` regular · `1` compact · `2` mini (status menu header)
    var density: Int = 0

    private var fontSize: CGFloat { density >= 2 ? 10 : density == 1 ? 12 : 13 }
    private var hPad: CGFloat { density >= 2 ? 7 : density == 1 ? 10 : 14 }
    private var vPad: CGFloat { density >= 2 ? 4 : density == 1 ? 5 : 7 }
    private var corner: CGFloat { density >= 2 ? 6 : density == 1 ? 7 : 9 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(configuration.isPressed ? AlwmUpdateChrome.greenPressed : AlwmUpdateChrome.green)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(
                color: AlwmUpdateChrome.green.opacity(configuration.isPressed ? 0.15 : 0.45),
                radius: configuration.isPressed ? 1 : (density >= 2 ? 3 : 6),
                y: configuration.isPressed ? 0 : (density >= 2 ? 1 : 2)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AlwmUpdateButton: View {
    var title: String = L10n.t("about.update.button")
    var compact: Bool = false
    /// Even smaller than `compact` — for the status menu header row.
    var mini: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(AlwmUpdateButtonStyle(density: mini ? 2 : compact ? 1 : 0))
        .fixedSize()
    }
}
