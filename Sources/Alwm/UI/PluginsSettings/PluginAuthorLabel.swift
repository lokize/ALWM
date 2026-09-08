import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Plugin author label

struct PluginAuthorLabel: View {
    enum Style {
        case card
        case detail
    }

    let author: String
    var style: Style = .card

    var isOfficial: Bool {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.caseInsensitiveCompare("Lokize") == .orderedSame
            || name.caseInsensitiveCompare("ALWM") == .orderedSame
    }

    var body: some View {
        if isOfficial {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(style == .card ? .caption2 : .caption)
                Text(L10n.t("plugins.badge.official"))
                    .font(style == .card ? .caption2.weight(.bold) : .caption.weight(.semibold))
            }
            .padding(.horizontal, style == .card ? 6 : 8)
            .padding(.vertical, style == .card ? 1 : 2)
            .background(Color.blue.opacity(0.18))
            .foregroundStyle(Color.blue)
            .clipShape(Capsule())
            .accessibilityLabel(L10n.t("plugins.badge.official"))
        } else {
            Text(author)
                .font(style == .card ? .caption : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
