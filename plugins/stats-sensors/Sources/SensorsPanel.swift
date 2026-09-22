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

    static func toggle(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        if let window, window.isVisible {
            PluginPanelOutsideClick.stop(for: window)
            window.orderOut(nil)
            return
        }
        open(anchoredTo: geometry)
    }

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-sensors")
        let store = SensorsStore.shared
        let root = SensorsPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 620
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
                    summaryBlock
                    alertsBlock

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
        .pluginPanelChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private var summaryBlock: some View {
        if let primary = snap.primaryCelsius {
            HStack(alignment: .top, spacing: 12) {
                StatsRingGauge(
                    value: ringFraction(primary),
                    label: StatsFormat.temperature(primary, useFahrenheit: store.useFahrenheit),
                    color: tempColor(primary)
                )
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("plugin.sensors.primary"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(StatsFormat.temperature(primary, useFahrenheit: store.useFahrenheit))
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    }
                    HStack(spacing: 6) {
                        Text(t("plugin.sensors.group.gpu"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let gpu = snap.gpuCelsius {
                            Text(StatsFormat.temperature(gpu, useFahrenheit: store.useFahrenheit))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(tempColor(gpu))
                        } else {
                            Text(t("plugin.sensors.gpu.unavailable"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text("\(snap.readings.count) \(t("plugin.sensors.count"))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var alertsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatsSectionHeader(t("plugin.sensors.section.alerts"))
            Toggle(isOn: Binding(
                get: { store.alerts.enabled },
                set: { store.setAlertsEnabled($0) }
            )) {
                Text(t("plugin.sensors.alerts.enabled"))
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.alerts.enabled {
                thresholdRow(
                    title: t("plugin.sensors.alerts.cpu"),
                    value: store.alerts.cpuThresholdCelsius,
                    onChange: { store.setCPUThreshold($0) }
                )
                thresholdRow(
                    title: t("plugin.sensors.alerts.gpu"),
                    value: store.alerts.gpuThresholdCelsius,
                    onChange: { store.setGPUThreshold($0) },
                    disabled: snap.gpuCelsius == nil
                )
                Text(t("plugin.sensors.alerts.help"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func thresholdRow(
        title: String,
        value: Double,
        onChange: @escaping (Double) -> Void,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(disabled ? .tertiary : .secondary)
                Spacer()
                Text(StatsFormat.temperature(value, useFahrenheit: store.useFahrenheit))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(disabled ? .tertiary : .primary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { onChange($0) }
                ),
                in: 50...105,
                step: 1
            )
            .disabled(disabled)
            .controlSize(.small)
        }
        .opacity(disabled ? 0.55 : 1)
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
        min(max((celsius - 20) / 75.0, 0), 1)
    }

    private func tempColor(_ celsius: Double) -> Color {
        if celsius >= 85 { return StatsColors.system }
        if celsius >= 70 { return StatsColors.performance }
        return StatsColors.accent
    }
}
