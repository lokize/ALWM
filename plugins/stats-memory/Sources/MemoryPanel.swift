import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum MemoryPanelController {
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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-memory")
        let store = MemoryStore.shared
        let root = MemoryPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 600
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

struct MemoryPanelView: View {
    @ObservedObject private var store = MemoryStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: MemorySampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.memory.title"), systemImage: "memorychip")

                HStack(spacing: 16) {
                    StatsRingGauge(
                        value: snap.usageFraction,
                        label: StatsFormat.percent(snap.usageFraction * 100),
                        color: pressureColor
                    )
                    StatsRingGauge(
                        value: freeFraction,
                        label: StatsFormat.bytes(snap.freeBytes, digits: 0),
                        color: StatsColors.efficiency
                    )
                    StatsRingGauge(
                        value: swapFraction,
                        label: snap.swapUsedBytes > 0
                            ? StatsFormat.bytes(snap.swapUsedBytes, digits: 0)
                            : t("plugin.memory.swap.none"),
                        color: StatsColors.performance
                    )
                }
                .frame(maxWidth: .infinity)

                StatsSectionHeader(t("plugin.memory.section.history"))
                StatsHistoryChart(
                    values: store.history,
                    fill: pressureColor.opacity(0.28),
                    line: pressureColor
                )

                StatsSectionHeader(t("plugin.memory.section.details"))
                StatsDetailRow(
                    t("plugin.memory.detail.used"),
                    value: "\(StatsFormat.bytes(snap.usedBytes)) / \(StatsFormat.bytes(snap.totalBytes))",
                    swatch: pressureColor
                )
                StatsDetailRow(
                    t("plugin.memory.detail.app"),
                    value: StatsFormat.bytes(snap.appBytes),
                    swatch: StatsColors.user
                )
                StatsDetailRow(
                    t("plugin.memory.detail.wired"),
                    value: StatsFormat.bytes(snap.wiredBytes),
                    swatch: StatsColors.system
                )
                StatsDetailRow(
                    t("plugin.memory.detail.compressed"),
                    value: StatsFormat.bytes(snap.compressedBytes),
                    swatch: StatsColors.performance
                )
                StatsDetailRow(
                    t("plugin.memory.detail.cached"),
                    value: StatsFormat.bytes(snap.cachedBytes),
                    swatch: StatsColors.efficiency
                )
                StatsDetailRow(
                    t("plugin.memory.detail.free"),
                    value: StatsFormat.bytes(snap.freeBytes),
                    swatch: StatsColors.idle
                )
                StatsDetailRow(
                    t("plugin.memory.detail.swap"),
                    value: StatsFormat.bytes(snap.swapUsedBytes)
                )
                StatsDetailRow(
                    t("plugin.memory.detail.pressure"),
                    value: pressureLabel,
                    swatch: pressureColor
                )

                StatsSectionHeader(t("plugin.memory.section.processes"))
                processesSection
            }
            .padding(14)
        }
        .pluginPanelChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private var processesSection: some View {
        HStack {
            Text(t("plugin.memory.processes.name"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(t("plugin.memory.processes.usage"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        if snap.topProcesses.isEmpty {
            Text(t("plugin.memory.processes.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(snap.topProcesses) { proc in
                processRow(proc)
            }
            Text(t("plugin.memory.processes.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func processRow(_ proc: MemorySampler.ProcessUsage) -> some View {
        let label = proc.isOthers ? t("plugin.memory.processes.others") : proc.name
        let icon: NSImage? = proc.isOthers
            ? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            : StatsProcessIcon.icon(forProcessName: proc.name)
        return StatsProcessRow(
            name: label,
            value: StatsFormat.bytes(proc.residentBytes, digits: 0),
            icon: icon
        )
    }

    private var freeFraction: Double {
        guard snap.totalBytes > 0 else { return 0 }
        return min(max(Double(snap.freeBytes) / Double(snap.totalBytes), 0), 1)
    }

    private var swapFraction: Double {
        guard snap.totalBytes > 0 else { return 0 }
        return min(max(Double(snap.swapUsedBytes) / Double(snap.totalBytes), 0), 1)
    }

    private var pressureColor: Color {
        switch snap.pressure {
        case .normal: return StatsColors.accent
        case .warn: return StatsColors.performance
        case .critical: return StatsColors.system
        }
    }

    private var pressureLabel: String {
        switch snap.pressure {
        case .normal: return t("plugin.memory.pressure.normal")
        case .warn: return t("plugin.memory.pressure.warn")
        case .critical: return t("plugin.memory.pressure.critical")
        }
    }
}
