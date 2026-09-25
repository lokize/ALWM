import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

private final class CalculatorKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum CalculatorPanelController {
    private static var window: CalculatorKeyPanel?
    private static var keyMonitor: Any?

    static func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        if let window, window.isVisible {
            close()
            return
        }
        open(anchoredTo: geometry)
    }

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.calculator")
        let width: CGFloat = 420
        let height: CGFloat = CalculatorStore.shared.settings.scientificMode ? 720 : 640
        let root = CalculatorPanelView()
            .pluginLocalized()
            .frame(width: width, height: height)
        let hosting = NSHostingController(rootView: root)
        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        let win = CalculatorKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.becomesKeyOnlyIfNeeded = false
        win.isFloatingPanel = true
        win.hidesOnDeactivate = false
        window = win
        PluginPanelAnchor.attachBeforePresenting(win, size: NSSize(width: width, height: height), to: geo)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Keep keyboard on the calculator — search/note fields must not steal focus on open.
        win.makeFirstResponder(win.contentView)
        PluginPanelAnchor.attachAfterPresenting(win, size: NSSize(width: width, height: height), to: geo)
        PluginPanelOutsideClick.watch(win)
        installKeyMonitor()
        DispatchQueue.main.async {
            guard let win = self.window, win.isVisible else { return }
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(win.contentView)
        }
    }

    /// Put key events back on the calculator (not history search / notes).
    static func claimKeyboardFocus() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    /// Resize the open panel when scientific mode toggles.
    static func syncPanelSizeIfOpen() {
        guard let window, window.isVisible else { return }
        let width: CGFloat = 420
        let height: CGFloat = CalculatorStore.shared.settings.scientificMode ? 720 : 640
        let geo = PluginPanelAnchor.remembered(forPlugin: "dev.alwm.calculator")
        PluginPanelAnchor.attach(window, size: NSSize(width: width, height: height), to: geo)
    }

    private static func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, window.isVisible, event.window === window else { return event }
            let editingText = window.firstResponder is NSTextView || window.firstResponder is NSTextField
            if editingText {
                // Esc leaves the field and returns keys to the calculator (don't close).
                if event.keyCode == 53 {
                    window.makeFirstResponder(window.contentView)
                    return nil
                }
                return event
            }
            if CalculatorStore.shared.handleKey(
                event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) {
                return nil
            }
            if event.keyCode == 53 {
                close()
                return nil
            }
            return event
        }
    }
}

struct CalculatorPanelView: View {
    @ObservedObject private var store = CalculatorStore.shared
    @State private var noteDrafts: [UUID: String] = [:]

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }
    private var showScientific: Bool { store.settings.scientificMode }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            displayBlock
            keypad
            Divider().opacity(0.35)
            historyBlock
        }
        .frame(width: 420, height: showScientific ? 720 : 640)
        .pluginPanelChrome(cornerRadius: 14)
        .onAppear {
            // Reclaim key focus if SwiftUI focused a text field during first layout.
            DispatchQueue.main.async {
                CalculatorPanelController.claimKeyboardFocus()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "function")
                .foregroundStyle(.orange)
            Text(t("plugin.calculator.title"))
                .font(.headline)
            Spacer()
            Toggle(isOn: Binding(
                get: { store.settings.scientificMode },
                set: { store.setScientificMode($0) }
            )) {
                Text(t("plugin.calculator.scientific"))
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Toggle(isOn: Binding(
                get: { store.settings.degMode },
                set: { store.setDegMode($0) }
            )) {
                Text(store.settings.degMode ? t("plugin.calculator.deg") : t("plugin.calculator.rad"))
                    .font(.caption.monospaced())
            }
            .toggleStyle(.button)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var displayBlock: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if store.hasMemory {
                    Text("M")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
                Text(store.liveExpression.isEmpty ? " " : store.liveExpression)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let preview = store.livePreview {
                    Text("= \(preview)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .accessibilityLabel("= \(preview)")
                }
            }
            Text(store.livePreview ?? store.display)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(store.lastError == nil ? Color.primary : Color.red)
            if let err = store.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            CalculatorPanelController.claimKeyboardFocus()
        }
    }

    private var keypad: some View {
        VStack(spacing: 6) {
            if showScientific {
                HStack(spacing: 6) {
                    sci("sin") { store.applyUnary(.sin) }
                    sci("cos") { store.applyUnary(.cos) }
                    sci("tan") { store.applyUnary(.tan) }
                    sci("π") { store.inputConstant(.pi, symbol: "π") }
                    sci("e") { store.inputConstant(Darwin.M_E, symbol: "e") }
                }
                HStack(spacing: 6) {
                    sci("√") { store.applyUnary(.sqrt) }
                    sci("x²") { store.applyUnary(.square) }
                    sci("1/x") { store.applyUnary(.reciprocal) }
                    sci("(") { store.inputParen("(") }
                    sci(")") { store.inputParen(")") }
                }
            }
            HStack(spacing: 6) {
                mem("MC") { store.memoryClear() }
                mem("MR") { store.memoryRecall() }
                mem("M+") { store.memoryAdd() }
                mem("M−") { store.memorySubtract() }
            }
            HStack(spacing: 6) {
                op("C", accent: .red) { store.clearAll() }
                op("⌫") { store.backspace() }
                op("%") { store.percent() }
                op("÷", accent: .orange) { store.inputOperator("÷") }
            }
            HStack(spacing: 6) {
                num("7")
                num("8")
                num("9")
                op("×", accent: .orange) { store.inputOperator("×") }
            }
            HStack(spacing: 6) {
                num("4")
                num("5")
                num("6")
                op("−", accent: .orange) { store.inputOperator("-") }
            }
            HStack(spacing: 6) {
                num("1")
                num("2")
                num("3")
                op("+", accent: .orange) { store.inputOperator("+") }
            }
            HStack(spacing: 6) {
                op("±") { store.toggleSign() }
                num("0")
                num(".")
                op("=", accent: .orange) { store.evaluate() }
            }
            if showScientific {
                HStack(spacing: 6) {
                    op("^", accent: .orange) { store.inputOperator("^") }
                    Text(t("plugin.calculator.hint.keys"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("plugin.calculator.history"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(t("plugin.calculator.history.clear_unpinned")) {
                    store.clearUnpinnedHistory()
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .disabled(store.history.allSatisfy(\.pinned) || store.history.isEmpty)
            }
            PluginPasteableTextField(
                placeholder: t("plugin.calculator.history.search"),
                text: $store.searchQuery,
                acceptsInitialFocus: false
            )
            .frame(minHeight: 22)

            if store.filteredHistory.isEmpty {
                Text(t("plugin.calculator.history.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.filteredHistory) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func historyRow(_ entry: CalculatorEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.expression)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("= \(entry.result)")
                        .font(.body.weight(.semibold).monospacedDigit())
                }
                Spacer(minLength: 8)
                Button {
                    store.togglePin(id: entry.id)
                } label: {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(t("plugin.calculator.history.pin"))
                Button {
                    store.copyResult(entry.result)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(t("plugin.calculator.history.copy"))
                Button {
                    store.reuseEntry(entry)
                } label: {
                    Image(systemName: "arrow.uturn.left")
                }
                .buttonStyle(.borderless)
                .help(t("plugin.calculator.history.reuse"))
                Button {
                    store.deleteEntry(id: entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(t("plugin.calculator.history.delete"))
            }
            let noteBinding = Binding<String>(
                get: { noteDrafts[entry.id] ?? entry.note },
                set: { noteDrafts[entry.id] = $0 }
            )
            HStack(spacing: 6) {
                PluginPasteableTextField(
                    placeholder: t("plugin.calculator.history.note_placeholder"),
                    text: noteBinding,
                    onSubmit: {
                        store.updateNote(id: entry.id, note: noteDrafts[entry.id] ?? entry.note)
                    },
                    acceptsInitialFocus: false
                )
                .frame(minHeight: 22)
                Button(t("plugin.calculator.history.save_note")) {
                    store.updateNote(id: entry.id, note: noteDrafts[entry.id] ?? entry.note)
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func num(_ label: String) -> some View {
        calcButton(label, fill: Color.primary.opacity(0.08)) {
            store.inputDigit(label)
        }
    }

    private func op(_ label: String, accent: Color? = nil, action: @escaping () -> Void) -> some View {
        calcButton(label, fill: (accent ?? Color.primary).opacity(accent == nil ? 0.08 : 0.22), action: action)
    }

    private func sci(_ label: String, action: @escaping () -> Void) -> some View {
        calcButton(label, fill: Color.cyan.opacity(0.15), font: .caption.weight(.semibold), action: action)
    }

    private func mem(_ label: String, action: @escaping () -> Void) -> some View {
        calcButton(label, fill: Color.orange.opacity(0.15), font: .caption.weight(.semibold), action: action)
    }

    private func calcButton(
        _ label: String,
        fill: Color,
        font: Font = .body.weight(.semibold),
        action: @escaping () -> Void
    ) -> some View {
        Button {
            CalculatorPanelController.claimKeyboardFocus()
            action()
        } label: {
            Text(label)
                .font(font)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
