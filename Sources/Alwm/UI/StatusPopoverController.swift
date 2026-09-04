import AppKit
import Combine
import SwiftUI

@MainActor
public final class StatusPopoverController {
    private var popover = NSPopover()
    private let model = StatusMenuModel()
    private var hostingController: NSHostingController<StatusMenuView>?

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
    public var onColorPalette: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init() {
        popover.behavior = .transient
        popover.animates = true
        installContent()
    }

    public func update(
        focusFollowsMouse: Bool,
        borders: Bool,
        workspaceBar: Bool,
        preventSleep: Bool,
        developerMode: Bool,
        version: String,
        isRecording: Bool = false,
        recentNotes: [NotePreview] = []
    ) {
        let changed =
            model.focusFollowsMouse != focusFollowsMouse
            || model.bordersEnabled != borders
            || model.workspaceBarEnabled != workspaceBar
            || model.preventSleep != preventSleep
            || model.developerMode != developerMode
            || model.version != version
            || model.isRecording != isRecording
            || model.recentNotes != recentNotes
        guard changed else { return }
        model.focusFollowsMouse = focusFollowsMouse
        model.bordersEnabled = borders
        model.workspaceBarEnabled = workspaceBar
        model.preventSleep = preventSleep
        model.developerMode = developerMode
        model.version = version
        model.isRecording = isRecording
        model.recentNotes = recentNotes
        resizeToFit()
    }

    public func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        resizeToFit()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        popover.performClose(nil)
    }

    private func installContent() {
        let root = StatusMenuView(
            model: model,
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
            onRelayout: { [weak self] in self?.close(); self?.onRelayout?() },
            onColorPalette: { [weak self] in self?.close(); self?.onColorPalette?() },
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
        // Propose the screen cap so ScrollView can scroll when needed; fixedSize still hugs content.
        let ideal = hosting.sizeThatFits(in: NSSize(width: 340, height: maxH))
        popover.contentSize = NSSize(
            width: max(340, ceil(ideal.width)),
            height: max(1, min(ceil(ideal.height), maxH))
        )
    }
}

private enum StatusMenuLayout {
    static var maxHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame.height ?? 700
        return max(280, floor(visible - 16))
    }
}

@MainActor
final class StatusMenuModel: ObservableObject {
    @Published var focusFollowsMouse = false
    @Published var bordersEnabled = true
    @Published var workspaceBarEnabled = true
    @Published var preventSleep = false
    @Published var developerMode = false
    @Published var version = AlwmVersion.string
    @Published var isRecording = false
    @Published var recentNotes: [NotePreview] = []
}

private enum StatusMenuTheme {
    static let accent = Color(red: 0.31, green: 0.76, blue: 0.97) // #4FC3F7
    static let rowRadius: CGFloat = 10
    static let sectionGap: CGFloat = 12
}

struct StatusMenuView: View {
    @ObservedObject var model: StatusMenuModel
    @ObservedObject private var loc = LocalizationController.shared
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
    var onColorPalette: () -> Void
    var onQuit: () -> Void
    var onCloseMenu: () -> Void = {}

    var body: some View {
        let maxH = StatusMenuLayout.maxHeight
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: StatusMenuTheme.sectionGap) {
                header

                controlsSection

                VStack(spacing: 4) {
                    navRow(title: L10n.t("menu.settings"), systemImage: "gearshape", action: onSettings)
                    navRow(title: L10n.t("menu.plugins"), systemImage: "puzzlepiece.extension", action: onPlugins)
                    navRow(title: L10n.t("menu.whats_new"), systemImage: "sparkles", action: onWhatsNew)
                }

                if model.developerMode {
                    sectionBlock(title: L10n.t("menu.developer")) {
                        actionRow(title: L10n.t("menu.reset_runtime"), systemImage: "arrow.counterclockwise", action: onReset)
                        actionRow(title: L10n.t("menu.restart_clearing"), systemImage: "arrow.triangle.2.circlepath", action: onRestart)
                    }
                }

                sectionBlock(title: L10n.t("menu.tools")) {
                    if !model.recentNotes.isEmpty {
                        Text(L10n.t("menu.notepad.recent"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)
                            ],
                            spacing: 6
                        ) {
                            ForEach(model.recentNotes.prefix(4)) { note in
                                notePreviewCard(note)
                            }
                        }
                        .padding(.bottom, 6)
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 4),
                            GridItem(.flexible(), spacing: 4)
                        ],
                        spacing: 2
                    ) {
                        actionRow(title: L10n.t("menu.command_palette"), systemImage: "command", action: onPalette)
                        actionRow(title: L10n.t("menu.quake"), systemImage: "terminal", action: onQuake)
                        actionRow(title: L10n.t("menu.color_palette"), systemImage: "paintpalette", action: onColorPalette)
                        actionRow(title: L10n.t("menu.notepad"), systemImage: "note.text", action: onNotepad)
                        actionRow(title: L10n.t("menu.capture.region"), systemImage: "crop", action: onCaptureRegion)
                        actionRow(title: L10n.t("menu.capture.display"), systemImage: "rectangle.dashed", action: onCaptureDisplay)
                        actionRow(
                            title: model.isRecording ? L10n.t("menu.capture.record_stop") : L10n.t("menu.capture.record"),
                            systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
                            action: onCaptureRecordToggle
                        )
                        actionRow(title: L10n.t("menu.relayout"), systemImage: "rectangle.split.3x1", action: onRelayout)
                    }
                }

                supportSection

                quitButton
            }
            .padding(14)
        }
        .frame(width: 340)
        // Hug content on large screens; only grow up to the visible display height.
        .frame(maxHeight: maxH, alignment: .top)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .alwmLocalized()
    }

    private var header: some View {
        HStack(spacing: 12) {
            AlwmLogoImage(side: 40, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("ALWM")
                    .font(.system(size: 16, weight: .semibold))
                        Text("v\(AlwmVersion.installed)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("menu.controls"))
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
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
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            VStack(spacing: 2) {
                content()
            }
            .padding(6)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? StatusMenuTheme.accent.opacity(0.2) : Color.primary.opacity(0.06))
                            .frame(width: 30, height: 30)
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
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
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
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
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
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func notePreviewCard(_ note: NotePreview) -> some View {
        Button {
            onOpenNote(note.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
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
            .padding(8)
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
            .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L10n.t("menu.support"))
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("menu.support.body"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                StripeBuyButtonView(onOpenCheckout: onCloseMenu)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
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
