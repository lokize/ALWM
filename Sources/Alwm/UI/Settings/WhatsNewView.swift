import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Whats New + credits avatar

struct WhatsNewView: View {
    @Environment(\.dismiss) var dismiss

    var releases: [AlwmWhatsNew.Release] {
        AlwmWhatsNew.releases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 4)
            Text("ALWM \(AlwmVersion.string)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(releases, id: \.version) { release in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Version \(release.version)")
                                .font(.headline)
                            ForEach(Array(release.items.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(line)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.trailing, 4)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 520, height: 440)
    }
}

struct CreditsAvatarView: View {
    let url: URL?
    let name: String
    @State var image: NSImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .task(id: url) {
            image = await CreditsService.shared.avatarImage(for: url)
        }
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        if !letters.isEmpty { return letters.joined().uppercased() }
        return String(name.prefix(1)).uppercased()
    }
}

