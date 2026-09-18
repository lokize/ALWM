import AppKit
import SwiftUI

/// AppKit-backed field so ⌘V / menu Paste work in floating plugin `NSPanel`s.
/// SwiftUI `TextField` inside utility panels often never becomes first-responder for paste.
public struct PluginPasteableTextField: NSViewRepresentable {
    public var placeholder: String
    @Binding public var text: String
    public var onSubmit: (() -> Void)?

    public init(placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    public func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        weak var field: NSTextField?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                text.wrappedValue = (control as? NSTextField)?.stringValue ?? text.wrappedValue
                onSubmit?()
                return true
            }
            return false
        }
    }
}
