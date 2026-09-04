import AppKit
import SwiftUI

@MainActor
public final class ColorPaletteController {
    nonisolated(unsafe) private static var sharedWindow: NSWindow?

    public init() {}

    public func toggle(relativeTo view: NSView? = nil) {
        if let win = Self.sharedWindow, win.isVisible {
            win.orderOut(nil)
            return
        }
        open(relativeTo: view)
    }

    public func open(relativeTo view: NSView? = nil) {
        let root = ColorPaletteView(onClose: { Self.sharedWindow?.orderOut(nil) })
        let hosting = NSHostingController(rootView: root)
        let win = Self.sharedWindow ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.t("menu.color_palette")
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 280, height: 300)

        if let view, let screen = view.window?.screen ?? NSScreen.main {
            let rect = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
                ?? NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 1)
            var origin = NSPoint(x: rect.midX - 160, y: rect.minY - 380)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - 332)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 12), screen.visibleFrame.maxY - 320)
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.sharedWindow = win
    }

    public func close() {
        Self.sharedWindow?.orderOut(nil)
    }
}

// MARK: - View

private struct ColorPaletteView: View {
    var onClose: () -> Void
    @State private var copied: String?
    @State private var flashID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("color_palette.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    sampleFromScreen()
                } label: {
                    Label(L10n.t("color_palette.eyedropper"), systemImage: "eyedropper")
                }
                .controlSize(.small)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Self.swatches) { swatch in
                        swatchButton(swatch)
                    }
                }
            }

            HStack {
                if let copied {
                    Text(String(format: L10n.t("color_palette.copied"), copied))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button(L10n.t("plugins.close")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(minWidth: 300, minHeight: 320)
    }

    private func swatchButton(_ swatch: ColorSwatch) -> some View {
        Button {
            copy(swatch)
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: swatch.color))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .overlay {
                    if flashID == swatch.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(swatch.color.relativeLuminance > 0.55 ? Color.black : Color.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(swatch.hex)
    }

    private func copy(_ swatch: ColorSwatch) {
        ColorPasteboard.copy(swatch.color, hex: swatch.hex)
        withAnimation(.easeOut(duration: 0.15)) {
            copied = swatch.hex
            flashID = swatch.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation {
                if flashID == swatch.id { flashID = nil }
            }
        }
    }

    private func sampleFromScreen() {
        NSColorSampler().show { color in
            guard let color else { return }
            let hex = color.alwmHexString
            ColorPasteboard.copy(color, hex: hex)
            DispatchQueue.main.async {
                withAnimation {
                    copied = hex
                }
            }
        }
    }

    private static let swatches: [ColorSwatch] = {
        let hexes = [
            // Neutrals
            "#000000", "#1C1C1E", "#2C2C2E", "#3A3A3C", "#8E8E93", "#C7C7CC", "#E5E5EA", "#FFFFFF",
            // Reds / oranges
            "#FF3B30", "#FF453A", "#FF6961", "#FF9500", "#FF9F0A", "#FFD60A", "#FFCC00", "#F4C27A",
            // Greens
            "#34C759", "#30D158", "#32ADE6", "#64D2FF", "#0A84FF", "#007AFF", "#5E5CE6", "#BF5AF2",
            // Teals / accents
            "#4FC3F7", "#00C7BE", "#AC8E68", "#A2845E", "#FF375F", "#FF2D55", "#AF52DE", "#5856D6",
            // Deep
            "#8B0000", "#006400", "#00008B", "#4B0082", "#800020", "#2F4F4F", "#556B2F", "#191970"
        ]
        return hexes.enumerated().compactMap { index, hex in
            guard let color = NSColor(hex: hex) else { return nil }
            return ColorSwatch(id: "\(index)-\(hex)", hex: hex.uppercased(), color: color)
        }
    }()
}

private struct ColorSwatch: Identifiable {
    let id: String
    let hex: String
    let color: NSColor
}

private enum ColorPasteboard {
    static func copy(_ color: NSColor, hex: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex, forType: .string)
        pb.writeObjects([color])
    }
}

private extension NSColor {
    var alwmHexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
