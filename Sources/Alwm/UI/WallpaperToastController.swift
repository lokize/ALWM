import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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
            Text("Papel de parede alterado")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            ForEach(Array(payloads.prefix(4).enumerated()), id: \.offset) { _, payload in
                HStack(spacing: 10) {
                    WallpaperToastThumbnailView(url: payload.wallpaperURL)
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

private struct WallpaperToastThumbnailView: View {
    let url: URL
    @State private var thumbnailData: Data?

    var body: some View {
        Group {
            if let thumbnailData, let image = NSImage(data: thumbnailData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.08))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .task(id: url) {
            let data = await Task.detached(priority: .utility) {
                await WallpaperToastThumbnail.data(for: url)
            }.value
            thumbnailData = data
        }
    }
}

enum WallpaperToastThumbnail {
    static func data(for url: URL) async -> Data? {
        let ext = url.pathExtension.lowercased()
        let cgImage: CGImage?
        if WallpaperCatalog.imageExtensions.contains(ext) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 176
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            cgImage = thumbnail
        } else if WallpaperCatalog.videoExtensions.contains(ext) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 176, height: 176)
            cgImage = try? await generator.image(
                at: CMTime(seconds: 0.1, preferredTimescale: 600)
            ).image
        } else {
            return nil
        }

        guard let cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
