import AppKit
import SwiftUI

/// Shared plugin-popover chrome — opaque enough to match Liquid Glass → opaque.
public struct PluginPanelBackground: View {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // Dense material, then a nearly-opaque scrim so wallpaper never punches through.
            PluginVisualEffectRepresentable(material: .hudWindow, blendingMode: .withinWindow)
            shape.fill(Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 0.94)))
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        }
        .clipShape(shape)
    }
}

public extension View {
    /// Shared plugin-popover background (replaces `.ultraThinMaterial`).
    func pluginPanelChrome(cornerRadius: CGFloat = 14, flushTop: Bool = true) -> some View {
        _ = flushTop
        return background(PluginPanelBackground(cornerRadius: cornerRadius))
    }
}

/// `NSVisualEffectView` forced to `.active` so appearance does not oscillate with key-window state.
struct PluginVisualEffectRepresentable: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = true
    }
}
