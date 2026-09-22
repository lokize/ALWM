import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum CPUPanelController {
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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-cpu")
        let store = CPUStore.shared
        let root = CPUPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 560
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

struct CPUPanelView: View {
    @ObservedObject private var store = CPUStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: CPUSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.cpu.title"))

                HStack(spacing: 16) {
                    StatsRingGauge(
                        value: tempFraction,
                        label: StatsFormat.celsius(snap.temperatureCelsius),
                        color: StatsColors.accent
                    )
                    StatsRingGauge(
                        value: snap.totalUsage,
                        label: StatsFormat.percent(snap.totalUsage * 100),
                        color: StatsColors.system
                    )
                    StatsRingGauge(
                        value: loadFraction,
                        label: StatsFormat.load(snap.load1),
                        color: StatsColors.idle
                    )
                }
                .frame(maxWidth: .infinity)

                StatsSectionHeader(t("plugin.cpu.section.history"))
                StatsHistoryChart(values: store.history)
                StatsCoreBars(cores: snap.coreUsages, efficiencyCount: snap.efficiencyCoreCount)

                StatsSectionHeader(t("plugin.cpu.section.details"))
                StatsDetailRow(t("plugin.cpu.detail.system"), value: StatsFormat.percent(snap.systemUsage * 100), swatch: StatsColors.system)
                StatsDetailRow(t("plugin.cpu.detail.user"), value: StatsFormat.percent(snap.userUsage * 100), swatch: StatsColors.user)
                StatsDetailRow(t("plugin.cpu.detail.idle"), value: StatsFormat.percent(snap.idleUsage * 100), swatch: StatsColors.idle)
                if snap.efficiencyCoreCount > 0 {
                    StatsDetailRow(
                        t("plugin.cpu.detail.efficiency"),
                        value: StatsFormat.percent(snap.efficiencyUsage * 100),
                        swatch: StatsColors.efficiency
                    )
                }
                if snap.performanceCoreCount > 0 {
                    StatsDetailRow(
                        t("plugin.cpu.detail.performance"),
                        value: StatsFormat.percent(snap.performanceUsage * 100),
                        swatch: StatsColors.performance
                    )
                }
                StatsDetailRow(
                    t("plugin.cpu.detail.uptime"),
                    value: StatsFormat.uptime(
                        seconds: snap.uptimeSeconds,
                        daysWord: t("plugin.cpu.uptime.days"),
                        hoursWord: t("plugin.cpu.uptime.hours")
                    )
                )

                StatsSectionHeader(t("plugin.cpu.section.load"))
                StatsDetailRow(t("plugin.cpu.load.1"), value: StatsFormat.load(snap.load1))
                StatsDetailRow(t("plugin.cpu.load.5"), value: StatsFormat.load(snap.load5))
                StatsDetailRow(t("plugin.cpu.load.15"), value: StatsFormat.load(snap.load15))

                if hasFrequency {
                    StatsSectionHeader(t("plugin.cpu.section.frequency"))
                    StatsDetailRow(
                        t("plugin.cpu.freq.all"),
                        value: StatsFormat.mhz(snap.frequencyAllMHz ?? 0)
                    )
                    if snap.efficiencyCoreCount > 0 {
                        StatsDetailRow(
                            t("plugin.cpu.detail.efficiency"),
                            value: StatsFormat.mhz(snap.frequencyEfficiencyMHz ?? 0),
                            swatch: StatsColors.efficiency
                        )
                    }
                    if snap.performanceCoreCount > 0 {
                        StatsDetailRow(
                            t("plugin.cpu.detail.performance"),
                            value: StatsFormat.mhz(snap.frequencyPerformanceMHz ?? 0),
                            swatch: StatsColors.performance
                        )
                    }
                }

                StatsSectionHeader(t("plugin.cpu.section.processes"))
                HStack {
                    Text(t("plugin.cpu.processes.name"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(t("plugin.cpu.processes.usage"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if snap.topProcesses.isEmpty {
                    Text(t("plugin.cpu.processes.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(snap.topProcesses) { proc in
                        StatsProcessRow(
                            name: proc.name,
                            value: StatsFormat.percent(proc.usage * 100, digits: 1),
                            icon: StatsProcessIcon.icon(forProcessName: proc.name)
                        )
                    }
                }
            }
            .padding(14)
        }
        .pluginPanelChrome(cornerRadius: 12)
    }

    private var tempFraction: Double {
        guard let t = snap.temperatureCelsius else { return 0 }
        return min(max(t / 100.0, 0), 1)
    }

    private var loadFraction: Double {
        let n = Double(max(ProcessInfo.processInfo.processorCount, 1))
        return min(max(snap.load1 / n, 0), 1)
    }

    private var hasFrequency: Bool {
        snap.frequencyAllMHz != nil
            || snap.frequencyEfficiencyMHz != nil
            || snap.frequencyPerformanceMHz != nil
    }
}
