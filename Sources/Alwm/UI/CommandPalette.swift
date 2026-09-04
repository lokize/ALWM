import AppKit
import Foundation

public struct CommandItem: Equatable, Sendable {
    public var action: String
    public var title: String
    public var detail: String
    public var shortcut: String
    /// Per-keycap labels for badge UI (e.g. `["⌥", "⇧", "←"]`).
    public var shortcutTokens: [String]

    public init(
        action: String,
        title: String,
        detail: String = "",
        shortcut: String = "",
        shortcutTokens: [String] = []
    ) {
        self.action = action
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.shortcutTokens = shortcutTokens.isEmpty && !shortcut.isEmpty
            ? [shortcut]
            : shortcutTokens
    }
}

@MainActor
public final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var panel: NSPanel?
    private var field: NSTextField?
    private var table: NSTableView?
    private var catalog: [CommandItem] = []
    private var filtered: [CommandItem] = []
    private var clickOutsideGlobal: Any?
    private var clickOutsideLocal: Any?
    private var clickOutsideBridge: PaletteClickOutsideBridge?
    private let rowClickBridge = PaletteRowClickBridge()
    public private(set) var isVisible = false
    public var onRun: ((String) -> Void)?

    public override init() {
        super.init()
        rowClickBridge.owner = self
    }
    public func toggle(monitor: MonitorInfo, mainHeight: Double, bindings: [HotkeyBinding]) {
        if isVisible { hide() } else { show(monitor: monitor, mainHeight: mainHeight, bindings: bindings) }
    }

    public func show(monitor: MonitorInfo, mainHeight: Double, bindings: [HotkeyBinding]) {
        if isVisible { hide() }
        catalog = Self.buildCatalog(bindings: bindings)
        filtered = catalog

        let width: CGFloat = 580
        let height: CGFloat = 420
        let cocoaY = mainHeight - monitor.frame.y - (monitor.frame.height + height) / 2
        let x = monitor.frame.x + (monitor.frame.width - width) / 2
        let rect = NSRect(x: x, y: cocoaY, width: width, height: height)

        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "ALWM Commands"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(origin: .zero, size: rect.size))
        let field = NSTextField(frame: NSRect(x: 12, y: height - 40, width: width - 24, height: 28))
        field.placeholderString = "Buscar por nome, descrição ou atalho…"
        field.delegate = self
        field.focusRingType = .none

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: width - 24, height: height - 60))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let table = NSTableView(frame: scroll.bounds)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.title = "Command"
        col.width = width - 40
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 52
        table.delegate = self
        table.dataSource = self
        table.target = rowClickBridge
        table.action = #selector(PaletteRowClickBridge.rowClicked)
        table.doubleAction = #selector(PaletteRowClickBridge.rowClicked)
        table.allowsEmptySelection = false
        scroll.documentView = table

        root.addSubview(field)
        root.addSubview(scroll)
        panel.contentView = root
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        self.panel = panel
        self.field = field
        self.table = table
        isVisible = true
        table.reloadData()
        if !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        installClickOutsideMonitor()
    }

    public func hide() {
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
        panel = nil
        field = nil
        table = nil
        isVisible = false
        catalog = []
        filtered = []
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        let bridge = PaletteClickOutsideBridge { [weak self] in
            self?.dismissIfClickOutside()
        }
        clickOutsideBridge = bridge
        clickOutsideGlobal = bridge.installGlobal()
        clickOutsideLocal = bridge.installLocal()
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideGlobal {
            NSEvent.removeMonitor(clickOutsideGlobal)
            self.clickOutsideGlobal = nil
        }
        if let clickOutsideLocal {
            NSEvent.removeMonitor(clickOutsideLocal)
            self.clickOutsideLocal = nil
        }
        clickOutsideBridge = nil
    }

    private func dismissIfClickOutside() {
        guard isVisible, let panel else { return }
        let loc = NSEvent.mouseLocation
        // Inflate slightly so title-bar / shadow edge clicks still count as inside.
        let frame = panel.frame.insetBy(dx: -2, dy: -2)
        if frame.contains(loc) { return }
        hide()
    }

    public static func buildCatalog(bindings: [HotkeyBinding]) -> [CommandItem] {
        var actions = HotkeyActions.all
        for b in bindings where !actions.contains(b.action) {
            actions.append(b.action)
        }
        return actions.map { action in
            let tokens = HotkeyActions.chordTokens(for: action, in: bindings) ?? []
            return CommandItem(
                action: action,
                title: HotkeyActions.title(for: action),
                detail: HotkeyActions.detail(for: action),
                shortcut: tokens.joined(),
                shortcutTokens: tokens
            )
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        let q = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filtered = catalog
        } else {
            filtered = catalog.filter {
                $0.title.lowercased().contains(q)
                    || $0.detail.lowercased().contains(q)
                    || $0.action.lowercased().contains(q)
                    || $0.shortcut.lowercased().contains(q)
            }
        }
        table?.reloadData()
        if !filtered.isEmpty {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filtered[row]
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("cmdCell")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.distribution = .fill

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcutView: NSView
        if item.shortcutTokens.isEmpty {
            let empty = NSTextField(labelWithString: "—")
            empty.font = .systemFont(ofSize: 12, weight: .medium)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .right
            empty.setContentHuggingPriority(.required, for: .horizontal)
            shortcutView = empty
        } else {
            shortcutView = Self.makeKeycapStack(tokens: item.shortcutTokens)
        }

        top.addArrangedSubview(title)
        top.addArrangedSubview(NSView()) // spacer
        top.addArrangedSubview(shortcutView)

        let detail = NSTextField(wrappingLabelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping

        stack.addArrangedSubview(top)
        stack.addArrangedSubview(detail)
        cell.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return cell
    }

    fileprivate func rowClicked() {
        guard let row = table?.selectedRow, row >= 0, row < filtered.count else { return }
        let action = filtered[row].action
        hide()
        onRun?(action)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            rowClicked()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard let table, filtered.count > 0 else { return true }
            let next = min(table.selectedRow + 1, filtered.count - 1)
            table.selectRowIndexes(IndexSet(integer: max(0, next)), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard let table, filtered.count > 0 else { return true }
            let next = max(table.selectedRow - 1, 0)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        }
        return false
    }

    /// Horizontal stack of macOS-style keycap badges.
    private static func makeKeycapStack(tokens: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for token in tokens {
            stack.addArrangedSubview(makeKeycapBadge(token))
        }
        return stack
    }

    private static func makeKeycapBadge(_ symbol: String) -> NSView {
        let label = NSTextField(labelWithString: symbol)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer?.cornerRadius = 5
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor

        box.addSubview(label)
        let minSide: CGFloat = symbol.count > 1 ? 28 : 22
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
            box.heightAnchor.constraint(equalToConstant: 22),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: minSide)
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.setContentCompressionResistancePriority(.required, for: .horizontal)
        return box
    }
}

/// Click-outside monitors without capturing MainActor self.
private final class PaletteClickOutsideBridge: @unchecked Sendable {
    private let onClick: @MainActor () -> Void

    init(onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
    }

    func installGlobal() -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.onClick() }
        }
    }

    func installLocal() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in self.onClick() }
            return event
        }
    }
}

private final class PaletteRowClickBridge: NSObject {
    nonisolated(unsafe) weak var owner: CommandPaletteController?

    @objc func rowClicked() {
        let owner = self.owner
        Task { @MainActor in owner?.rowClicked() }
    }
}
