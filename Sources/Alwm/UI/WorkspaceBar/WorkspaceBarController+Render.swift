import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Workspace bar — overlay/below render

extension WorkspaceBarController {

    /// Compact window that only covers the workspace chips — never the system status items.
    func renderOverlay(
        monitor: MonitorInfo,
        monitors: [MonitorInfo],
        screenFrame: NSRect,
        menuHeight: CGFloat,
        definitions: [WorkspaceDefinition],
        activeID: String?,
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String],
        settings: WorkspaceBarSettings,
        avoidRect: NSRect?
    ) {
        // Height slider controls pill size inside the system menu bar strip.
        let pillHeight = min(max(14, CGFloat(settings.height) - 4), menuHeight - 2)
        let pillAlpha = CGFloat(min(1, max(0, settings.backgroundOpacity)))
        let pill = makeWorkspaceCluster(
            definitions: definitions,
            activeID: activeID,
            workspaces: workspaces,
            windowsByID: windowsByID,
            windowWorkspace: windowWorkspace,
            settings: settings,
            monitor: monitor,
            monitors: monitors,
            pillHeight: pillHeight,
            pillAlpha: pillAlpha
        )
        pill.translatesAutoresizingMaskIntoConstraints = false

        let padX: CGFloat = 4
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: padX),
            pill.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        let naturalWidth = max(60, ceil(pill.fittingSize.width) + padX * 2)
        let gap: CGFloat = 8
        let narrow = screenFrame.width < 1480
        let leftChrome: CGFloat = narrow
            ? min(72, max(28, screenFrame.width * 0.05))
            : min(120, max(40, screenFrame.width * 0.08))
        // Keep horizontalOffset out of the clamp floor — it applies after alignment.
        let minOriginX = screenFrame.minX + leftChrome
        let documentTitleLeadingX = MenuBarLayout.documentTitleLeadingX(
            screenFrame: screenFrame,
            menuHeight: menuHeight
        )
        // Status item window lives on one screen; mirror its trailing inset onto every menu bar.
        let statusLeadingX = statusTitleLeadingX(avoidRect: avoidRect, screenFrame: screenFrame)
        var rightClearX = screenFrame.maxX - (narrow ? 64 : 96)
        if let statusLeadingX {
            rightClearX = min(rightClearX, statusLeadingX - gap)
        }
        if let titleX = documentTitleLeadingX,
           titleX > minOriginX + 40,
           titleX < rightClearX {
            rightClearX = titleX - gap
        }
        var width = naturalWidth
        let room = rightClearX - minOriginX
        if room >= 80 {
            width = min(width, room)
        }
        let height = menuHeight
        if width + 0.5 < naturalWidth {
            let cap = pill.widthAnchor.constraint(lessThanOrEqualToConstant: max(40, width - padX * 2))
            cap.isActive = true
        }

        let originX = overlayOriginX(
            barWidth: width,
            settings: settings,
            screenFrame: screenFrame,
            minOriginX: minOriginX,
            rightClearX: rightClearX
        )
        let rect = NSRect(
            x: originX,
            y: screenFrame.maxY - menuHeight,
            width: width,
            height: height
        )

        let win = windows[monitor.id] ?? makeBarWindow(frame: rect, overlay: true)
        win.level = .statusBar
        win.setFrame(rect, display: true)
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.layoutSubtreeIfNeeded()
        win.contentView = host
        win.orderFrontRegardless()
        windows[monitor.id] = win
    }


    /// Leading X of the ALWM status title on `screenFrame` (direct or mirrored from the host screen).
    func statusTitleLeadingX(avoidRect: NSRect?, screenFrame: NSRect) -> CGFloat? {
        guard let avoid = avoidRect, avoid.width > 8 else { return nil }
        if avoid.midX >= screenFrame.minX - 2, avoid.midX <= screenFrame.maxX + 2 {
            return avoid.minX
        }
        guard let host = NSScreen.screens.first(where: {
            avoid.midX >= $0.frame.minX - 2 && avoid.midX <= $0.frame.maxX + 2
        }) else { return nil }
        let insetFromTrailing = host.frame.maxX - avoid.minX
        guard insetFromTrailing > 8, insetFromTrailing < screenFrame.width - 40 else { return nil }
        return screenFrame.maxX - insetFromTrailing
    }


    /// Place the overlay pill per `settings.alignment`, clamped so it stays clear of
    /// Apple menu chrome (left) and status / document-title region (right).
    func overlayOriginX(
        barWidth: CGFloat,
        settings: WorkspaceBarSettings,
        screenFrame: NSRect,
        minOriginX: CGFloat,
        rightClearX: CGFloat
    ) -> CGFloat {
        let offset = CGFloat(settings.horizontalOffset)
        let maxOriginX = max(minOriginX, rightClearX - barWidth)

        let unclamped: CGFloat
        switch settings.alignment {
        case .left:
            unclamped = minOriginX + offset
        case .center:
            // Geometric center of this monitor — not “dock left of status item”.
            unclamped = screenFrame.midX - barWidth / 2 + offset
        case .right:
            unclamped = rightClearX - barWidth + offset
        }
        return min(max(unclamped, minOriginX), maxOriginX)
    }


    func renderBelow(
        monitor: MonitorInfo,
        monitors: [MonitorInfo],
        visible: NSRect,
        definitions: [WorkspaceDefinition],
        activeID: String?,
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String],
        settings: WorkspaceBarSettings
    ) {
        let height = max(22, min(40, CGFloat(settings.height)))
        let rect = NSRect(
            x: visible.origin.x,
            y: visible.maxY - height,
            width: visible.width,
            height: height
        )
        let win = windows[monitor.id] ?? makeBarWindow(frame: rect, overlay: false)
        win.level = .floating
        win.setFrame(rect, display: true)

        let root = NSView(frame: NSRect(origin: .zero, size: rect.size))
        root.wantsLayer = true
        root.clipsToBounds = true
        let bgAlpha = max(0, min(1, settings.backgroundOpacity))
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(bgAlpha).cgColor

        let pillHeight: CGFloat = max(14, min(26, height - 6))
        let pillAlpha = CGFloat(min(1, max(0, settings.backgroundOpacity)))
        let pill = makeWorkspaceCluster(
            definitions: definitions,
            activeID: activeID,
            workspaces: workspaces,
            windowsByID: windowsByID,
            windowWorkspace: windowWorkspace,
            settings: settings,
            monitor: monitor,
            monitors: monitors,
            pillHeight: pillHeight,
            pillAlpha: pillAlpha
        )
        pill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pill)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(line)

        var constraints: [NSLayoutConstraint] = [
            pill.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -1),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 2)
        ]
        let offset = CGFloat(settings.horizontalOffset)
        switch settings.alignment {
        case .left:
            constraints.append(pill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10 + offset))
        case .center:
            constraints.append(pill.centerXAnchor.constraint(equalTo: root.centerXAnchor, constant: offset))
        case .right:
            constraints.append(pill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10 + offset))
        }
        NSLayoutConstraint.activate(constraints)

        win.contentView = root
        win.orderFrontRegardless()
        windows[monitor.id] = win
    }


    func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return CGDirectDisplayID(num?.uint32Value ?? 0) == id
        }
    }
}
