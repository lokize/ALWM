import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum SensorsPanelController {
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
        let store = SensorsStore.shared
        let root = SensorsPanelView()
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

struct SensorsPanelView: View {
    @ObservedObject private var store = SensorsStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: SensorsSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.sensors.title"), systemImage: "thermometer.medium")

                HStack {
                    Text(t("plugin.sensors.unit"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $store.useFahrenheit) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                    .labelsHidden()
                }

                if !snap.present {
                    Text(t("plugin.sensors.absent"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    if let primary = snap.primaryCelsius {
                        HStack {
                            StatsRingGauge(
                                value: ringFraction(primary),
                                label: StatsFormat.temperature(primary, useFahrenheit: store.useFahrenheit),
                                color: tempColor(primary)
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("plugin.sensors.primary"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(StatsFormat.temperature(primary, useFahrenheit: store.useFahrenheit))
                                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                                Text("\(snap.readings.count) \(t("plugin.sensors.count"))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    StatsSectionHeader(t("plugin.sensors.section.temperature"))
                    ForEach(Array(snap.grouped.enumerated()), id: \.offset) { _, pair in
                        let (group, list) = pair
                        Text(groupTitle(group))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(list) { reading in
                            StatsSensorRow(
                                name: reading.name,
                                value: StatsFormat.temperature(
                                    reading.celsius,
                                    useFahrenheit: store.useFahrenheit
                                )
                            )
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

    private func groupTitle(_ group: SensorsSampler.Group) -> String {
        switch group {
        case .cpu: return t("plugin.sensors.group.cpu")
        case .gpu: return t("plugin.sensors.group.gpu")
        case .pmu: return t("plugin.sensors.group.pmu")
        case .battery: return t("plugin.sensors.group.battery")
        case .nand: return t("plugin.sensors.group.nand")
        case .airport: return t("plugin.sensors.group.airport")
        case .ambient: return t("plugin.sensors.group.ambient")
        case .other: return t("plugin.sensors.group.other")
        }
    }

    private func ringFraction(_ celsius: Double) -> Double {
        // Map ~20…95 °C into a soft ring.
        min(max((celsius - 20) / 75.0, 0), 1)
    }

    private func tempColor(_ celsius: Double) -> Color {
        if celsius >= 85 { return StatsColors.system }
        if celsius >= 70 { return StatsColors.performance }
        return StatsColors.accent
    }
}
