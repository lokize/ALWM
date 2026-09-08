import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Workspace bar — chips and icons

extension WorkspaceBarController {

    // MARK: - Pieces

    func makePill(height: CGFloat, alpha: CGFloat) -> NSView {
        // alpha 0 → readable glass; alpha 1 → more solid (settings.backgroundOpacity).
        let solid = min(1, max(0, alpha))
        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: height).isActive = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = height / 2
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20 + solid * 0.42).cgColor
        fill.layer?.cornerRadius = height / 2
        fill.layer?.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fill)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.cornerRadius = height / 2
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.16 + solid * 0.08).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border)

        container.layer?.cornerRadius = height / 2
        container.layer?.cornerCurve = .continuous
        container.clipsToBounds = true

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fill.topAnchor.constraint(equalTo: container.topAnchor),
            fill.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            border.topAnchor.constraint(equalTo: container.topAnchor),
            border.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }


    func makeWorkspaceCluster(
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
        pillStack.spacing = max(2, 3 * scale)
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


    func appendPluginViews(
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
    func makeFocusedStatusChip(text: String, chipHeight: CGFloat, scale: CGFloat) -> NSView {
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


    func truncateStatusLabel(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars, maxChars > 1 else { return text }
        let end = text.index(text.startIndex, offsetBy: maxChars - 1)
        return String(text[..<end]) + "…"
    }


    /// Stable key for grouping icons (bundle preferred, else app name).
    func barAppKey(_ win: ManagedWindow) -> String {
        if let bid = win.bundleID, !bid.isEmpty { return bid }
        return "name:\(win.appName)"
    }


    /// Live window counts per app — same universe as the icon-click picker.
    func globalAppWindowCounts(
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
    func appsForWorkspaceBar(
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
    func floatingWindows(
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


    func makeFloatChip(
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
        chip.layer?.cornerRadius = max(6, 7 * scale)
        chip.layer?.cornerCurve = .continuous
        chip.clipsToBounds = true
        chip.layer?.borderWidth = max(1, 1.0 * scale)
        chip.layer?.borderColor = separator.cgColor
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
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
    func makeFloatAppIconButton(
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


    func makeVerticalSeparator(scale: CGFloat = 1) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = separator.cgColor
        v.layer?.cornerRadius = 0.5
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: max(0.5, 0.75 * scale)),
            v.heightAnchor.constraint(equalToConstant: max(8, 10 * scale))
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: max(3, 4 * scale)),
            v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        return wrap
    }


    func makeWorkspaceChip(
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
        chip.layer?.cornerRadius = max(6, 7 * scale)
        chip.layer?.cornerCurve = .continuous
        chip.clipsToBounds = true
        chip.isActiveWorkspace = active
        chip.accentColor = accent
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
    func makeAppIconButton(
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


    func icon(for window: ManagedWindow, size: CGFloat = 11) -> NSImage {
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


    func makeBarWindow(frame: NSRect, overlay: Bool) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = overlay ? .statusBar : .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.ignoresMouseEvents = false
        return w
    }


    func renderSignature(
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
