import AppKit
import Foundation

@MainActor
public final class OverviewController {
    private var window: NSWindow?
    private let actionBridge = OverviewActionBridge()
    public private(set) var isVisible = false
    public var onSelectWorkspace: ((String) -> Void)?

    public init() {
        actionBridge.owner = self
    }

    public func toggle(
        monitor: MonitorInfo,
        definitions: [WorkspaceDefinition],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        mainHeight: Double
    ) {
        if isVisible {
            hide()
        } else {
            show(monitor: monitor, definitions: definitions, workspaces: workspaces, windowsByID: windowsByID, mainHeight: mainHeight)
        }
    }

    public func show(
        monitor: MonitorInfo,
        definitions: [WorkspaceDefinition],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        mainHeight: Double
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

        let title = NSTextField(labelWithString: "Overview")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.textColor = .white
        stack.addArrangedSubview(title)

        let canThumb = Permissions.screenRecordingGranted()
        if !canThumb {
            let note = NSTextField(labelWithString: "Screen Recording not granted — showing names only")
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
                let empty = NSTextField(labelWithString: "Empty")
                empty.textColor = .secondaryLabelColor
                columnsRow.addArrangedSubview(empty)
            } else {
                for column in ws.columns {
                    let colStack = NSStackView()
                    colStack.orientation = .vertical
                    colStack.spacing = 6
                    for wid in column.windows {
                        let name = windowsByID[wid]?.appName ?? wid.token
                        let tile = NSBox()
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

            let open = NSButton(
                title: "Open workspace \(def.name)",
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
}
