import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Plugin gallery slider

struct PluginGallerySlider: View {
    let urls: [URL]
    let index: Int
    var onIndexChange: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 16) {
                HStack {
                    Text(L10n.tf("plugins.gallery.counter", index + 1, urls.count))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button(L10n.t("plugins.gallery.close")) { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                HStack(spacing: 16) {
                    navButton(systemName: "chevron.left", help: L10n.t("plugins.gallery.prev")) {
                        onIndexChange(max(0, index - 1))
                    }
                    .disabled(index <= 0)

                    imageView
                        .frame(maxWidth: 860, maxHeight: 520)

                    navButton(systemName: "chevron.right", help: L10n.t("plugins.gallery.next")) {
                        onIndexChange(min(urls.count - 1, index + 1))
                    }
                    .disabled(index >= urls.count - 1)
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 24)
            }
        }
        .focusable()
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left where index > 0:
                onIndexChange(index - 1)
            case .right where index < urls.count - 1:
                onIndexChange(index + 1)
            default:
                break
            }
        }
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    var imageView: some View {
        if urls.indices.contains(index), let img = NSImage(contentsOf: urls[index]) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }

    func navButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }
}
