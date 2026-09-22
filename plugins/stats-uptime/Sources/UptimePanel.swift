import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum UptimePanelController {
    private static var window: NSPanel?

    static func close() {
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        if let window, window.isVisible {
            PluginPanelOutsideClick.stop(for: window)
            window.orderOut(nil)
            return
        }
        open(anchoredTo: geometry)
    }

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-uptime")
        let store = UptimeStore.shared
        let root = UptimePanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 280
        let height: CGFloat = 280
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
        PluginPanelAnchor.attachBeforePresenting(win, size: NSSize(width: width, height: height), to: geo)
        win.orderFront(nil)
        window = win
        PluginPanelAnchor.attachAfterPresenting(win, size: NSSize(width: width, height: height), to: geo)
        _ = store
        PluginPanelOutsideClick.watch(win)
    }
}

struct UptimePanelView: View {
    @ObservedObject private var store = UptimeStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: UptimeSampler.Snapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsPopoverHeader(title: t("plugin.uptime.title"), systemImage: "clock")

            Text(UptimeStore.compactUptime(snap.uptimeSeconds))
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)

            Text(
                StatsFormat.uptime(
                    seconds: snap.uptimeSeconds,
                    daysWord: t("plugin.uptime.days"),
                    hoursWord: t("plugin.uptime.hours")
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)

            StatsSectionHeader(t("plugin.uptime.section.details"))
            StatsDetailRow(
                t("plugin.uptime.detail.uptime"),
                value: detailedUptime(snap.uptimeSeconds)
            )
            StatsDetailRow(
                t("plugin.uptime.detail.boot"),
                value: bootFormatted
            )
            StatsDetailRow(
                t("plugin.uptime.detail.boot_relative"),
                value: bootRelative
            )
        }
        .padding(14)
        .pluginPanelChrome(cornerRadius: 12)
    }

    private var bootFormatted: String {
        guard let boot = snap.bootDate else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: loc)
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: boot)
    }

    private var bootRelative: String {
        guard let boot = snap.bootDate else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: loc)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: boot, relativeTo: Date())
    }

    private func detailedUptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if days > 0 {
            return String(format: "%dd %02dh %02dm %02ds", days, hours, minutes, secs)
        }
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        }
        return String(format: "%dm %02ds", minutes, secs)
    }
}
