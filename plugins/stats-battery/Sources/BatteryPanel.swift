import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum BatteryPanelController {
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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-battery")
        let store = BatteryStore.shared
        let root = BatteryPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 480
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

struct BatteryPanelView: View {
    @ObservedObject private var store = BatteryStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: BatterySampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.battery.title"), systemImage: "battery.100")

                if !snap.present {
                    Text(t("plugin.battery.absent"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    HStack(spacing: 16) {
                        StatsRingGauge(
                            value: snap.percent,
                            label: StatsFormat.percent(snap.percent * 100),
                            color: chargeColor
                        )
                        StatsRingGauge(
                            value: min(snap.healthPercent ?? 0, 1),
                            label: snap.healthPercent.map { StatsFormat.percent(min($0, 1.5) * 100) } ?? "—",
                            color: StatsColors.efficiency
                        )
                        StatsRingGauge(
                            value: timeFraction,
                            label: timeLabel,
                            color: StatsColors.performance
                        )
                    }
                    .frame(maxWidth: .infinity)

                    StatsSectionHeader(t("plugin.battery.section.history"))
                    StatsHistoryChart(
                        values: store.history,
                        fill: chargeColor.opacity(0.28),
                        line: chargeColor
                    )

                    StatsSectionHeader(t("plugin.battery.section.details"))
                    StatsDetailRow(
                        t("plugin.battery.detail.charge"),
                        value: StatsFormat.percent(snap.percent * 100),
                        swatch: chargeColor
                    )
                    StatsDetailRow(
                        t("plugin.battery.detail.status"),
                        value: statusLabel
                    )
                    StatsDetailRow(
                        t("plugin.battery.detail.source"),
                        value: sourceLabel
                    )
                    StatsDetailRow(
                        t("plugin.battery.detail.time"),
                        value: detailedTimeLabel
                    )
                    StatsDetailRow(
                        t("plugin.battery.detail.cycles"),
                        value: snap.cycleCount.map(String.init) ?? "—"
                    )
                    if let design = snap.designCycleCount {
                        StatsDetailRow(
                            t("plugin.battery.detail.design_cycles"),
                            value: "\(design)"
                        )
                    }
                    StatsDetailRow(
                        t("plugin.battery.detail.health"),
                        value: snap.healthPercent.map { StatsFormat.percent($0 * 100) } ?? "—",
                        swatch: StatsColors.efficiency
                    )
                    StatsDetailRow(
                        t("plugin.battery.detail.temperature"),
                        value: StatsFormat.celsius(snap.temperatureCelsius)
                    )
                    if let current = snap.currentCapacity, let max = snap.maxCapacity {
                        StatsDetailRow(
                            t("plugin.battery.detail.capacity"),
                            value: "\(current) / \(max)"
                        )
                    }
                }
            }
            .padding(14)
        }
        .pluginPanelChrome(cornerRadius: 12)
    }

    private var chargeColor: Color {
        if snap.isCharging { return StatsColors.efficiency }
        if snap.percent < 0.2 { return StatsColors.system }
        if snap.percent < 0.4 { return StatsColors.performance }
        return StatsColors.accent
    }

    private var statusLabel: String {
        if snap.isCharged { return t("plugin.battery.status.charged") }
        if snap.isCharging { return t("plugin.battery.status.charging") }
        return t("plugin.battery.status.discharging")
    }

    private var sourceLabel: String {
        if snap.isACPowered { return t("plugin.battery.source.ac") }
        return t("plugin.battery.source.battery")
    }

    private var timeLabel: String {
        if snap.isCharging, let m = snap.timeToFullMinutes, m > 0 {
            return formatMinutes(m)
        }
        if !snap.isCharging, let m = snap.timeToEmptyMinutes, m > 0 {
            return formatMinutes(m)
        }
        return "—"
    }

    private var detailedTimeLabel: String {
        if snap.isCharging, let m = snap.timeToFullMinutes, m > 0 {
            return "\(t("plugin.battery.time.to_full")) \(formatMinutes(m))"
        }
        if !snap.isCharging, let m = snap.timeToEmptyMinutes, m > 0 {
            return "\(t("plugin.battery.time.to_empty")) \(formatMinutes(m))"
        }
        return "—"
    }

    private var timeFraction: Double {
        // Visual only — map remaining minutes into a soft 0…1 ring (cap 6h).
        let minutes: Int?
        if snap.isCharging {
            minutes = snap.timeToFullMinutes
        } else {
            minutes = snap.timeToEmptyMinutes
        }
        guard let m = minutes, m > 0 else { return 0 }
        return min(Double(m) / 360.0, 1)
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return String(format: "%dm", m)
    }
}
