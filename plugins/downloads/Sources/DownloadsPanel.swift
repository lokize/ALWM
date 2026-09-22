import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

private final class DownloadsKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum DownloadsPanelController {
    private static var window: DownloadsKeyPanel?

    static func close() {
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        if let window, window.isVisible {
            close()
            return
        }
        open(anchoredTo: geometry)
    }

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.downloads")
        let root = DownloadsPanelView().pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 340
        let height: CGFloat = 380

        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }

        let win = DownloadsKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .utilityWindow],
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
        win.becomesKeyOnlyIfNeeded = false
        win.isFloatingPanel = true
        window = win
        PluginPanelAnchor.attachBeforePresenting(win, size: NSSize(width: width, height: height), to: geo)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PluginPanelAnchor.attachAfterPresenting(win, size: NSSize(width: width, height: height), to: geo)
        PluginPanelOutsideClick.watch(win)
        Task { await DownloadsStore.shared.refresh() }
    }
}

struct DownloadsPanelView: View {
    @ObservedObject private var store = DownloadsStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }
    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: PluginL10n.t(key, locale: loc), locale: Locale(identifier: loc), arguments: args)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statsCards
            cleanSection
            trashSection
            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if !store.statusLine.isEmpty {
                Text(store.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340, height: 380, alignment: .topLeading)
        .pluginPanelChrome(cornerRadius: 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color(nsColor: store.barTint))
            Text(t("plugin.downloads.title"))
                .font(.headline)
            Spacer()
            if store.isRefreshing || store.isCleaning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(t("plugin.common.refresh"))
            }
        }
    }

    private var statsCards: some View {
        HStack(spacing: 8) {
            statCard(
                title: t("plugin.downloads.section.downloads"),
                count: store.downloads.itemCount,
                size: store.downloads.sizeLabel,
                icon: "arrow.down.circle",
                actionTitle: t("plugin.downloads.open"),
                action: { store.openDownloads() }
            )
            statCard(
                title: t("plugin.downloads.section.trash"),
                count: store.trash.itemCount,
                size: store.trash.sizeLabel,
                icon: "trash",
                actionTitle: t("plugin.downloads.open_trash"),
                action: { store.openTrash() }
            )
        }
    }

    private func statCard(
        title: String,
        count: Int,
        size: String,
        icon: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            Text("\(count)")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(size)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(actionTitle, action: action)
                .controlSize(.mini)
                .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var cleanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("plugin.downloads.clean.title"))
                .font(.caption.weight(.semibold))

            Picker(t("plugin.downloads.clean.age"), selection: Binding(
                get: { store.ageDays },
                set: { store.setAgeDays($0) }
            )) {
                ForEach(DownloadsAgeDays.allCases) { age in
                    Text(tf("plugin.downloads.clean.days", age.rawValue)).tag(age)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(store.isCleaning)

            Text(
                store.oldDownloadsCount == 0
                    ? t("plugin.downloads.clean.none")
                    : tf(
                        "plugin.downloads.clean.ready",
                        store.oldDownloadsCount,
                        ByteCountFormatter.string(fromByteCount: store.oldDownloadsBytes, countStyle: .file)
                    )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            Button {
                Task { await store.cleanOldDownloads() }
            } label: {
                Label(t("plugin.downloads.clean.action"), systemImage: "trash.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.oldDownloadsCount == 0 || store.isCleaning || store.isRefreshing)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var trashSection: some View {
        Button {
            Task { await store.emptyTrash() }
        } label: {
            Label(t("plugin.downloads.empty_trash"), systemImage: "trash.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(store.trash.itemCount == 0 || store.isCleaning)
    }
}
