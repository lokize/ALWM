import AppKit
import SwiftUI
import AlwmStatsKit
import AlwmL10n
import AlwmPluginAPI

@MainActor
enum NowPlayingPanelController {
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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.now-playing")
        let store = NowPlayingStore.shared
        let root = NowPlayingPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 300
        let height: CGFloat = 420
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

struct NowPlayingPanelView: View {
    @ObservedObject private var store = NowPlayingStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    private var snap: NowPlayingSampler.Snapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StatsPopoverHeader(title: t("plugin.nowplaying.title"), systemImage: "music.note")

                if !snap.present {
                    Text(t("plugin.nowplaying.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    artworkView
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(snap.title ?? t("plugin.nowplaying.unknown_title"))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                        Text(snap.artist ?? t("plugin.nowplaying.unknown_artist"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let album = snap.album, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let app = snap.appName, !app.isEmpty {
                            Text(app)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if snap.duration != nil {
                        progressSection
                    }

                    HStack(spacing: 28) {
                        transportButton(systemName: "backward.fill") {
                            store.send(.previousTrack)
                        }
                        transportButton(
                            systemName: snap.isPlaying ? "pause.fill" : "play.fill",
                            large: true
                        ) {
                            store.send(.togglePlayPause)
                        }
                        transportButton(systemName: "forward.fill") {
                            store.send(.nextTrack)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                    if snap.appName == "Safari", snap.duration == nil {
                        Text(t("plugin.nowplaying.safari_js_hint"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(14)
        }
        .pluginPanelChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private var artworkView: some View {
        let side: CGFloat = 180
        if let data = snap.artworkData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: side, height: side)
                Image(systemName: snap.artist == "YouTube" || snap.appName == "Safari" ? "play.rectangle.fill" : "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(StatsColors.accent)
                        .frame(width: max(3, geo.size.width * snap.progress))
                }
            }
            .frame(height: 3)
            HStack {
                Text(formatTime(snap.elapsed))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(snap.duration))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func transportButton(systemName: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: large ? 22 : 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: large ? 44 : 36, height: large ? 44 : 36)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(large ? 0.10 : 0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
