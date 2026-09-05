import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum NetworkPanelController {
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
        let store = NetworkStore.shared
        let root = NetworkPanelView()
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

struct NetworkPanelView: View {
    @ObservedObject private var store = NetworkStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: NetworkSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.network.title"), systemImage: "network")

                HStack(spacing: 16) {
                    rateBlock(
                        label: t("plugin.network.download"),
                        value: StatsFormat.bytesPerSecond(snap.downloadBytesPerSec),
                        color: StatsColors.download
                    )
                    rateBlock(
                        label: t("plugin.network.upload"),
                        value: StatsFormat.bytesPerSecond(snap.uploadBytesPerSec),
                        color: StatsColors.upload
                    )
                }
                .frame(maxWidth: .infinity)

                StatsSectionHeader(t("plugin.network.section.history"))
                StatsDualHistoryChart(
                    primary: store.downloadHistory,
                    secondary: store.uploadHistory
                )
                HStack(spacing: 12) {
                    legendDot(StatsColors.download, t("plugin.network.download"))
                    legendDot(StatsColors.upload, t("plugin.network.upload"))
                }

                StatsSectionHeader(t("plugin.network.section.connectivity"))
                StatsConnectivityGrid(samples: store.connectivityHistory)

                StatsSectionHeader(t("plugin.network.section.interface"))
                StatsDetailRow(
                    t("plugin.network.detail.upload_total"),
                    value: StatsFormat.bytes(snap.totalUploadBytes),
                    swatch: StatsColors.upload
                )
                StatsDetailRow(
                    t("plugin.network.detail.download_total"),
                    value: StatsFormat.bytes(snap.totalDownloadBytes),
                    swatch: StatsColors.download
                )
                HStack {
                    Text(t("plugin.network.detail.status"))
                        .font(.system(size: 12))
                    Spacer()
                    StatsStatusPill(snap.isUp ? "UP" : "DOWN", ok: snap.isUp)
                }
                .padding(.vertical, 2)
                HStack {
                    Text(t("plugin.network.detail.internet"))
                        .font(.system(size: 12))
                    Spacer()
                    StatsStatusPill(snap.internetReachable ? "UP" : "DOWN", ok: snap.internetReachable)
                }
                .padding(.vertical, 2)
                StatsDetailRow(
                    t("plugin.network.detail.latency"),
                    value: snap.latencyMs.map { String(format: "%.1f ms", $0) } ?? "—"
                )
                StatsDetailRow(
                    t("plugin.network.detail.jitter"),
                    value: snap.jitterMs.map { String(format: "%.1f ms", $0) } ?? "—"
                )

                StatsSectionHeader(t("plugin.network.section.details"))
                StatsDetailRow(t("plugin.network.detail.interface"), value: snap.displayName)
                StatsDetailRow(t("plugin.network.detail.mac"), value: snap.macAddress ?? "—")

                StatsSectionHeader(t("plugin.network.section.address"))
                StatsDetailRow(t("plugin.network.detail.ip_local"), value: snap.localIPv4 ?? snap.localIPv6 ?? "—")
                StatsDetailRow(t("plugin.network.detail.ip_public"), value: store.publicIP ?? "—")

                StatsSectionHeader(t("plugin.network.section.processes"))
                Text(t("plugin.network.processes.unavailable"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
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

    private func rateBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
