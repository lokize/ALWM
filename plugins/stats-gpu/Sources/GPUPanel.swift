import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum GPUPanelController {
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
        let store = GPUStore.shared
        let root = GPUPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 500
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
        } else {
            win.center()
        }

        win.orderFront(nil)
        window = win
        _ = store
        PluginPanelOutsideClick.watch(win)
    }
}

struct GPUPanelView: View {
    @ObservedObject private var store = GPUStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: GPUSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.gpu.title"), systemImage: "cpu")

                if !snap.present {
                    Text(t("plugin.gpu.absent"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    HStack(spacing: 16) {
                        StatsRingGauge(
                            value: snap.utilization,
                            label: StatsFormat.percent(snap.utilization * 100),
                            color: utilColor
                        )
                        StatsRingGauge(
                            value: snap.renderUtilization ?? 0,
                            label: snap.renderUtilization.map { StatsFormat.percent($0 * 100) } ?? "—",
                            color: StatsColors.user
                        )
                        StatsRingGauge(
                            value: snap.tilerUtilization ?? 0,
                            label: snap.tilerUtilization.map { StatsFormat.percent($0 * 100) } ?? "—",
                            color: StatsColors.performance
                        )
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        legendDot(utilColor, t("plugin.gpu.ring.device"))
                        legendDot(StatsColors.user, t("plugin.gpu.ring.render"))
                        legendDot(StatsColors.performance, t("plugin.gpu.ring.tiler"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                    StatsSectionHeader(t("plugin.gpu.section.history"))
                    StatsHistoryChart(
                        values: store.history,
                        fill: utilColor.opacity(0.28),
                        line: utilColor
                    )

                    StatsSectionHeader(t("plugin.gpu.section.details"))
                    StatsDetailRow(t("plugin.gpu.detail.model"), value: snap.model)
                    StatsDetailRow(
                        t("plugin.gpu.detail.cores"),
                        value: snap.coreCount.map(String.init) ?? "—"
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.utilization"),
                        value: StatsFormat.percent(snap.utilization * 100),
                        swatch: utilColor
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.render"),
                        value: snap.renderUtilization.map { StatsFormat.percent($0 * 100) } ?? "—",
                        swatch: StatsColors.user
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.tiler"),
                        value: snap.tilerUtilization.map { StatsFormat.percent($0 * 100) } ?? "—",
                        swatch: StatsColors.performance
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.memory_used"),
                        value: snap.memoryUsedBytes.map { StatsFormat.bytes($0) } ?? "—"
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.memory_alloc"),
                        value: snap.memoryAllocatedBytes.map { StatsFormat.bytes($0) } ?? "—"
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.ane"),
                        value: snap.aneUtilization.map { StatsFormat.percent($0 * 100) } ?? "—"
                    )
                    StatsDetailRow(
                        t("plugin.gpu.detail.fps"),
                        value: snap.fps.map { String(format: "%.0f", $0) } ?? "—"
                    )
                }
            }
            .padding(14)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(2)
    }

    private var utilColor: Color {
        if snap.utilization >= 0.85 { return StatsColors.system }
        if snap.utilization >= 0.55 { return StatsColors.performance }
        return StatsColors.accent
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }
}
