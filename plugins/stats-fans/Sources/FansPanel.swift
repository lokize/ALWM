import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum FansPanelController {
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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.stats-fans")
        let store = FansStore.shared
        let root = FansPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 360
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

struct FansPanelView: View {
    @ObservedObject private var store = FansStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: FansSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                StatsPopoverHeader(title: t("plugin.fans.title"), systemImage: "fan")

                if !snap.present {
                    Text(t("plugin.fans.absent"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    if let rpm = snap.primaryRPM {
                        HStack(spacing: 16) {
                            StatsRingGauge(
                                value: snap.primaryFraction ?? 0,
                                label: "\(Int(rpm.rounded()))",
                                color: StatsColors.accent
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("plugin.fans.primary"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("\(Int(rpm.rounded())) \(t("plugin.fans.rpm"))")
                                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                if let frac = snap.primaryFraction {
                                    Text(StatsFormat.percent(frac * 100))
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    StatsSectionHeader(t("plugin.fans.section.fans"))
                    ForEach(snap.fans) { fan in
                        fanRow(fan)
                    }
                }
            }
            .padding(14)
        }
        .pluginPanelChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private func fanRow(_ fan: FansSampler.Fan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fan.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(fan.rpm.rounded())) \(t("plugin.fans.rpm"))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(StatsColors.accent)
                        .frame(width: max(4, geo.size.width * fan.fraction))
                }
            }
            .frame(height: 4)
            HStack {
                Text("\(Int(fan.minRPM.rounded()))–\(Int(fan.maxRPM.rounded())) \(t("plugin.fans.rpm"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(StatsFormat.percent(fan.fraction * 100))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
