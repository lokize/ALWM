import AppKit
import Foundation
import AlwmPluginAPI

@MainActor
public final class WorkspaceBarController {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    /// AppKit action target (not the @MainActor controller).
    private let actionBridge = WorkspaceBarActionBridge()
    /// Skip full rebuild when the visible signature is unchanged.
    private var lastRenderSignature = ""
    private var pluginBarItems: [PluginBarItem] = []
    /// Menu-bar-style status text (workspace + focused window), shown at end of the pill when enabled.
    private var focusedStatusLabel = ""

    /// Returns live ManagedWindows for a given bundleID/appName restricted to a workspace.
    /// Used by the multi-window picker to resolve token-churn cases.
    public var onWindowsForApp: ((String?, String, String) -> [ManagedWindow])?
    public var onSelectWorkspace: ((CGDirectDisplayID, String) -> Void)?
    /// Switch workspace if needed, then focus a tiled window (layout stays put).
    public var onFocusWorkspaceWindow: ((CGDirectDisplayID, String, WindowID) -> Void)?
    public var onMoveFocusedToWorkspace: ((String, Bool) -> Void)?
    public var onMoveWindowToWorkspace: ((WindowID, String, Bool) -> Void)?
    public var onCloseWindow: ((WindowID) -> Void)?
    public var onQuitApp: ((pid_t) -> Void)?
    public var onToggleFloatWindow: ((WindowID) -> Void)?
    public var onFocusFloatingOnMonitor: ((CGDirectDisplayID) -> Void)?
    /// Opens the ALWM status menu (same as the menu-bar icon).
    public var onFocusedStatusClicked: ((NSView) -> Void)?

    /// Snapshot of workspace chips for context menus (id + display name).
    private var menuWorkspaces: [(id: String, name: String)] = []

    private let accent = NSColor(hex: "#4FC3F7") ?? .systemTeal
    private let separator = NSColor(calibratedWhite: 0.55, alpha: 0.5)
    /// Avoid NSWorkspace.iconForFile on every chrome rebuild (main-thread freeze).
    private var iconCache: [String: NSImage] = [:]
    /// Last render snapshots used to resolve multi-window app picks on icon click.
    private var lastWorkspaces: [String: WorkspaceState] = [:]
    private var lastWindowsByID: [WindowID: ManagedWindow] = [:]
    private var lastWindowWorkspace: [WindowID: String] = [:]

    public init() {
        actionBridge.owner = self
    }

    public func render(
        monitors: [MonitorInfo],
        definitions: [WorkspaceDefinition],
        activeByMonitor: [CGDirectDisplayID: String],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String] = [:],
        settings: WorkspaceBarSettings,
        mainHeight: Double,
        avoidRect: NSRect? = nil,
        pluginItems: [PluginBarItem] = [],
        focusedStatusLabel: String = ""
    ) {
        let signature = renderSignature(
            monitors: monitors,
            definitions: definitions,
            activeByMonitor: activeByMonitor,
            workspaces: workspaces,
            windowsByID: windowsByID,
            windowWorkspace: windowWorkspace,
            settings: settings,
            avoidRect: avoidRect,
            pluginItems: pluginItems,
            focusedStatusLabel: focusedStatusLabel
        )
        guard signature != lastRenderSignature else { return }
        lastRenderSignature = signature
        pluginBarItems = pluginItems
        self.focusedStatusLabel = focusedStatusLabel
        lastWorkspaces = workspaces
        lastWindowsByID = windowsByID
        lastWindowWorkspace = windowWorkspace

        guard settings.enabled else {
            hideAll()
            return
        }
        menuWorkspaces = definitions.map { ($0.id, $0.name.isEmpty ? $0.id : $0.name) }
        let ids = Set(monitors.map(\.id))
        for (id, win) in windows where !ids.contains(id) {
            win.orderOut(nil)
            windows.removeValue(forKey: id)
        }

        for mon in monitors {
            guard let screen = screen(for: mon.id) else { continue }
            let frame = screen.frame
            let visible = screen.visibleFrame
            let systemMenuHeight = max(22, frame.maxY - visible.maxY)
            let overlay = settings.position == .overlayMenuBar
            let activeID = activeByMonitor[mon.id]
            let monIdx = monitors.firstIndex(where: { $0.id == mon.id }) ?? 0
            let localDefs = WorkspaceStore.definitions(definitions, visibleOnMonitorIndex: monIdx)

            if overlay {
                renderOverlay(
                    monitor: mon,
                    monitors: monitors,
                    screenFrame: frame,
                    menuHeight: systemMenuHeight,
                    definitions: localDefs,
                    activeID: activeID,
                    workspaces: workspaces,
                    windowsByID: windowsByID,
                    windowWorkspace: windowWorkspace,
                    settings: settings,
                    avoidRect: avoidRect
                )
            } else {
                renderBelow(
                    monitor: mon,
                    monitors: monitors,
                    visible: visible,
                    definitions: localDefs,
                    activeID: activeID,
                    workspaces: workspaces,
                    windowsByID: windowsByID,
                    windowWorkspace: windowWorkspace,
                    settings: settings
                )
            }
        }
    }

    /// Compact window that only covers the workspace chips — never the system status items.
    private func renderOverlay(
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
    private func statusTitleLeadingX(avoidRect: NSRect?, screenFrame: NSRect) -> CGFloat? {
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
    private func overlayOriginX(
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

    private func renderBelow(
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

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return CGDirectDisplayID(num?.uint32Value ?? 0) == id
        }
    }

    // MARK: - Pieces

    private func makePill(height: CGFloat, alpha: CGFloat) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: alpha).cgColor
        v.layer?.cornerRadius = height / 2
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func makeWorkspaceCluster(
        definitions: [WorkspaceDefinition],
        activeID: String?,
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String],
        settings: WorkspaceBarSettings,
        monitor: MonitorInfo,
        monitors: [MonitorInfo],
        pillHeight: CGFloat,
        pillAlpha: CGFloat
    ) -> NSView {
        let scale = CGFloat(min(1.8, max(0.8, settings.widthScale)))
        let leftPill = makePill(height: pillHeight, alpha: pillAlpha)
        let pillStack = NSStackView()
        pillStack.orientation = .horizontal
        pillStack.alignment = .centerY
        pillStack.spacing = 0
        // gravityAreas keeps chips at intrinsic width — `.fill` expands one chip into empty space.
        pillStack.distribution = .gravityAreas
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        leftPill.addSubview(pillStack)

        let before = pluginBarItems.filter {
            $0.placement == .beforeWorkspaces && $0.display.matches(monitor.id)
        }
        appendPluginViews(before, to: pillStack, scale: scale, trailingSeparator: !before.isEmpty)

        // Badge matches the multi-window picker: count every live window of the app,
        // not only those on the chip's workspace (Safari often spans workspaces).
        let globalCounts = settings.showAppIcons
            ? globalAppWindowCounts(windowsByID: windowsByID)
            : [:]

        for (index, def) in definitions.enumerated() {
            if index > 0 {
                pillStack.addArrangedSubview(makeVerticalSeparator(scale: scale))
            }
            let isActive = activeID == def.id
            let ws = workspaces[def.id]
            var apps = appsForWorkspaceBar(
                workspaceID: def.id,
                workspace: ws,
                workspaces: workspaces,
                windowsByID: windowsByID,
                windowWorkspace: windowWorkspace,
                deduplicate: settings.deduplicateAppIcons
            )
            if !settings.showAppIcons { apps = [] }
            let focusedID = ws?.focusedWindowID
            let focusedBundle = focusedID.flatMap { windowsByID[$0]?.bundleID }
            // Always keep a visible affordance when labels+icons are both off.
            let label: String = {
                if settings.showLabels { return def.name }
                if !settings.showAppIcons { return def.name.isEmpty ? def.id : def.name }
                return ""
            }()
            pillStack.addArrangedSubview(
                makeWorkspaceChip(
                    name: label,
                    apps: apps,
                    appWindowCounts: globalCounts,
                    active: isActive,
                    focusedWindowID: focusedID,
                    focusedBundleID: focusedBundle,
                    monitorID: monitor.id,
                    workspaceID: def.id,
                    workspaceName: def.name.isEmpty ? def.id : def.name,
                    chipHeight: max(14, pillHeight - 4),
                    scale: scale
                )
            )
        }

        var floats = floatingWindows(
            on: monitor,
            activeWorkspaceID: activeID,
            monitors: monitors,
            workspaces: workspaces,
            windowsByID: windowsByID,
            windowWorkspace: windowWorkspace
        )
        if settings.deduplicateAppIcons {
            floats = floats.uniqued(by: \.bundleID)
        }
        if !floats.isEmpty {
            pillStack.addArrangedSubview(makeVerticalSeparator(scale: scale))
            pillStack.addArrangedSubview(
                makeFloatChip(
                    name: "⌀",
                    apps: settings.showAppIcons ? floats : [],
                    monitorID: monitor.id,
                    workspaceID: activeID ?? "",
                    chipHeight: max(14, pillHeight - 4),
                    scale: scale,
                    tooltip: floats.map { $0.title.isEmpty ? $0.appName : $0.title }.uniqued().joined(separator: ", ")
                )
            )
        }

        let afterWS = pluginBarItems.filter {
            ($0.placement == .afterWorkspaces || $0.placement == .afterCommand)
                && $0.display.matches(monitor.id)
        }
        appendPluginViews(afterWS, to: pillStack, scale: scale, leadingSeparator: true)

        if settings.showFocusedStatus {
            let label = focusedStatusLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                pillStack.addArrangedSubview(makeVerticalSeparator(scale: scale))
                pillStack.addArrangedSubview(
                    makeFocusedStatusChip(
                        text: label,
                        chipHeight: max(14, pillHeight - 4),
                        scale: scale
                    )
                )
            }
        }

        leftPill.setContentHuggingPriority(.required, for: .horizontal)
        leftPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pillStack.setHuggingPriority(.required, for: .horizontal)
        pillStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let insetX: CGFloat = 5 * scale
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: leftPill.leadingAnchor, constant: insetX),
            pillStack.trailingAnchor.constraint(equalTo: leftPill.trailingAnchor, constant: -insetX),
            pillStack.topAnchor.constraint(equalTo: leftPill.topAnchor, constant: 1),
            pillStack.bottomAnchor.constraint(equalTo: leftPill.bottomAnchor, constant: -1)
        ])
        return leftPill
    }

    private func appendPluginViews(
        _ items: [PluginBarItem],
        to stack: NSStackView,
        scale: CGFloat,
        leadingSeparator: Bool = false,
        trailingSeparator: Bool = false
    ) {
        guard !items.isEmpty else { return }
        PluginManager.shared.updateBarScale(scale)
        // Skip plugins that auto-hide (fanless Fans, no-battery, BT off, …) so we
        // don't leave orphan separators on the bar.
        var views: [NSView] = []
        views.reserveCapacity(items.count)
        for item in items {
            guard let view = PluginManager.shared.makeBarView(
                id: item.id,
                placement: item.placement,
                scale: scale
            ) else { continue }
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(view)
        }
        guard !views.isEmpty else { return }
        if leadingSeparator {
            stack.addArrangedSubview(makeVerticalSeparator(scale: scale))
        }
        for (index, view) in views.enumerated() {
            if index > 0 {
                stack.addArrangedSubview(makeVerticalSeparator(scale: scale))
            }
            stack.addArrangedSubview(view)
        }
        if trailingSeparator {
            stack.addArrangedSubview(makeVerticalSeparator(scale: scale))
        }
    }

    /// Same affordance as the menu-bar status item: brand logo + workspace/window title.
    private func makeFocusedStatusChip(text: String, chipHeight: CGFloat, scale: CGFloat) -> NSView {
        let maxChars = 28
        let display = truncateStatusLabel(text, maxChars: maxChars)
        let fontSize = max(9, 10 * scale)
        let iconSide = max(11, 12 * scale)
        let padX = max(5, 6 * scale)
        let spacing = max(3, 4 * scale)

        let btn = NSButton(title: "", target: actionBridge, action: #selector(WorkspaceBarActionBridge.focusedStatusClicked(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = AlwmBrand.logo(side: iconSide * 2)
        btn.imagePosition = .imageLeft
        btn.imageScaling = .scaleProportionallyDown
        btn.title = display
        btn.font = .systemFont(ofSize: fontSize, weight: .medium)
        btn.contentTintColor = .white
        btn.toolTip = text
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: padX),
            btn.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -padX),
            btn.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.heightAnchor.constraint(equalToConstant: chipHeight),
            btn.heightAnchor.constraint(equalToConstant: chipHeight)
        ])
        // Keep a little breathing room matching menu-bar chrome.
        _ = spacing
        return wrap
    }

    private func truncateStatusLabel(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars, maxChars > 1 else { return text }
        let end = text.index(text.startIndex, offsetBy: maxChars - 1)
        return String(text[..<end]) + "…"
    }

    /// Stable key for grouping icons (bundle preferred, else app name).
    private func barAppKey(_ win: ManagedWindow) -> String {
        if let bid = win.bundleID, !bid.isEmpty { return bid }
        return "name:\(win.appName)"
    }

    /// Live window counts per app — same universe as the icon-click picker.
    private func globalAppWindowCounts(
        windowsByID: [WindowID: ManagedWindow]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for win in windowsByID.values {
            guard !win.isScratchpad, !win.isIgnored else { continue }
            counts[barAppKey(win), default: 0] += 1
        }
        return counts
    }

    /// Windows shown as icons on a workspace chip (same filter as render + signature).
    /// Only tiled column members — floats belong on the ⌀ chip, not as ghost app icons
    /// (Safari AX siblings with home=active WS were painting Safari on empty workspaces).
    private func appsForWorkspaceBar(
        workspaceID: String,
        workspace: WorkspaceState?,
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String],
        deduplicate: Bool
    ) -> [ManagedWindow] {
        var apps = (workspace?.columns.flatMap(\.windows) ?? [])
            .compactMap { id -> ManagedWindow? in
                guard let win = windowsByID[id], !win.isScratchpad, !win.isIgnored else { return nil }
                // Floating windows must not appear as workspace icons even if still listed in a column.
                guard !win.isFloating else { return nil }
                if let home = windowWorkspace[id] {
                    guard home == workspaceID else { return nil }
                } else {
                    let holders = workspaces.compactMap { wsID, state -> String? in
                        state.columns.contains(where: { $0.windows.contains(id) }) ? wsID : nil
                    }
                    guard holders == [workspaceID] else { return nil }
                }
                return win
            }
        if deduplicate {
            apps = apps.uniqued(by: \.bundleID)
        }
        return apps
    }

    /// Floating / scratchpad / unassigned windows for the active workspace (or orphans on this monitor).
    private func floatingWindows(
        on monitor: MonitorInfo,
        activeWorkspaceID: String?,
        monitors: [MonitorInfo],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String]
    ) -> [ManagedWindow] {
        let tiledIDs: Set<WindowID> = Set(
            workspaces.values.flatMap { ws in ws.columns.flatMap(\.windows) }
        )
        return windowsByID.values
            .filter { win in
                guard !win.isIgnored else { return false }
                // Quake / scratchpads live outside tiling — never show as bar icons.
                guard !win.isScratchpad else { return false }
                let loose = win.isFloating || !tiledIDs.contains(win.id)
                guard loose else { return false }
                let home = windowWorkspace[win.id]
                if let activeWorkspaceID, let home {
                    return home == activeWorkspaceID
                }
                // No home yet: show on the monitor the window currently occupies.
                let host = monitors.first { $0.frame.contains(pointX: win.frame.midX, pointY: win.frame.midY) }
                    ?? monitors.first
                return host?.id == monitor.id
            }
            .sorted { a, b in
                if a.appName != b.appName { return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    private func makeFloatChip(
        name: String,
        apps: [ManagedWindow],
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        chipHeight: CGFloat,
        scale: CGFloat,
        tooltip: String
    ) -> NSView {
        let chip = NSButton(title: "", target: actionBridge, action: #selector(WorkspaceBarActionBridge.floatClicked(_:)))
        chip.bezelStyle = .inline
        chip.isBordered = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = max(5, 6 * scale)
        chip.clipsToBounds = true
        chip.layer?.borderWidth = max(1, 1.0 * scale)
        chip.layer?.borderColor = separator.cgColor
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        chip.identifier = NSUserInterfaceItemIdentifier("float|\(monitorID)")
        chip.toolTip = tooltip.isEmpty ? "Floating" : "Floating: \(tooltip)"

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = max(2, 3 * scale)
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.required, for: .horizontal)

        let fontSize = max(9, 10 * scale)
        let iconSize = max(10, 11 * scale)
        let padX = max(5, 6 * scale)

        if !name.isEmpty {
            let num = NSTextField(labelWithString: name)
            num.font = .systemFont(ofSize: fontSize, weight: .medium)
            num.textColor = NSColor.secondaryLabelColor
            num.isEditable = false
            num.isBezeled = false
            num.drawsBackground = false
            num.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(num)
        }

        for app in apps.prefix(4) {
            row.addArrangedSubview(
                makeFloatAppIconButton(
                    for: app,
                    monitorID: monitorID,
                    workspaceID: workspaceID,
                    size: iconSize,
                    scale: scale,
                    maxOuter: chipHeight - 2
                )
            )
        }

        chip.addSubview(row)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -padX),
            row.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: chipHeight)
        ])
        return chip
    }

    /// Clickable float icon (Finder etc.) — same focus path as tiled workspace icons.
    private func makeFloatAppIconButton(
        for app: ManagedWindow,
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        size: CGFloat,
        scale: CGFloat,
        maxOuter: CGFloat
    ) -> NSView {
        let btn = NSButton(title: "", target: actionBridge, action: #selector(WorkspaceBarActionBridge.appIconClicked(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = icon(for: app, size: size)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyUpOrDown
        let home = workspaceID.isEmpty ? "_" : workspaceID
        btn.identifier = NSUserInterfaceItemIdentifier("\(monitorID)|\(home)|\(app.id.token)")
        let tip = app.title.isEmpty ? app.appName : "\(app.appName) — \(app.title)"
        btn.toolTip = tip
        btn.menu = makeAppContextMenu(for: app, monitorID: monitorID, workspaceID: home)
        let outer = min(max(size + 2, size), maxOuter)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: outer),
            btn.heightAnchor.constraint(equalToConstant: outer)
        ])
        return btn
    }

    private func makeVerticalSeparator(scale: CGFloat = 1) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = separator.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: max(10, 12 * scale))
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: max(6, 7 * scale)),
            v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        return wrap
    }

    private func makeWorkspaceChip(
        name: String,
        apps: [ManagedWindow],
        appWindowCounts: [String: Int],
        active: Bool,
        focusedWindowID: WindowID?,
        focusedBundleID: String?,
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        workspaceName: String,
        chipHeight: CGFloat,
        scale: CGFloat = 1
    ) -> NSView {
        // Container (not a single button) so app icons can receive their own clicks.
        let chip = WorkspaceChipHoverView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = max(5, 6 * scale)
        chip.clipsToBounds = true
        chip.isActiveWorkspace = active
        chip.applyHoverAppearance()

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = max(3, 4 * scale)
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.required, for: .horizontal)

        let fontSize = max(9, 10 * scale)
        let iconSize = max(10, 11 * scale)
        let padX = max(5, 6 * scale)

        let wsButton = NSButton(title: name, target: actionBridge, action: #selector(WorkspaceBarActionBridge.workspaceClicked(_:)))
        wsButton.bezelStyle = .inline
        wsButton.isBordered = false
        wsButton.identifier = NSUserInterfaceItemIdentifier("\(monitorID)|\(workspaceID)")
        wsButton.toolTip = "Workspace \(workspaceName)"
        wsButton.font = .systemFont(ofSize: fontSize, weight: active ? .semibold : .medium)
        wsButton.contentTintColor = active ? accent : .white
        wsButton.setContentHuggingPriority(.required, for: .horizontal)
        wsButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        var wsButtonConstraints = [
            wsButton.heightAnchor.constraint(equalToConstant: chipHeight)
        ]
        if name.isEmpty {
            // Labels hidden — keep a clickable hit target beside app icons.
            wsButton.title = ""
            wsButtonConstraints.append(
                wsButton.widthAnchor.constraint(equalToConstant: max(6, 8 * scale))
            )
        }
        NSLayoutConstraint.activate(wsButtonConstraints)
        row.addArrangedSubview(wsButton)

        for app in apps.prefix(4) {
            let selected = active && (
                app.id == focusedWindowID
                    || (focusedBundleID != nil && app.bundleID == focusedBundleID)
            )
            let windowCount = appWindowCounts[barAppKey(app)] ?? 1
            row.addArrangedSubview(
                makeAppIconButton(
                    for: app,
                    monitorID: monitorID,
                    workspaceID: workspaceID,
                    size: iconSize,
                    scale: scale,
                    selected: selected,
                    maxOuter: chipHeight - 2,
                    windowCount: windowCount
                )
            )
        }

        chip.addSubview(row)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -padX),
            row.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: chipHeight)
        ])

        chip.menu = makeWorkspaceContextMenu(
            monitorID: monitorID,
            workspaceID: workspaceID,
            workspaceName: workspaceName
        )
        return chip
    }

    /// Focused app: circular accent halo (same color as the window focus border).
    /// Multi-window apps get a small count badge (Dock-style) when `windowCount > 1`.
    private func makeAppIconButton(
        for app: ManagedWindow,
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        size: CGFloat,
        scale: CGFloat,
        selected: Bool,
        maxOuter: CGFloat,
        windowCount: Int = 1
    ) -> NSView {
        let btn = NSButton(title: "", target: actionBridge, action: #selector(WorkspaceBarActionBridge.appIconClicked(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = icon(for: app, size: size)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyUpOrDown
        btn.identifier = NSUserInterfaceItemIdentifier("\(monitorID)|\(workspaceID)|\(app.id.token)")
        let baseTip = app.title.isEmpty ? app.appName : "\(app.appName) — \(app.title)"
        btn.toolTip = windowCount > 1 ? "\(baseTip) (\(windowCount) windows)" : baseTip
        btn.menu = makeAppContextMenu(for: app, monitorID: monitorID, workspaceID: workspaceID)

        let outer: CGFloat = {
            guard selected else { return size + 2 }
            return min(max(size + 4, size * 1.35), maxOuter)
        }()
        btn.wantsLayer = true
        btn.layer?.cornerRadius = outer / 2
        if selected {
            btn.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
            btn.layer?.borderWidth = max(1.0, 1.15 * scale)
            btn.layer?.borderColor = accent.cgColor
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)

        guard windowCount > 1 else {
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: outer),
                btn.heightAnchor.constraint(equalToConstant: outer)
            ])
            return btn
        }

        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.wantsLayer = true
        wrap.addSubview(btn)

        let label = windowCount > 9 ? "9+" : "\(windowCount)"
        let badgeSize = max(10, min(13, outer * 0.62))
        let badgePad = max(2, badgeSize * 0.28)
        let badge = MultiWindowCountBadge(labelWithString: label)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: max(7, badgeSize * 0.7), weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.isEditable = false
        badge.isBezeled = false
        badge.drawsBackground = false
        badge.wantsLayer = true
        // Vivid red (notification-style) — readable on teal accent / blue Safari icons.
        badge.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor
        badge.layer?.cornerRadius = badgeSize / 2
        badge.layer?.masksToBounds = true
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        wrap.addSubview(badge)

        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: outer + badgePad),
            wrap.heightAnchor.constraint(equalToConstant: outer + badgePad),
            btn.widthAnchor.constraint(equalToConstant: outer),
            btn.heightAnchor.constraint(equalToConstant: outer),
            btn.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            btn.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeSize),
            badge.heightAnchor.constraint(equalToConstant: badgeSize),
            badge.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            badge.topAnchor.constraint(equalTo: wrap.topAnchor)
        ])
        wrap.setContentHuggingPriority(.required, for: .horizontal)
        wrap.setContentCompressionResistancePriority(.required, for: .horizontal)
        return wrap
    }

    fileprivate func floatClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("float|"),
              let mon = UInt32(raw.dropFirst("float|".count)) else { return }
        onFocusFloatingOnMonitor?(CGDirectDisplayID(mon))
    }

    fileprivate func workspaceClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let mon = UInt32(parts[0]) else { return }
        onSelectWorkspace?(CGDirectDisplayID(mon), String(parts[1]))
    }

    fileprivate func focusedStatusClicked(_ sender: NSButton) {
        onFocusedStatusClicked?(sender)
    }

    fileprivate func appIconClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let mon = UInt32(parts[0]) else { return }
        let tokenParts = parts[2].split(separator: ":", maxSplits: 1).map(String.init)
        guard tokenParts.count == 2,
              let pid = Int32(tokenParts[0]),
              let winNum = Int(tokenParts[1])
        else { return }
        let clickedID = WindowID(pid: pid, windowNumber: winNum)
        let monID = CGDirectDisplayID(mon)
        let workspaceID = parts[1]

        // Try to find the representative ManagedWindow for this icon.
        // Prefer exact match; fall back to any live window with the same pid (token churn).
        let app: ManagedWindow? = lastWindowsByID[clickedID]
            ?? lastWindowsByID.values.first(where: { $0.id.pid == clickedID.pid && !$0.isIgnored })

        if let app {
            let candidates = workspaceAppCandidates(monitorID: monID, workspaceID: workspaceID, app: app)
            if candidates.count > 1 {
                let menu = makeAppPickMenu(candidates: candidates, monitorID: monID, workspaceID: workspaceID)
                let anchor = NSPoint(x: sender.bounds.midX, y: sender.bounds.maxY + 4)
                menu.popUp(positioning: nil, at: anchor, in: sender)
                return
            }
        }
        onFocusWorkspaceWindow?(monID, workspaceID, clickedID)
    }

    /// When one icon represents several windows from the same app in a workspace,
    /// offer explicit per-window selection instead of focusing an arbitrary one.
    private func workspaceAppCandidates(
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        app: ManagedWindow
    ) -> [ManagedWindow] {
        let bid = app.bundleID
        let appPID = app.id.pid

        // ── Primary: ask the WindowManager directly (most up-to-date, handles token churn) ──
        if let live = onWindowsForApp?(bid ?? "", app.appName, workspaceID), !live.isEmpty {
            return live.sorted {
                let t0 = $0.title.isEmpty ? $0.appName : $0.title
                let t1 = $1.title.isEmpty ? $1.appName : $1.title
                return t0.localizedCaseInsensitiveCompare(t1) == .orderedAscending
            }
        }

        // ── Fallback: derive from cached snapshots when the callback is unavailable ──
        var candidateIDs = Set<WindowID>()
        if let ws = lastWorkspaces[workspaceID] {
            candidateIDs.formUnion(ws.columns.flatMap(\.windows))
        }
        for (id, home) in lastWindowWorkspace where home == workspaceID {
            candidateIDs.insert(id)
        }

        func matches(_ win: ManagedWindow) -> Bool {
            guard !win.isIgnored, !win.isScratchpad else { return false }
            if let bid = bid, !bid.isEmpty { return win.bundleID == bid }
            if win.id.pid == appPID { return true }
            return win.appName == app.appName
        }

        var seen = Set<WindowID>()
        var filtered: [ManagedWindow] = []

        for id in candidateIDs {
            if let win = lastWindowsByID[id], matches(win), seen.insert(id).inserted {
                filtered.append(win)
            }
        }
        for (id, win) in lastWindowsByID {
            guard matches(win), seen.insert(id).inserted else { continue }
            let assignedWS = lastWindowWorkspace[id]
            if assignedWS == workspaceID || assignedWS == nil {
                filtered.append(win)
            }
        }

        return filtered.sorted {
            let t0 = $0.title.isEmpty ? $0.appName : $0.title
            let t1 = $1.title.isEmpty ? $1.appName : $1.title
            return t0.localizedCaseInsensitiveCompare(t1) == .orderedAscending
        }
    }

    private func makeAppPickMenu(
        candidates: [ManagedWindow],
        monitorID: CGDirectDisplayID,
        workspaceID: String
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let homes = Set(candidates.compactMap { lastWindowWorkspace[$0.id] })
        let showHomeLabel = homes.count > 1 || homes.contains(where: { $0 != workspaceID })
        for win in candidates {
            let windowTitle = win.title.isEmpty ? win.appName : win.title
            let home = lastWindowWorkspace[win.id] ?? workspaceID
            let homeName = menuWorkspaces.first(where: { $0.0 == home })?.1 ?? home
            let title = showHomeLabel ? "\(windowTitle)  ·  \(homeName)" : windowTitle
            let item = NSMenuItem(
                title: title,
                action: #selector(WorkspaceBarActionBridge.menuFocusWindow(_:)),
                keyEquivalent: ""
            )
            item.target = actionBridge
            // Pass the window's own home so focus switches to the right workspace/monitor.
            item.representedObject = "\(monitorID)|\(home)|\(win.id.token)"
            item.image = icon(for: win, size: 12)
            item.isEnabled = true
            menu.addItem(item)
        }
        return menu
    }

    private func makeWorkspaceContextMenu(
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        workspaceName: String
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let switchItem = NSMenuItem(
            title: String(format: L10n.t("wsbar.menu.switch_to"), workspaceName),
            action: #selector(WorkspaceBarActionBridge.menuSwitchWorkspace(_:)),
            keyEquivalent: ""
        )
        switchItem.target = actionBridge
        switchItem.representedObject = "\(monitorID)|\(workspaceID)"
        switchItem.isEnabled = true
        menu.addItem(switchItem)
        menu.addItem(.separator())

        let moveHere = NSMenuItem(
            title: L10n.t("wsbar.menu.move_here"),
            action: #selector(WorkspaceBarActionBridge.menuMoveFocusedHere(_:)),
            keyEquivalent: ""
        )
        moveHere.target = actionBridge
        moveHere.representedObject = workspaceID
        moveHere.isEnabled = true
        menu.addItem(moveHere)

        let moveFollow = NSMenuItem(
            title: L10n.t("wsbar.menu.move_here_follow"),
            action: #selector(WorkspaceBarActionBridge.menuMoveFocusedHereFollow(_:)),
            keyEquivalent: ""
        )
        moveFollow.target = actionBridge
        moveFollow.representedObject = workspaceID
        moveFollow.isEnabled = true
        menu.addItem(moveFollow)

        return menu
    }

    private func makeAppContextMenu(
        for app: ManagedWindow,
        monitorID: CGDirectDisplayID,
        workspaceID: String
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let token = app.id.token

        let focus = NSMenuItem(
            title: L10n.t("wsbar.menu.focus"),
            action: #selector(WorkspaceBarActionBridge.menuFocusWindow(_:)),
            keyEquivalent: ""
        )
        focus.target = actionBridge
        focus.representedObject = "\(monitorID)|\(workspaceID)|\(token)"
        focus.isEnabled = true
        menu.addItem(focus)

        menu.addItem(.separator())

        let close = NSMenuItem(
            title: L10n.t("wsbar.menu.close_window"),
            action: #selector(WorkspaceBarActionBridge.menuCloseWindow(_:)),
            keyEquivalent: ""
        )
        close.target = actionBridge
        close.representedObject = token
        close.isEnabled = true
        menu.addItem(close)

        let quitTitle = String(format: L10n.t("wsbar.menu.quit_app"), app.appName.isEmpty ? "App" : app.appName)
        let quit = NSMenuItem(
            title: quitTitle,
            action: #selector(WorkspaceBarActionBridge.menuQuitApp(_:)),
            keyEquivalent: ""
        )
        quit.target = actionBridge
        quit.representedObject = NSNumber(value: app.id.pid)
        quit.isEnabled = true
        menu.addItem(quit)

        menu.addItem(.separator())

        let floatTitle = app.isFloating ? L10n.t("wsbar.menu.tile") : L10n.t("wsbar.menu.float")
        let floatItem = NSMenuItem(
            title: floatTitle,
            action: #selector(WorkspaceBarActionBridge.menuToggleFloat(_:)),
            keyEquivalent: ""
        )
        floatItem.target = actionBridge
        floatItem.representedObject = token
        floatItem.isEnabled = true
        menu.addItem(floatItem)

        let moveSub = NSMenu(title: L10n.t("wsbar.menu.move_to"))
        moveSub.autoenablesItems = false
        for ws in menuWorkspaces where ws.id != workspaceID {
            let item = NSMenuItem(
                title: ws.name,
                action: #selector(WorkspaceBarActionBridge.menuMoveWindowToWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = actionBridge
            item.representedObject = "\(token)|\(ws.id)|0"
            item.isEnabled = true
            moveSub.addItem(item)
        }
        if !moveSub.items.isEmpty {
            let moveParent = NSMenuItem(title: L10n.t("wsbar.menu.move_to"), action: nil, keyEquivalent: "")
            moveParent.submenu = moveSub
            menu.addItem(moveParent)

            let moveFollowSub = NSMenu(title: L10n.t("wsbar.menu.move_to_follow"))
            moveFollowSub.autoenablesItems = false
            for ws in menuWorkspaces where ws.id != workspaceID {
                let item = NSMenuItem(
                    title: ws.name,
                    action: #selector(WorkspaceBarActionBridge.menuMoveWindowToWorkspace(_:)),
                    keyEquivalent: ""
                )
                item.target = actionBridge
                item.representedObject = "\(token)|\(ws.id)|1"
                item.isEnabled = true
                moveFollowSub.addItem(item)
            }
            let followParent = NSMenuItem(title: L10n.t("wsbar.menu.move_to_follow"), action: nil, keyEquivalent: "")
            followParent.submenu = moveFollowSub
            menu.addItem(followParent)
        }

        return menu
    }

    private func parseWindowToken(_ token: String) -> WindowID? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pid = Int32(parts[0]), let winNum = Int(parts[1]) else { return nil }
        return WindowID(pid: pid, windowNumber: winNum)
    }

    fileprivate func menuSwitchWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 2, let mon = UInt32(parts[0]) else { return }
        onSelectWorkspace?(CGDirectDisplayID(mon), parts[1])
    }

    fileprivate func menuMoveFocusedHere(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onMoveFocusedToWorkspace?(id, false)
    }

    fileprivate func menuMoveFocusedHereFollow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onMoveFocusedToWorkspace?(id, true)
    }

    fileprivate func menuFocusWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let mon = UInt32(parts[0]), let wid = parseWindowToken(parts[2]) else { return }
        onFocusWorkspaceWindow?(CGDirectDisplayID(mon), parts[1], wid)
    }

    fileprivate func menuCloseWindow(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, let id = parseWindowToken(token) else { return }
        onCloseWindow?(id)
    }

    fileprivate func menuQuitApp(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        onQuitApp?(pid_t(num.int32Value))
    }

    fileprivate func menuToggleFloat(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, let id = parseWindowToken(token) else { return }
        onToggleFloatWindow?(id)
    }

    fileprivate func menuMoveWindowToWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 3, let wid = parseWindowToken(parts[0]) else { return }
        let follow = parts[2] == "1"
        onMoveWindowToWorkspace?(wid, parts[1], follow)
    }

    private func icon(for window: ManagedWindow, size: CGFloat = 11) -> NSImage {
        let cacheKey = window.bundleID ?? "name:\(window.appName)"
        let sizedKey = "\(cacheKey)|\(Int(size * 10))"
        if let cached = iconCache[sizedKey] {
            return cached
        }
        if iconCache.count >= 64 {
            iconCache.removeAll(keepingCapacity: true)
        }
        let img: NSImage
        if let bid = window.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let raw = NSWorkspace.shared.icon(forFile: url.path)
            raw.size = NSSize(width: size, height: size)
            img = raw
        } else {
            img = NSImage(size: NSSize(width: size, height: size))
        }
        iconCache[sizedKey] = img
        return img
    }

    private func makeBarWindow(frame: NSRect, overlay: Bool) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = overlay ? .statusBar : .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.ignoresMouseEvents = false
        return w
    }

    public func hideAll() {
        lastRenderSignature = ""
        for (_, w) in windows { w.orderOut(nil) }
    }

    private func renderSignature(
        monitors: [MonitorInfo],
        definitions: [WorkspaceDefinition],
        activeByMonitor: [CGDirectDisplayID: String],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String],
        settings: WorkspaceBarSettings,
        avoidRect: NSRect?,
        pluginItems: [PluginBarItem],
        focusedStatusLabel: String
    ) -> String {
        var parts: [String] = []
        parts.append("pos=\(settings.position.rawValue)")
        parts.append("align=\(settings.alignment.rawValue)")
        parts.append("h=\(Int(settings.height))")
        parts.append("op=\(Int(settings.backgroundOpacity * 100))")
        parts.append("off=\(Int(settings.horizontalOffset))")
        parts.append("lbl=\(settings.showLabels)")
        parts.append("ic=\(settings.showAppIcons)")
        parts.append("dedup=\(settings.deduplicateAppIcons)")
        parts.append("fs=\(settings.showFocusedStatus)")
        parts.append("fst=\(focusedStatusLabel)")
        parts.append("ws=\(Int(settings.widthScale * 100))")
        for item in pluginItems {
            parts.append("pl:\(item.id):\(item.placement.rawString):\(item.display.rawString):\(item.signature)")
        }
        if let avoidRect {
            parts.append("av=\(Int(avoidRect.minX)),\(Int(avoidRect.width))")
        }
        for mon in monitors {
            if settings.position == .overlayMenuBar {
                parts.append(MenuBarLayout.cachedTitleToken())
                if let screen = screen(for: mon.id) {
                    let sx = statusTitleLeadingX(avoidRect: avoidRect, screenFrame: screen.frame)
                    parts.append("sx\(mon.id)=\(sx.map { Int(($0 / 16).rounded(.down)) } ?? -1)")
                }
            }
            let monIdx = monitors.firstIndex(where: { $0.id == mon.id }) ?? 0
            let localDefs = WorkspaceStore.definitions(definitions, visibleOnMonitorIndex: monIdx)
            let active = activeByMonitor[mon.id] ?? "-"
            parts.append("m\(mon.id):a\(active)")
            let globalCounts = globalAppWindowCounts(windowsByID: windowsByID)
            for def in localDefs {
                let ws = workspaces[def.id]
                parts.append("w\(def.id)")
                if let focused = ws?.focusedWindowID {
                    parts.append("f\(focused.token)")
                }
                let apps = appsForWorkspaceBar(
                    workspaceID: def.id,
                    workspace: ws,
                    workspaces: workspaces,
                    windowsByID: windowsByID,
                    windowWorkspace: windowWorkspace,
                    deduplicate: settings.deduplicateAppIcons
                )
                for win in apps.prefix(4) {
                    let n = globalCounts[barAppKey(win)] ?? 1
                    parts.append("\(win.id.token)x\(n)")
                }
            }
            let floats = floatingWindows(
                on: mon,
                activeWorkspaceID: activeByMonitor[mon.id],
                monitors: monitors,
                workspaces: workspaces,
                windowsByID: windowsByID,
                windowWorkspace: windowWorkspace
            )
            for win in floats.prefix(4) {
                parts.append("fl\(win.id.token)")
            }
        }
        return parts.joined(separator: "|")
    }
}

/// Workspace chip with dark charcoal hover (quieter fill when active and not hovered).
/// Hover via `WorkspaceChipHoverTracker` — AppKit enter/exit isn't always on the MainActor executor.
private final class WorkspaceChipHoverView: NSView {
    var isActiveWorkspace = false
    private var isHovered = false
    private var tracking: NSTrackingArea?
    private let hoverTracker = WorkspaceChipHoverTracker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverTracker.chip = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverTracker,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    fileprivate var isMouseInside: Bool {
        guard let window else { return false }
        let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(loc)
    }

    fileprivate func setHovered(_ on: Bool) {
        guard isHovered != on else { return }
        isHovered = on
        applyHoverAppearance(animated: true)
    }

    func applyHoverAppearance(animated: Bool = false) {
        wantsLayer = true
        let color: NSColor = {
            if isHovered {
                // Dark charcoal hover (covers label + icons).
                return NSColor(calibratedWhite: 0.16, alpha: 0.92)
            }
            if isActiveWorkspace {
                return NSColor.black.withAlphaComponent(0.32)
            }
            return .clear
        }()
        let apply = { self.layer?.backgroundColor = color.cgColor }
        if animated, let layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            apply()
            CATransaction.commit()
            _ = layer
        } else {
            apply()
        }
    }
}

/// Tracking-area owner; hops to MainActor from AppKit enter/exit.
private final class WorkspaceChipHoverTracker: NSObject {
    nonisolated(unsafe) weak var chip: WorkspaceChipHoverView?

    @objc func mouseEntered(_ event: NSEvent) {
        let chip = self.chip
        Task { @MainActor in
            chip?.setHovered(true)
        }
    }

    @objc func mouseExited(_ event: NSEvent) {
        let chip = self.chip
        Task { @MainActor in
            guard let chip else { return }
            chip.setHovered(chip.isMouseInside)
        }
    }
}

/// Button/menu target for the bar; hops onto MainActor.
private final class WorkspaceBarActionBridge: NSObject {
    nonisolated(unsafe) weak var owner: WorkspaceBarController?

    private func hop(_ body: @escaping @MainActor (WorkspaceBarController) -> Void) {
        let owner = self.owner
        Task { @MainActor in
            guard let owner else { return }
            body(owner)
        }
    }

    /// Pass the button via bitPattern (Sendable).
    private func hopButton(_ sender: NSButton, _ body: @escaping @MainActor (WorkspaceBarController, NSButton) -> Void) {
        let owner = self.owner
        let addr = Int(bitPattern: Unmanaged.passUnretained(sender).toOpaque())
        Task { @MainActor in
            guard let owner,
                  let ptr = UnsafeRawPointer(bitPattern: addr) else { return }
            let button = Unmanaged<NSButton>.fromOpaque(ptr).takeUnretainedValue()
            body(owner, button)
        }
    }

    private func hopMenuItem(_ sender: NSMenuItem, _ body: @escaping @MainActor (WorkspaceBarController, NSMenuItem) -> Void) {
        let owner = self.owner
        // Use bitPattern to cross the Sendable boundary safely — the item is
        // retained by the NSMenu for the lifetime of the run loop iteration.
        let addr = Int(bitPattern: Unmanaged.passRetained(sender).toOpaque())
        Task { @MainActor in
            guard let owner else {
                // Balance the retain
                _ = Unmanaged<NSMenuItem>.fromOpaque(UnsafeRawPointer(bitPattern: addr)!).takeRetainedValue()
                return
            }
            let item = Unmanaged<NSMenuItem>.fromOpaque(UnsafeRawPointer(bitPattern: addr)!).takeRetainedValue()
            body(owner, item)
        }
    }

    @objc func floatClicked(_ sender: NSButton) {
        hopButton(sender) { $0.floatClicked($1) }
    }

    @objc func workspaceClicked(_ sender: NSButton) {
        hopButton(sender) { $0.workspaceClicked($1) }
    }

    @objc func focusedStatusClicked(_ sender: NSButton) {
        hopButton(sender) { $0.focusedStatusClicked($1) }
    }

    @objc func appIconClicked(_ sender: NSButton) {
        hopButton(sender) { $0.appIconClicked($1) }
    }

    @objc func menuSwitchWorkspace(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuSwitchWorkspace($1) }
    }

    @objc func menuMoveFocusedHere(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuMoveFocusedHere($1) }
    }

    @objc func menuMoveFocusedHereFollow(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuMoveFocusedHereFollow($1) }
    }

    @objc func menuFocusWindow(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuFocusWindow($1) }
    }

    @objc func menuCloseWindow(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuCloseWindow($1) }
    }

    @objc func menuQuitApp(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuQuitApp($1) }
    }

    @objc func menuToggleFloat(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuToggleFloat($1) }
    }

    @objc func menuMoveWindowToWorkspace(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuMoveWindowToWorkspace($1) }
    }
}

/// Count badge on multi-window app icons — ignores hits so clicks reach the button below.
private final class MultiWindowCountBadge: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension Array {
    func uniqued<T: Hashable>(by key: (Element) -> T?) -> [Element] {
        var seen = Set<T>()
        return filter { el in
            guard let k = key(el) else { return true }
            return seen.insert(k).inserted
        }
    }

    func uniqued() -> [Element] where Element: Hashable {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
