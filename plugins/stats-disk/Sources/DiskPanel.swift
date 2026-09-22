import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum DiskPanelController {
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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-disk")
        let store = DiskStore.shared
        let root = DiskPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 580
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

struct DiskPanelView: View {
    @ObservedObject private var store = DiskStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: DiskSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.disk.title"), systemImage: "internaldrive")

                HStack(spacing: 16) {
                    StatsRingGauge(
                        value: snap.usageFraction,
                        label: StatsFormat.percent(snap.usageFraction * 100),
                        color: usageColor
                    )
                    StatsRingGauge(
                        value: freeFraction,
                        label: StatsFormat.bytes(snap.freeBytes, digits: 0),
                        color: StatsColors.efficiency
                    )
                    StatsRingGauge(
                        value: 1,
                        label: StatsFormat.bytes(snap.totalBytes, digits: 0),
                        color: StatsColors.accent
                    )
                }
                .frame(maxWidth: .infinity)

                StatsSectionHeader(t("plugin.disk.section.history"))
                StatsHistoryChart(
                    values: store.history,
                    fill: usageColor.opacity(0.28),
                    line: usageColor
                )

                StatsSectionHeader(t("plugin.disk.section.details"))
                StatsDetailRow(
                    t("plugin.disk.detail.used"),
                    value: StatsFormat.bytes(snap.usedBytes),
                    swatch: usageColor
                )
                StatsDetailRow(
                    t("plugin.disk.detail.free"),
                    value: StatsFormat.bytes(snap.freeBytes),
                    swatch: StatsColors.efficiency
                )
                StatsDetailRow(
                    t("plugin.disk.detail.total"),
                    value: StatsFormat.bytes(snap.totalBytes)
                )
                if let root = snap.root {
                    StatsDetailRow(t("plugin.disk.detail.volume"), value: root.name)
                    StatsDetailRow(t("plugin.disk.detail.mount"), value: root.path)
                }

                StatsSectionHeader(t("plugin.disk.section.volumes"))
                if snap.volumes.isEmpty {
                    Text(t("plugin.disk.volumes.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snap.volumes) { vol in
                        volumeRow(vol)
                    }
                }

                StatsSectionHeader(t("plugin.disk.section.processes"))
                processesSection
            }
            .padding(14)
        }
        .pluginPanelChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private var processesSection: some View {
        HStack {
            Text(t("plugin.disk.processes.name"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(t("plugin.disk.processes.usage"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        if snap.topProcesses.isEmpty {
            Text(t("plugin.disk.processes.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(snap.topProcesses) { proc in
                StatsProcessRow(
                    name: proc.name,
                    value: processRateLabel(proc),
                    icon: StatsProcessIcon.icon(forProcessName: proc.name)
                )
            }
        }
    }

    private func processRateLabel(_ proc: DiskSampler.ProcessUsage) -> String {
        let down = StatsFormat.compactBytesPerSecond(proc.readBytesPerSecond)
        let up = StatsFormat.compactBytesPerSecond(proc.writeBytesPerSecond)
        return "↓\(down) ↑\(up)"
    }

    private var freeFraction: Double {
        snap.root?.freeFraction ?? max(0, 1 - snap.usageFraction)
    }

    private var usageColor: Color {
        if snap.usageFraction >= 0.9 { return StatsColors.system }
        if snap.usageFraction >= 0.75 { return StatsColors.performance }
        return StatsColors.accent
    }

    @ViewBuilder
    private func volumeRow(_ vol: DiskSampler.Volume) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(vol.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(StatsFormat.percent(vol.usageFraction * 100))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(vol.isRoot ? usageColor : StatsColors.accent)
                        .frame(width: max(4, geo.size.width * vol.usageFraction))
                }
            }
            .frame(height: 4)
            HStack {
                Text("\(StatsFormat.bytes(vol.freeBytes, digits: 0)) \(t("plugin.disk.volumes.free"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(StatsFormat.bytes(vol.totalBytes, digits: 0))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
