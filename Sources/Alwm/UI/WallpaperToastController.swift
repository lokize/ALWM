import AppKit
import SwiftUI

@MainActor
final class WallpaperToastController {
    static let shared = WallpaperToastController()

    private let width: CGFloat = 360
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    private init() {}

    func show(_ payloads: [WallpaperNotificationContent.Payload]) {
        guard !payloads.isEmpty else { return }
        dismissTimer?.invalidate()

        let toastPanel = panel ?? Self.makePanel(frame: .zero)
        panel = toastPanel
        let host = NSHostingView(rootView: WallpaperToastView(payloads: payloads))
        toastPanel.contentView = host
        let size = NSSize(width: width, height: host.fittingSize.height)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        toastPanel.setFrame(Self.frame(for: size, in: screen.visibleFrame), display: true)
        toastPanel.alphaValue = 1
        toastPanel.orderFrontRegardless()

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
    }

    static func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    static func frame(for size: NSSize, in visibleFrame: NSRect, inset: CGFloat = 18) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - size.width - inset,
            y: visibleFrame.maxY - size.height - inset,
            width: size.width,
            height: size.height
        )
    }
}

private struct WallpaperToastView: View {
    let payloads: [WallpaperNotificationContent.Payload]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.cyan)
                Text("Papel de parede alterado")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            ForEach(Array(payloads.prefix(4).enumerated()), id: \.offset) { _, payload in
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(payload.body)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }

            if payloads.count > 4 {
                Text("+\(payloads.count - 4) outros papéis de parede")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
    }
}
