import AppKit

/// Drives an `NSStatusBarButton`: truncated title + brand icon.
///
/// Uses only `title`/`image` — custom subviews inside `NSStatusBarButton` force
/// continuous `_updateReplicants` snapshotting (~40–50% CPU on recent macOS).
@MainActor
final class StatusMarqueeController {
    private weak var button: NSStatusBarButton?
    private var fullText = ""

    private let maxChars = 28
    private let iconSide: CGFloat = 14
    private let chromePad: CGFloat = 14

    /// Current menu-bar slot width for the displayed title (icon + text + padding).
    var preferredStatusLength: CGFloat {
        let text = truncate(fullText, maxChars: maxChars)
        if text.isEmpty { return iconSide + chromePad }
        return length(for: text)
    }

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.image = AlwmBrand.logo(side: iconSide * 2)
        button.title = "ALWM"
        button.toolTip = "ALWM"
        applyTruncated()
    }

    func setText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == fullText {
            applyTruncated()
            return
        }
        fullText = trimmed
        button?.toolTip = trimmed.isEmpty ? "ALWM" : trimmed
        applyTruncated()
    }

    private func length(for text: String) -> CGFloat {
        guard !text.isEmpty else { return iconSide + chromePad }
        let font = NSFont.menuBarFont(ofSize: 0)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return max(iconSide + chromePad, textWidth + iconSide + chromePad)
    }

    private func applyTruncated() {
        guard let button else { return }
        let text = truncate(fullText, maxChars: maxChars)
        button.title = text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeft
    }

    private func truncate(_ text: String, maxChars: Int) -> String {
        guard !text.isEmpty else { return "" }
        guard text.count > maxChars else { return text }
        let end = text.index(text.startIndex, offsetBy: max(1, maxChars - 1))
        return String(text[..<end]) + "…"
    }
}
