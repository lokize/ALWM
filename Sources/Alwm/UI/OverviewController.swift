import AppKit
import Foundation

@MainActor
public final class OverviewController {
    private var window: NSWindow?
    private let actionBridge = OverviewActionBridge()
    public private(set) var isVisible = false
    public var onSelectWorkspace: ((String) -> Void)?
    public var onMoveWindow: ((WindowID, String) -> Void)?
    public var onCloseWindow: ((WindowID) -> Void)?
    public var onLaunchApp: ((String, String) -> Void)?
    public var onReorderColumn: ((String, Int, Int) -> Void)?
    public var onMoveWindowToColumn: ((WindowID, String, Int) -> Void)?

    public init() {
        actionBridge.owner = self
    }

    public func toggle(
        monitor: MonitorInfo,
        definitions: [WorkspaceDefinition],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        mainHeight: Double,
        savedLayouts: [String: RuntimeStateStore.WorkspaceLayoutSnapshot] = [:]
    ) {
        if isVisible {
            hide()
        } else {
            show(monitor: monitor, definitions: definitions, workspaces: workspaces, windowsByID: windowsByID, mainHeight: mainHeight, savedLayouts: savedLayouts)
        }
    }

    public func show(
        monitor: MonitorInfo,
        definitions: [WorkspaceDefinition],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        mainHeight: Double,
        savedLayouts: [String: RuntimeStateStore.WorkspaceLayoutSnapshot] = [:]
    ) {
        let cocoaY = mainHeight - monitor.frame.y - monitor.frame.height
        let rect = NSRect(x: monitor.frame.x, y: cocoaY, width: monitor.frame.width, height: monitor.frame.height)

        let panel = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces]

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: rect.size))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Visão geral")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.textColor = .white
        stack.addArrangedSubview(title)

        let canThumb = Permissions.screenRecordingGranted()
        if !canThumb {
            let note = NSTextField(labelWithString: "Permita gravação de tela para exibir miniaturas; os nomes continuam disponíveis.")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(note)
        }

        var pendingThumbs: [(NSImageView, Int)] = []

        for def in definitions {
            let ws = workspaces[def.id] ?? WorkspaceState(id: def.id, name: def.name)
            let header = NSTextField(labelWithString: "Workspace \(def.name)")
            header.font = .systemFont(ofSize: 18, weight: .medium)
            header.textColor = .white
            stack.addArrangedSubview(header)

            let columnsRow = NSStackView()
            columnsRow.orientation = .horizontal
            columnsRow.spacing = 10
            columnsRow.alignment = .top

            if ws.columns.isEmpty {
                let emptyDrop = OverviewDropStackView(workspaceID: def.id, columnIndex: 0, owner: self)
                emptyDrop.orientation = .vertical
                emptyDrop.alignment = .centerX
                emptyDrop.addArrangedSubview(NSTextField(labelWithString: "Solte uma janela aqui"))
                emptyDrop.translatesAutoresizingMaskIntoConstraints = false
                emptyDrop.widthAnchor.constraint(equalToConstant: 190).isActive = true
                emptyDrop.heightAnchor.constraint(equalToConstant: 96).isActive = true
                let empty = NSTextField(labelWithString: "Vazio")
                empty.textColor = .secondaryLabelColor
                emptyDrop.addArrangedSubview(empty)
                columnsRow.addArrangedSubview(emptyDrop)
            } else {
                for (columnIndex, column) in ws.columns.enumerated() {
                    let colStack = OverviewDropStackView(workspaceID: def.id, columnIndex: columnIndex, owner: self)
                    colStack.orientation = .vertical
                    colStack.spacing = 6
                    colStack.addArrangedSubview(OverviewColumnHeader(workspaceID: def.id, columnIndex: columnIndex))
                    for wid in column.windows {
                        let name = windowsByID[wid]?.appName ?? wid.token
                        let tile = OverviewWindowCard(windowID: wid, owner: self)
                        tile.boxType = .custom
                        tile.fillColor = NSColor.white.withAlphaComponent(0.12)
                        tile.borderColor = NSColor.white.withAlphaComponent(0.25)
                        tile.cornerRadius = 6
                        tile.title = ""

                        let content = NSStackView()
                        content.orientation = .vertical
                        content.spacing = 4
                        content.alignment = .centerX
                        content.translatesAutoresizingMaskIntoConstraints = false

                        if canThumb {
                            let imageView = NSImageView()
                            imageView.imageScaling = .scaleProportionallyUpOrDown
                            imageView.wantsLayer = true
                            imageView.layer?.cornerRadius = 4
                            imageView.layer?.masksToBounds = true
                            imageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                            content.addArrangedSubview(imageView)
                            imageView.translatesAutoresizingMaskIntoConstraints = false
                            NSLayoutConstraint.activate([
                                imageView.widthAnchor.constraint(equalToConstant: 140),
                                imageView.heightAnchor.constraint(equalToConstant: 84)
                            ])
                            pendingThumbs.append((imageView, wid.windowNumber))
                        }

                        let label = NSTextField(labelWithString: name)
                        label.textColor = .white
                        label.font = .systemFont(ofSize: 12)
                        label.alignment = .center
                        label.maximumNumberOfLines = 2
                        content.addArrangedSubview(label)

                        let actions = NSStackView()
                        actions.orientation = .horizontal
                        actions.spacing = 4
                        actions.addArrangedSubview(OverviewWindowDragHandle(windowID: wid))
                        let move = NSPopUpButton()
                        move.addItem(withTitle: "Mover…")
                        for destination in definitions {
                            move.addItem(withTitle: destination.name)
                            move.lastItem?.representedObject = destination.id
                        }
                        move.target = actionBridge
                        move.action = #selector(OverviewActionBridge.moveWindow(_:))
                        move.identifier = NSUserInterfaceItemIdentifier(wid.token)
                        actions.addArrangedSubview(move)
                        let close = NSButton(title: "Fechar", target: actionBridge, action: #selector(OverviewActionBridge.closeWindow(_:)))
                        close.identifier = NSUserInterfaceItemIdentifier(wid.token)
                        actions.addArrangedSubview(close)
                        content.addArrangedSubview(actions)

                        tile.contentView?.addSubview(content)
                        if let cv = tile.contentView {
                            NSLayoutConstraint.activate([
                                content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 6),
                                content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -6),
                                content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6),
                                content.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6),
                                tile.widthAnchor.constraint(equalToConstant: 152),
                                tile.heightAnchor.constraint(greaterThanOrEqualToConstant: canThumb ? 110 : 72)
                            ])
                        }
                        colStack.addArrangedSubview(tile)
                    }
                    columnsRow.addArrangedSubview(colStack)
                }
            }

            let liveIDs = Set(windowsByID.keys)
            let savedRefs = (savedLayouts[def.id]?.columns.flatMap(\.windows) ?? []) + (savedLayouts[def.id]?.floating ?? [])
            let missingApps = savedRefs.filter { ref in
                !liveIDs.contains(where: { $0.token == ref.token })
                    && !windowsByID.values.contains(where: { window in
                        guard let bundleID = ref.bundleID else { return false }
                        return window.bundleID == bundleID && (ref.title.isEmpty || window.title == ref.title)
                    })
            }
            for ref in missingApps {
                guard let bundleID = ref.bundleID, !bundleID.isEmpty else { continue }
                let relaunch = NSButton(
                    title: "Reabrir \(ref.appName.isEmpty ? bundleID : ref.appName)",
                    target: actionBridge,
                    action: #selector(OverviewActionBridge.launchApp(_:))
                )
                relaunch.identifier = NSUserInterfaceItemIdentifier("\(bundleID)|\(def.id)")
                stack.addArrangedSubview(relaunch)
            }

            let open = NSButton(
                title: "Abrir workspace \(def.name)",
                target: actionBridge,
                action: #selector(OverviewActionBridge.pick(_:))
            )
            open.identifier = NSUserInterfaceItemIdentifier(def.id)
            stack.addArrangedSubview(columnsRow)
            stack.addArrangedSubview(open)
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: rect.width)
        ])
        scroll.documentView = container
        panel.contentView = scroll
        panel.orderFrontRegardless()

        window?.orderOut(nil)
        window = panel
        isVisible = true

        for (imageView, windowNumber) in pendingThumbs {
            Task { @MainActor in
                guard self.isVisible else { return }
                if let thumb = await Permissions.thumbnail(windowNumber: windowNumber, maxWidth: 140) {
                    imageView.image = thumb
                }
            }
        }
    }

    fileprivate func pick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSelectWorkspace?(id)
        hide()
    }

    fileprivate func moveWindow(_ sender: NSPopUpButton) {
        guard let token = sender.identifier?.rawValue,
              let destination = sender.selectedItem?.representedObject as? String,
              let id = WindowID(token: token) else { return }
        onMoveWindow?(id, destination)
    }

    fileprivate func closeWindow(_ sender: NSButton) {
        guard let token = sender.identifier?.rawValue, let id = WindowID(token: token) else { return }
        onCloseWindow?(id)
    }

    fileprivate func launchApp(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let separator = raw.lastIndex(of: "|"),
              separator > raw.startIndex else { return }
        let bundleID = String(raw[..<separator])
        let workspaceID = String(raw[raw.index(after: separator)...])
        onLaunchApp?(bundleID, workspaceID)
    }

    fileprivate func acceptDrop(_ raw: String, workspaceID: String, columnIndex: Int) {
        if raw.hasPrefix("column|") {
            let fields = raw.split(separator: "|")
            guard fields.count == 3, String(fields[1]) == workspaceID,
                  let source = Int(fields[2]) else { return }
            onReorderColumn?(workspaceID, source, columnIndex)
        } else if let id = WindowID(token: raw) {
            onMoveWindowToColumn?(id, workspaceID, columnIndex)
        }
    }

    public func hide() {
        window?.orderOut(nil)
        window = nil
        isVisible = false
    }
}

private final class OverviewActionBridge: NSObject {
    nonisolated(unsafe) weak var owner: OverviewController?

    @objc func pick(_ sender: NSButton) {
        let owner = self.owner
        let addr = Int(bitPattern: Unmanaged.passUnretained(sender).toOpaque())
        Task { @MainActor in
            guard let owner,
                  let ptr = UnsafeRawPointer(bitPattern: addr) else { return }
            let button = Unmanaged<NSButton>.fromOpaque(ptr).takeUnretainedValue()
            owner.pick(button)
        }
    }

    @objc func moveWindow(_ sender: NSPopUpButton) {
        let owner = self.owner
        let addr = Int(bitPattern: Unmanaged.passUnretained(sender).toOpaque())
        Task { @MainActor in
            guard let owner, let ptr = UnsafeRawPointer(bitPattern: addr) else { return }
            owner.moveWindow(Unmanaged<NSPopUpButton>.fromOpaque(ptr).takeUnretainedValue())
        }
    }

    @objc func closeWindow(_ sender: NSButton) {
        let owner = self.owner
        let addr = Int(bitPattern: Unmanaged.passUnretained(sender).toOpaque())
        Task { @MainActor in
            guard let owner, let ptr = UnsafeRawPointer(bitPattern: addr) else { return }
            owner.closeWindow(Unmanaged<NSButton>.fromOpaque(ptr).takeUnretainedValue())
        }
    }

    @objc func launchApp(_ sender: NSButton) {
        let owner = self.owner
        let addr = Int(bitPattern: Unmanaged.passUnretained(sender).toOpaque())
        Task { @MainActor in
            guard let owner, let ptr = UnsafeRawPointer(bitPattern: addr) else { return }
            owner.launchApp(Unmanaged<NSButton>.fromOpaque(ptr).takeUnretainedValue())
        }
    }
}

private final class OverviewWindowCard: NSBox, NSDraggingSource {
    private let windowID: WindowID
    private weak var owner: OverviewController?
    private var mouseOrigin: NSPoint?
    private var didBeginDragging = false

    init(windowID: WindowID, owner: OverviewController) {
        self.windowID = windowID
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        mouseOrigin = event.locationInWindow
        didBeginDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didBeginDragging, let mouseOrigin,
              hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y) > 5 else { return }
        didBeginDragging = true
        let item = NSPasteboardItem()
        item.setString(windowID.token, forType: .string)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: bitmapImage())
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    private func bitmapImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            layer?.render(in: context)
        }
        image.unlockFocus()
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

private final class OverviewColumnHeader: NSTextField, NSDraggingSource {
    private let payload: String

    init(workspaceID: String, columnIndex: Int) {
        payload = "column|\(workspaceID)|\(columnIndex)"
        super.init(frame: .zero)
        stringValue = "Coluna \(columnIndex + 1) · arraste para reordenar"
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        textColor = .secondaryLabelColor
        font = .systemFont(ofSize: 11, weight: .medium)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(payload, forType: .string)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: stringValue as NSString)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

private final class OverviewWindowDragHandle: NSTextField, NSDraggingSource {
    private let token: String

    init(windowID: WindowID) {
        token = windowID.token
        super.init(frame: .zero)
        stringValue = "↕ Arrastar"
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        textColor = .secondaryLabelColor
        font = .systemFont(ofSize: 11, weight: .medium)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(token, forType: .string)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: stringValue as NSString)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

@MainActor
private final class OverviewDropStackView: NSStackView {
    private let workspaceID: String
    private let columnIndex: Int
    private weak var owner: OverviewController?

    init(workspaceID: String, columnIndex: Int, owner: OverviewController) {
        self.workspaceID = workspaceID
        self.columnIndex = columnIndex
        self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .string) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let raw = sender.draggingPasteboard.string(forType: .string) else { return false }
        owner?.acceptDrop(raw, workspaceID: workspaceID, columnIndex: columnIndex)
        return true
    }
}
