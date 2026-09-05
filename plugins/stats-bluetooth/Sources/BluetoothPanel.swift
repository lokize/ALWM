import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum BluetoothPanelController {
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
        let store = BluetoothStore.shared
        let root = BluetoothPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 320
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

struct BluetoothPanelView: View {
    @ObservedObject private var store = BluetoothStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: BluetoothSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.bluetooth.title"), systemImage: "antenna.radiowaves.left.and.right")

                if !snap.poweredOn {
                    Text(t("plugin.bluetooth.off"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else if snap.devices.isEmpty {
                    Text(t("plugin.bluetooth.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    StatsSectionHeader(t("plugin.bluetooth.section.connected"))
                    if snap.connected.isEmpty {
                        Text(t("plugin.bluetooth.connected.empty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snap.connected) { device in
                            deviceCard(device, connected: true)
                        }
                    }

                    if !snap.disconnected.isEmpty {
                        StatsSectionHeader(t("plugin.bluetooth.section.paired"))
                        ForEach(snap.disconnected) { device in
                            deviceCard(device, connected: false)
                        }
                    }
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

    @ViewBuilder
    private func deviceCard(_ device: BluetoothSampler.Device, connected: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 40, height: 40)
                if let bat = device.batteryPercent {
                    Circle()
                        .trim(from: 0, to: bat)
                        .stroke(batteryColor(bat), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 40)
                    Text(StatsFormat.percent(bat * 100))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                } else {
                    Image(systemName: iconName(for: device))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(connected ? t("plugin.bluetooth.status.connected") : t("plugin.bluetooth.status.paired"))
                        .font(.system(size: 10))
                        .foregroundStyle(connected ? StatsColors.efficiency : .secondary)
                    if let category = device.category, !category.isEmpty {
                        Text("· \(category)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let rssi = device.rssi {
                    Text("RSSI \(rssi) dBm")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func batteryColor(_ value: Double) -> Color {
        if value < 0.15 { return StatsColors.system }
        if value < 0.3 { return StatsColors.performance }
        return StatsColors.efficiency
    }

    private func iconName(for device: BluetoothSampler.Device) -> String {
        let cat = (device.category ?? device.name).lowercased()
        if cat.contains("keyboard") { return "keyboard" }
        if cat.contains("trackpad") || cat.contains("mouse") { return "magicmouse.fill" }
        if cat.contains("head") || cat.contains("airpod") || cat.contains("audio")
            || cat.contains("soundcore") || cat.contains("ear") {
            return "headphones"
        }
        return "wave.3.right"
    }
}
