import AppKit
import Combine
import SwiftUI

@MainActor
public final class StatusPopoverController {
    private var popover = NSPopover()
    private let model = StatusMenuModel()
    private var hostingController: NSHostingController<StatusMenuView>?
    private var updateResizeCancellable: AnyCancellable?
    private var contentHeightCancellable: AnyCancellable?
    private var wallpaperCancellable: AnyCancellable?
    private var upcomingWallpaperCancellable: AnyCancellable?
    private var wallpaperRotationCancellable: AnyCancellable?
    private var wallpaperHistoryCancellable: AnyCancellable?
    /// Survives workspace-bar re-renders so toggles don't dismiss the menu when the chip is rebuilt.
    private let anchorWindow: NSWindow
    private let anchorView: NSView
    private var pendingShowWorkItem: DispatchWorkItem?
    private var popoverCloseBridge: PopoverCloseBridge?

    public var onToggleFocusFollowsMouse: (() -> Void)?
    public var onToggleBorders: (() -> Void)?
    public var onToggleWorkspaceBar: (() -> Void)?
    public var onTogglePreventSleep: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenPlugins: (() -> Void)?
    public var onWhatsNew: (() -> Void)?
    public var onResetRuntime: (() -> Void)?
    public var onRestartClearing: (() -> Void)?
    public var onPalette: (() -> Void)?
    public var onQuake: (() -> Void)?
    public var onNotepad: (() -> Void)?
    public var onOpenNote: ((UUID) -> Void)?
    public var onCaptureRegion: (() -> Void)?
    public var onCaptureDisplay: (() -> Void)?
    public var onCaptureRecordToggle: (() -> Void)?
    public var onRelayout: (() -> Void)?
    public var onOverview: (() -> Void)?
    public var onUndo: (() -> Void)?
    public var onColorPalette: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onNextWallpaper: (() -> Void)?
    public var onPreviousWallpaper: (() -> Void)?
    public var onWallpaperRotationChange: ((Bool, Double, WallpaperIntervalUnit) -> Void)?
    public var onListEnvironmentProfiles: (() -> [EnvironmentProfileSummary])?
    public var onSaveEnvironmentProfile: ((String) -> Bool)?
    public var onApplyEnvironmentProfile: ((String) -> Bool)?

    public var isShown: Bool { popover.isShown }

    public init() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.contentView = view
        anchorView = view
        anchorWindow = win

        // Semitransient: stays open while flipping toggles / chrome refresh in-app;
        // still closes on outside click. Transient + bar chip rebuild was auto-dismissing.
        popover.behavior = .semitransient
        popover.animates = true
        let bridge = PopoverCloseBridge { [weak self] in
            self?.removeClickOutsideMonitor()
            self?.anchorWindow.orderOut(nil)
        }
        popoverCloseBridge = bridge
        popover.delegate = bridge
        installContent()
        wallpaperCancellable = WallpaperController.shared.$activeWallpaper
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                self.model.activeWallpaper = payload
                if self.popover.isShown { self.resizeToFit() }
            }
        upcomingWallpaperCancellable = WallpaperController.shared.$upcomingWallpaper
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                self.model.upcomingWallpaper = payload
                if self.popover.isShown { self.resizeToFit() }
            }
        wallpaperRotationCancellable = WallpaperController.shared.$rotationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.model.rotationStatus = status
            }
        wallpaperHistoryCancellable = WallpaperController.shared.$canGoToPreviousWallpaper
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoBack in
                self?.model.canGoToPreviousWallpaper = canGoBack
            }
        updateResizeCancellable = AppUpdateService.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.resizeToFit()
            }
        contentHeightCancellable = model.$contentHeight
            .removeDuplicates { abs($0 - $1) < 1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.resizeToFit()
            }
    }

    public func update(
        focusFollowsMouse: Bool,
        borders: Bool,
        workspaceBar: Bool,
        preventSleep: Bool,
        developerMode: Bool,
        version: String,
        isRecording: Bool = false,
        recentNotes: [NotePreview] = [],
        environmentProfiles: [EnvironmentProfileSummary]? = nil
    ) {
        let profiles = environmentProfiles ?? onListEnvironmentProfiles?() ?? model.environmentProfiles
        let changed =
            model.focusFollowsMouse != focusFollowsMouse
            || model.bordersEnabled != borders
            || model.workspaceBarEnabled != workspaceBar
            || model.preventSleep != preventSleep
            || model.developerMode != developerMode
            || model.version != version
            || model.isRecording != isRecording
            || model.recentNotes != recentNotes
            || model.environmentProfiles != profiles
        guard changed else { return }
        model.focusFollowsMouse = focusFollowsMouse
        model.bordersEnabled = borders
        model.workspaceBarEnabled = workspaceBar
        model.preventSleep = preventSleep
        model.developerMode = developerMode
        model.version = version
        model.isRecording = isRecording
        model.recentNotes = recentNotes
        model.environmentProfiles = profiles
        if !profiles.contains(where: { $0.id == model.selectedEnvironmentProfileID }) {
            model.selectedEnvironmentProfileID = profiles.first?.id ?? ""
        }
        resizeToFit()
    }

    public func toggle(relativeTo button: NSStatusBarButton) {
        toggle(relativeTo: button as NSView)
    }

    /// Anchor the menu under any view (workspace-bar status chip or menu-bar icon).
    public func toggle(relativeTo view: NSView) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if popover.isShown {
            close()
            return
        }
        AppUpdateService.shared.checkForUpdates()
        resizeToFit()
        placeAnchor(under: view)
        // Defer past the opening mouse-up — otherwise transient/semitransient treats it as
        // an outside click and closes immediately (common with custom status-bar overlays).
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.popover.show(
                relativeTo: self.anchorView.bounds,
                of: self.anchorView,
                preferredEdge: .minY
            )
            NSApp.activate(ignoringOtherApps: true)
            // Next turn — avoid treating the opening click as an outside dismiss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.installClickOutsideMonitor()
            }
        }
        pendingShowWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    public func close() {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        removeClickOutsideMonitor()
        popover.performClose(nil)
        anchorWindow.orderOut(nil)
    }

    private var clickOutsideGlobal: Any?
    private var clickOutsideLocal: Any?
    private var clickOutsideBridge: StatusMenuClickOutsideBridge?

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        let bridge = StatusMenuClickOutsideBridge { [weak self] point in
            self?.dismissIfClickOutside(at: point)
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

    private func dismissIfClickOutside(at loc: CGPoint) {
        guard popover.isShown else { return }
        if let win = popover.contentViewController?.view.window {
            if win.frame.insetBy(dx: -4, dy: -4).contains(loc) { return }
        }
        // Ignore the tiny anchor under the status chip that opened the menu.
        if anchorWindow.frame.insetBy(dx: -12, dy: -12).contains(loc) { return }
        close()
    }

    private func placeAnchor(under view: NSView) {
        guard let window = view.window else {
            // Fallback: 1×1 under the cursor.
            let p = NSEvent.mouseLocation
            anchorWindow.setFrame(NSRect(x: p.x, y: p.y - 1, width: 1, height: 1), display: true)
            anchorWindow.orderFrontRegardless()
            return
        }
        let local = view.convert(view.bounds, to: nil)
        var screen = window.convertToScreen(local)
        // Prefer a non-empty rect so AppKit has a real edge to attach under.
        if screen.width < 1 { screen.size.width = 1 }
        if screen.height < 1 { screen.size.height = 1 }
        anchorWindow.setFrame(screen, display: true)
        anchorWindow.orderFrontRegardless()
    }

    private func installContent() {
        let root = StatusMenuView(
            model: model,
            menuWidth: StatusMenuLayout.menuWidth,
            onToggleFocus: { [weak self] in self?.onToggleFocusFollowsMouse?() },
            onToggleBorders: { [weak self] in self?.onToggleBorders?() },
            onToggleBar: { [weak self] in self?.onToggleWorkspaceBar?() },
            onTogglePreventSleep: { [weak self] in self?.onTogglePreventSleep?() },
            onSettings: { [weak self] in self?.close(); self?.onOpenSettings?() },
            onPlugins: { [weak self] in self?.close(); self?.onOpenPlugins?() },
            onWhatsNew: { [weak self] in self?.close(); self?.onWhatsNew?() },
            onReset: { [weak self] in self?.close(); self?.onResetRuntime?() },
            onRestart: { [weak self] in self?.close(); self?.onRestartClearing?() },
            onPalette: { [weak self] in self?.close(); self?.onPalette?() },
            onQuake: { [weak self] in self?.close(); self?.onQuake?() },
            onNotepad: { [weak self] in self?.close(); self?.onNotepad?() },
            onOpenNote: { [weak self] id in self?.close(); self?.onOpenNote?(id) },
            onCaptureRegion: { [weak self] in self?.close(); self?.onCaptureRegion?() },
            onCaptureDisplay: { [weak self] in self?.close(); self?.onCaptureDisplay?() },
            onCaptureRecordToggle: { [weak self] in self?.close(); self?.onCaptureRecordToggle?() },
            onRelayout: { [weak self] in
                self?.close()
                // After popover dismiss — sync close + soft relayout used to no-op on settled frames.
                DispatchQueue.main.async { self?.onRelayout?() }
            },
            onOverview: { [weak self] in self?.close(); self?.onOverview?() },
            onUndo: { [weak self] in self?.close(); self?.onUndo?() },
            onColorPalette: { [weak self] in self?.close(); self?.onColorPalette?() },
            onNextWallpaper: { [weak self] in self?.onNextWallpaper?() },
            onPreviousWallpaper: { [weak self] in self?.onPreviousWallpaper?() },
            onWallpaperRotationChange: { [weak self] enabled, value, unit in
                self?.onWallpaperRotationChange?(enabled, value, unit)
            },
            onListEnvironmentProfiles: { [weak self] in self?.onListEnvironmentProfiles?() ?? [] },
            onSaveEnvironmentProfile: { [weak self] name in self?.onSaveEnvironmentProfile?(name) ?? false },
            onApplyEnvironmentProfile: { [weak self] id in
                self?.close()
                _ = self?.onApplyEnvironmentProfile?(id)
            },
            onQuit: { [weak self] in self?.close(); self?.onQuit?() },
            onCloseMenu: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: root)
        hostingController = hosting
        popover.contentViewController = hosting
        resizeToFit()
    }

    /// Cap height to the screen under the cursor so small displays can scroll instead of clipping.
    /// Always hug content on large screens — never stretch to fill the display.
    private func resizeToFit() {
        guard let hosting = hostingController else { return }
        let maxH = StatusMenuLayout.maxHeight
        let width = StatusMenuLayout.menuWidth
        var root = hosting.rootView
        root.menuWidth = width
        hosting.rootView = root
        popover.contentSize = NSSize(
            width: width,
            height: StatusMenuLayout.viewportHeight(contentHeight: model.contentHeight, maximum: maxH)
        )
    }
}

/// Keeps MainActor isolation off the NSPopoverDelegate path.
private final class PopoverCloseBridge: NSObject, NSPopoverDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}

/// Click-outside monitors (same pattern as CommandPalette / plugins overlays).
final class StatusMenuClickOutsideBridge: @unchecked Sendable {
    private let onClick: @MainActor (CGPoint) -> Void

    init(onClick: @escaping @MainActor (CGPoint) -> Void) {
        self.onClick = onClick
    }

    func installGlobal() -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            // Global events have no in-process window; AppKit reports screen coordinates.
            let point = event.locationInWindow
            Task { @MainActor in self.onClick(point) }
        }
    }

    func installLocal() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let point = event.locationInWindow
            let windowNumber = event.windowNumber
            Task { @MainActor in
                let screenPoint = NSApp.window(withWindowNumber: windowNumber)?
                    .convertPoint(toScreen: point) ?? point
                self.onClick(screenPoint)
            }
            return event
        }
    }
}

enum StatusMenuLayout {
    static func width(visibleFrameWidth: CGFloat) -> CGFloat {
        max(1, min(620, floor(visibleFrameWidth - 32)))
    }

    static func viewportHeight(contentHeight: CGFloat, maximum: CGFloat) -> CGFloat {
        guard contentHeight.isFinite, contentHeight > 0 else { return max(1, maximum) }
        return max(1, min(ceil(contentHeight), maximum))
    }

    static var menuWidth: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return width(visibleFrameWidth: screen?.visibleFrame.width ?? 800)
    }

    static func maxHeight(visibleFrameHeight: CGFloat) -> CGFloat {
        max(1, floor(visibleFrameHeight - 16))
    }

    static var maxHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame.height ?? 700
        return maxHeight(visibleFrameHeight: visible)
    }
}

private struct StatusMenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
final class StatusMenuModel: ObservableObject {
    @Published var contentHeight: CGFloat = 0
    @Published var focusFollowsMouse = false
    @Published var bordersEnabled = true
    @Published var workspaceBarEnabled = true
    @Published var preventSleep = false
    @Published var developerMode = false
    @Published var version = AlwmVersion.string
    @Published var isRecording = false
    @Published var recentNotes: [NotePreview] = []
    @Published var activeWallpaper: WallpaperNotificationContent.Payload?
    @Published var upcomingWallpaper: WallpaperNotificationContent.Payload?
    @Published var canGoToPreviousWallpaper = false
    @Published var rotationStatus = WallpaperController.shared.rotationStatus
    @Published var environmentProfiles: [EnvironmentProfileSummary] = []
    @Published var selectedEnvironmentProfileID = ""
    @Published var environmentProfileName = ""
    @Published var environmentProfileStatus = ""
}

private enum StatusMenuTheme {
    static let accent = Color(red: 0.31, green: 0.76, blue: 0.97) // #4FC3F7
    static let rowRadius: CGFloat = 10
    static let sectionGap: CGFloat = 6
}

struct StatusMenuView: View {
    @ObservedObject var model: StatusMenuModel
    var menuWidth: CGFloat
    @ObservedObject private var loc = LocalizationController.shared
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var github = GitHubProjectService.shared
    var onToggleFocus: () -> Void
    var onToggleBorders: () -> Void
    var onToggleBar: () -> Void
    var onTogglePreventSleep: () -> Void
    var onSettings: () -> Void
    var onPlugins: () -> Void
    var onWhatsNew: () -> Void
    var onReset: () -> Void
    var onRestart: () -> Void
    var onPalette: () -> Void
    var onQuake: () -> Void
    var onNotepad: () -> Void
    var onOpenNote: (UUID) -> Void
    var onCaptureRegion: () -> Void
    var onCaptureDisplay: () -> Void
    var onCaptureRecordToggle: () -> Void
    var onRelayout: () -> Void
    var onOverview: () -> Void
    var onUndo: () -> Void
    var onColorPalette: () -> Void
    var onNextWallpaper: () -> Void
    var onPreviousWallpaper: () -> Void
    var onWallpaperRotationChange: (Bool, Double, WallpaperIntervalUnit) -> Void
    var onListEnvironmentProfiles: () -> [EnvironmentProfileSummary]
    var onSaveEnvironmentProfile: (String) -> Bool
    var onApplyEnvironmentProfile: (String) -> Void
    var onQuit: () -> Void
    var onCloseMenu: () -> Void = {}

    var body: some View {
        let maxH = StatusMenuLayout.maxHeight
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: StatusMenuTheme.sectionGap) {
                header
                headerUpdateBanner

                controlsSection

                if model.developerMode {
                    sectionBlock(title: L10n.t("menu.developer")) {
                        actionRow(title: L10n.t("menu.reset_runtime"), systemImage: "arrow.counterclockwise", action: onReset)
                        actionRow(title: L10n.t("menu.restart_clearing"), systemImage: "arrow.triangle.2.circlepath", action: onRestart)
                    }
                }

                toolsSection

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: StatusMenuTheme.sectionGap) {
                        wallpaperSection
                        environmentProfileSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: StatusMenuTheme.sectionGap) {
                        supportSection
                        quitButton
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(8)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: StatusMenuContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(width: menuWidth, height: viewportHeight(maxHeight: maxH), alignment: .top)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .onPreferenceChange(StatusMenuContentHeightKey.self) { height in
            guard height.isFinite, height > 0, abs(model.contentHeight - height) >= 1 else { return }
            model.contentHeight = height
        }
        .alwmLocalized()
    }

    private func viewportHeight(maxHeight: CGFloat) -> CGFloat {
        StatusMenuLayout.viewportHeight(contentHeight: model.contentHeight, maximum: maxHeight)
    }

    private var toolsSection: some View {
        sectionBlock(title: L10n.t("menu.tools")) {
            if !model.recentNotes.isEmpty {
                Text(L10n.t("menu.notepad.recent"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)],
                    spacing: 4
                ) {
                    ForEach(model.recentNotes.prefix(4)) { note in
                        notePreviewCard(note)
                    }
                }
                .padding(.bottom, 3)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)],
                spacing: 0
            ) {
                actionRow(title: L10n.t("menu.command_palette"), systemImage: "command", action: onPalette)
                actionRow(title: L10n.t("menu.quake"), systemImage: "terminal", action: onQuake)
                actionRow(title: L10n.t("menu.color_palette"), systemImage: "paintpalette", action: onColorPalette)
                actionRow(title: L10n.t("menu.notepad"), systemImage: "note.text", action: onNotepad)
                actionRow(title: L10n.t("menu.capture.region"), systemImage: "crop", action: onCaptureRegion)
                actionRow(title: L10n.t("menu.capture.display"), systemImage: "rectangle.dashed", action: onCaptureDisplay)
                actionRow(title: "Visão geral", systemImage: "rectangle.3.group", action: onOverview)
                actionRow(title: "Desfazer janela", systemImage: "arrow.uturn.backward", action: onUndo)
                actionRow(
                    title: model.isRecording ? L10n.t("menu.capture.record_stop") : L10n.t("menu.capture.record"),
                    systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
                    action: onCaptureRecordToggle
                )
                actionRow(title: L10n.t("menu.relayout"), systemImage: "rectangle.split.3x1", action: onRelayout)
                navRow(title: L10n.t("menu.settings"), systemImage: "gearshape", action: onSettings)
                navRow(title: L10n.t("menu.plugins"), systemImage: "puzzlepiece.extension", action: onPlugins)
            }

            navRow(title: L10n.t("menu.whats_new"), systemImage: "sparkles", action: onWhatsNew)
                .padding(.top, 3)
        }
    }

    private var environmentProfileSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("Perfil de ambiente")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Picker("Perfil", selection: $model.selectedEnvironmentProfileID) {
                        ForEach(model.environmentProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.environmentProfiles.isEmpty)
                    Button("Carregar") { onApplyEnvironmentProfile(model.selectedEnvironmentProfileID) }
                        .disabled(model.selectedEnvironmentProfileID.isEmpty)
                }
                HStack(spacing: 6) {
                    Button("Salvar") {
                        guard let profile = model.environmentProfiles.first(where: { $0.id == model.selectedEnvironmentProfileID }) else { return }
                        let saved = onSaveEnvironmentProfile(profile.name)
                        model.environmentProfileStatus = saved ? "Perfil atualizado." : "Não foi possível salvar o perfil."
                        model.environmentProfiles = onListEnvironmentProfiles()
                    }
                    .disabled(model.selectedEnvironmentProfileID.isEmpty)
                    TextField("Novo perfil", text: $model.environmentProfileName)
                        .textFieldStyle(.roundedBorder)
                    Button("Criar") {
                        let name = model.environmentProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
                        guard !model.environmentProfiles.contains(where: { $0.id == id }) else {
                            model.environmentProfileStatus = "Esse perfil já existe. Selecione-o e use Salvar para atualizá-lo."
                            return
                        }
                        if onSaveEnvironmentProfile(name) {
                            model.environmentProfiles = onListEnvironmentProfiles()
                            model.selectedEnvironmentProfileID = id
                            model.environmentProfileName = ""
                            model.environmentProfileStatus = "Perfil criado com o ambiente atual."
                        } else {
                            model.environmentProfileStatus = "Não foi possível criar o perfil."
                        }
                    }
                    .disabled(model.environmentProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !model.environmentProfileStatus.isEmpty {
                    Text(model.environmentProfileStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Papel de parede")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if let wallpaper = model.activeWallpaper {
                        WallpaperThumbnailView(url: wallpaper.wallpaperURL, side: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wallpaper.subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(wallpaper.body)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .help(wallpaper.wallpaperURL.path)
                        }
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nenhum papel de parede ativo")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Ative o gerenciamento nas configurações")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                }

                if let wallpaper = model.upcomingWallpaper {
                    HStack(spacing: 6) {
                        Text("A seguir")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        WallpaperThumbnailView(url: wallpaper.wallpaperURL, side: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wallpaper.subtitle)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(wallpaper.body)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .help(wallpaper.wallpaperURL.path)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 2)
                    .accessibilityElement(children: .combine)
                }

                Divider().opacity(0.5)

                Toggle("Troca automática", isOn: Binding(
                    get: { model.rotationStatus.rotationEnabled },
                    set: { enabled in
                        onWallpaperRotationChange(
                            enabled,
                            model.rotationStatus.intervalSeconds,
                            model.rotationStatus.intervalUnit
                        )
                    }
                ))
                .font(.system(size: 10, weight: .medium))
                .toggleStyle(.switch)
                .controlSize(.mini)

                HStack(spacing: 6) {
                    Text("Atualizar a cada")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Intervalo", value: Binding(
                        get: { intervalDisplayValue },
                        set: { value in
                            onWallpaperRotationChange(
                                model.rotationStatus.rotationEnabled,
                                model.rotationStatus.intervalUnit.intervalSeconds(from: value),
                                model.rotationStatus.intervalUnit
                            )
                        }
                    ), format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 48)
                        .textFieldStyle(.roundedBorder)
                    Picker("Unidade do intervalo", selection: Binding(
                        get: { model.rotationStatus.intervalUnit },
                        set: { unit in
                            onWallpaperRotationChange(
                                model.rotationStatus.rotationEnabled,
                                model.rotationStatus.intervalSeconds,
                                unit
                            )
                        }
                    )) {
                        ForEach(WallpaperIntervalUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!model.rotationStatus.rotationEnabled)

                Text(rotationCountdownText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Button(action: onPreviousWallpaper) {
                        Label("Anterior", systemImage: "backward.end.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canGoToPreviousWallpaper)
                    .help("Voltar ao papel de parede anterior")

                    Button(action: onNextWallpaper) {
                        Label("Próximo", systemImage: "forward.end.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.activeWallpaper == nil)
                    .help("Passar para o próximo papel de parede")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var intervalDisplayValue: Double {
        model.rotationStatus.intervalUnit.displayValue(from: model.rotationStatus.intervalSeconds)
    }

    private var rotationCountdownText: String {
        guard model.rotationStatus.rotationEnabled else { return "Troca automática desativada" }
        guard model.activeWallpaper != nil else { return "Aguardando papel de parede" }
        return WallpaperRotationStatus.nextChangeText(
            secondsRemaining: model.rotationStatus.secondsUntilNextChange
        ) ?? "Aguardando papel de parede"
    }

    private var header: some View {
        HStack(spacing: 8) {
            AlwmLogoImage(side: 32, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("ALWM")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("v\(AlwmVersion.installed)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if case .available = updates.phase, let latest = updates.latestVersion {
                        Text(L10n.tf("menu.update.badge", latest))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AlwmUpdateChrome.green)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AlwmUpdateChrome.green.opacity(0.18))
                            )
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                headerGitHubActions
                headerUpdateAction
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.bottom, 2)
        .onAppear {
            github.refreshIfNeeded()
        }
    }

    private var headerGitHubActions: some View {
        HStack(spacing: 4) {
            Button {
                github.starOrOpen()
            } label: {
                HStack(spacing: 3) {
                    if case .starring = github.phase {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: github.isStarred ? "star.fill" : "star")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(github.isStarred ? Color.yellow : Color.primary.opacity(0.85))
                    }
                    Text(github.formattedStarCount)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(github.phase == .starring)
            .help(L10n.t(github.isStarred ? "menu.github.starred.help" : "menu.github.star.help"))
            .accessibilityLabel(L10n.tf("menu.github.stars.a11y", github.formattedStarCount))

            Button {
                github.openRepository()
            } label: {
                Text(L10n.t("menu.github"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L10n.t("menu.github.open.help"))
            .accessibilityLabel(L10n.t("menu.github.open.help"))
        }
    }

    @ViewBuilder
    private var headerUpdateAction: some View {
        switch updates.phase {
        case .available:
            AlwmUpdateButton(mini: true) {
                updates.installUpdate()
            }
        case .downloading, .installing:
            ProgressView()
                .controlSize(.mini)
        case .failed(_) where updates.isUpdateAvailable:
            AlwmUpdateButton(mini: true) {
                updates.installUpdate()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var headerUpdateBanner: some View {
        switch updates.phase {
        case .available:
            EmptyView()
        case .downloading:
            updateProgressBanner(L10n.t("about.update.downloading"))
        case .installing:
            updateProgressBanner(L10n.t("about.update.installing"))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tf("about.update.failed", message))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.t("about.update.retry")) {
                        updates.checkForUpdates(force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if updates.isUpdateAvailable {
                        AlwmUpdateButton(compact: true) {
                            updates.installUpdate()
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.12))
            )
        default:
            EmptyView()
        }
    }

    private func updateProgressBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(L10n.t("menu.controls"))
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ],
                spacing: 6
            ) {
                toggleCard(
                    title: L10n.t("menu.focus_follows_mouse"),
                    subtitle: L10n.t("menu.focus_follows_mouse.sub"),
                    systemImage: "cursorarrow.click",
                    isOn: model.focusFollowsMouse,
                    action: onToggleFocus
                )
                toggleCard(
                    title: L10n.t("menu.window_borders"),
                    subtitle: L10n.t("menu.window_borders.sub"),
                    systemImage: "square.dashed",
                    isOn: model.bordersEnabled,
                    action: onToggleBorders
                )
                toggleCard(
                    title: L10n.t("menu.workspace_bar"),
                    subtitle: L10n.t("menu.workspace_bar.sub"),
                    systemImage: "menubar.rectangle",
                    isOn: model.workspaceBarEnabled,
                    action: onToggleBar
                )
                toggleCard(
                    title: L10n.t("menu.prevent_sleep"),
                    subtitle: L10n.t("menu.prevent_sleep.sub"),
                    systemImage: "cup.and.saucer.fill",
                    isOn: model.preventSleep,
                    action: onTogglePreventSleep
                )
            }
        }
    }

    private func sectionBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)
            VStack(spacing: 2) {
                content()
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func toggleCard(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? StatusMenuTheme.accent.opacity(0.2) : Color.primary.opacity(0.06))
                            .frame(width: 26, height: 26)
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isOn ? StatusMenuTheme.accent : Color.secondary)
                    }
                    Spacer(minLength: 4)
                    StatusMenuSwitch(isOn: isOn)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: StatusMenuTheme.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(isOn ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StatusMenuTheme.rowRadius, style: .continuous)
                    .strokeBorder(
                        isOn ? StatusMenuTheme.accent.opacity(0.35) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func navRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StatusMenuTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: StatusMenuTheme.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private func actionRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func notePreviewCard(_ note: NotePreview) -> some View {
        Button {
            onOpenNote(note.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(note.excerpt)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(note.updatedAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.t("menu.quit"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color.red.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: StatusMenuTheme.rowRadius, style: .continuous)
                    .fill(Color.red.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StatusMenuTheme.rowRadius, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(L10n.t("menu.support"))
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.t("menu.support.body"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                StripeBuyButtonView(onOpenCheckout: onCloseMenu)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

/// Custom switch: clearer on/off, accent when enabled.
private struct StatusMenuSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? StatusMenuTheme.accent : Color.primary.opacity(0.18))
                .frame(width: 42, height: 24)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                .frame(width: 20, height: 20)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L10n.t("menu.on") : L10n.t("menu.off"))
    }
}
