import AppKit
import SwiftUI

/// Shared brand artwork (logo / app icon source).
public enum AlwmBrand {
    /// Full-color logo from `Resources/alwm.png` (falls back to SF Symbol).
    public static var logo: NSImage {
        if let url = AlwmResources.url(forResource: "alwm", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let image = NSImage(named: "alwm") {
            return image
        }
        return NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "ALWM")
            ?? NSImage(size: NSSize(width: 64, height: 64))
    }

    /// Sized copy suitable for menu-bar / chrome (not a template image).
    public static func logo(side: CGFloat) -> NSImage {
        let source = logo
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let srcSize = source.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            image.unlockFocus()
            return source
        }
        let scale = min(side / srcSize.width, side / srcSize.height)
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let origin = NSPoint(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2
        )
        source.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

public struct AlwmLogoImage: View {
    var side: CGFloat
    var cornerRadius: CGFloat

    public init(side: CGFloat = 40, cornerRadius: CGFloat = 10) {
        self.side = side
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Image(nsImage: AlwmBrand.logo(side: side * 2))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
