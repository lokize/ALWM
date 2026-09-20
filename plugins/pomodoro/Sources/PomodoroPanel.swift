import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum PomodoroPanelController {
    private static var window: NSPanel?

    static func close() {
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(relativeTo view: NSView?) {
        if let window, window.isVisible {
            PluginPanelOutsideClick.stop(for: window)
            window.orderOut(nil)
            return
        }
        open(relativeTo: view)
    }

    static func open(relativeTo view: NSView?) {
        let root = PomodoroPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 320
        let height: CGFloat = 420
        let win = window ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
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
        win.hidesOnDeactivate = false

        if let view, let screen = view.window?.screen ?? NSScreen.main {
            let rect = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
                ?? NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 1)
            var origin = NSPoint(x: rect.midX - width / 2, y: rect.minY - height - 8)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - height - 8)
            win.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        } else if let screen = NSScreen.main {
            // Fallback when chip can't be passed across isolation — place near mouse.
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - height - 12)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - height - 8)
            win.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        } else {
            win.center()
        }

        win.orderFront(nil)
        window = win
        PluginPanelOutsideClick.watch(win)
    }
}

struct PomodoroPanelView: View {
    @ObservedObject private var store = PomodoroStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }
    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: PluginL10n.t(key, locale: loc), locale: Locale(identifier: loc), arguments: args)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            timerBlock
            controls
            Divider()
            settingsBlock
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320, height: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.barSymbol)
                .foregroundStyle(Color(nsColor: store.barTint))
            Text(t("plugin.pomodoro.title"))
                .font(.headline)
            Spacer()
            if store.isKeepingAwake {
                Label(t("plugin.pomodoro.awake.badge"), systemImage: "cup.and.saucer.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
            }
        }
    }

    private var timerBlock: some View {
        VStack(spacing: 6) {
            Text(store.phaseTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(store.barLabel)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(maxWidth: .infinity)
            Text(tf("plugin.pomodoro.today", store.completedFocusToday))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                store.toggleRunning()
            } label: {
                Label(
                    store.isRunning ? t("plugin.pomodoro.pause") : t("plugin.pomodoro.start"),
                    systemImage: store.isRunning ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: store.barTint))

            Button {
                store.skip()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .help(t("plugin.pomodoro.skip"))

            Button {
                store.resetPhase()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help(t("plugin.pomodoro.reset"))
        }
        .controlSize(.large)
    }

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("plugin.pomodoro.settings"))
                .font(.subheadline.weight(.semibold))

            Stepper(
                tf("plugin.pomodoro.focus_min", store.settings.focusMinutes),
                value: Binding(
                    get: { store.settings.focusMinutes },
                    set: { v in store.updateSettings { $0.focusMinutes = v } }
                ),
                in: 1...120
            )
            Stepper(
                tf("plugin.pomodoro.short_min", store.settings.shortBreakMinutes),
                value: Binding(
                    get: { store.settings.shortBreakMinutes },
                    set: { v in store.updateSettings { $0.shortBreakMinutes = v } }
                ),
                in: 1...60
            )
            Stepper(
                tf("plugin.pomodoro.long_min", store.settings.longBreakMinutes),
                value: Binding(
                    get: { store.settings.longBreakMinutes },
                    set: { v in store.updateSettings { $0.longBreakMinutes = v } }
                ),
                in: 1...60
            )
            Stepper(
                tf("plugin.pomodoro.cycles", store.settings.cyclesBeforeLongBreak),
                value: Binding(
                    get: { store.settings.cyclesBeforeLongBreak },
                    set: { v in store.updateSettings { $0.cyclesBeforeLongBreak = v } }
                ),
                in: 1...12
            )

            Toggle(isOn: Binding(
                get: { store.settings.keepAwakeDuringFocus },
                set: { v in store.updateSettings { $0.keepAwakeDuringFocus = v } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("plugin.pomodoro.awake.toggle"))
                    Text(t("plugin.pomodoro.awake.help"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(t("plugin.pomodoro.notify"), isOn: Binding(
                get: { store.settings.notifyOnPhaseEnd },
                set: { v in store.updateSettings { $0.notifyOnPhaseEnd = v } }
            ))

            Toggle(t("plugin.pomodoro.auto_next"), isOn: Binding(
                get: { store.settings.autoStartNext },
                set: { v in store.updateSettings { $0.autoStartNext = v } }
            ))
        }
    }
}
