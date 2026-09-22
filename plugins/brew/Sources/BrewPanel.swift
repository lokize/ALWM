import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

private final class BrewKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum BrewPanelController {
    private static var window: BrewKeyPanel?

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
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.brew")
        let root = BrewPanelView().pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 360
        let height: CGFloat = 440

        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }

        let win = BrewKeyPanel(
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
    }
}

struct BrewPanelView: View {
    @ObservedObject private var store = BrewStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }
    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: PluginL10n.t(key, locale: loc), locale: Locale(identifier: loc), arguments: args)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !store.brewAvailable {
                Text(t("plugin.brew.error.missing"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                actions
                list
            }
            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            if !store.statusLine.isEmpty {
                Text(store.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360, height: 440, alignment: .topLeading)
        .pluginPanelChrome(cornerRadius: 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mug.fill")
                .foregroundStyle(Color(nsColor: store.barTint))
            Text(t("plugin.brew.title"))
                .font(.headline)
            Spacer()
            if store.isRefreshing || store.isUpgrading {
                ProgressView().controlSize(.small)
            } else {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countLabel: String {
        let n = store.outdatedCount
        if n == 1 { return t("plugin.brew.count_one") }
        return tf("plugin.brew.count", n)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label(t("plugin.brew.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing || store.isUpgrading)

            Button {
                Task { await store.upgradeAll() }
            } label: {
                Label(t("plugin.brew.upgrade_all"), systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.upgradeablePackages.isEmpty || store.isRefreshing || store.isUpgrading)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var list: some View {
        Group {
            if store.packages.isEmpty && !store.isRefreshing {
                VStack(spacing: 6) {
                    Spacer(minLength: 40)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green.opacity(0.8))
                    Text(t("plugin.brew.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.packages) { pkg in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pkg.name)
                                        .font(.callout.weight(.medium))
                                    Text(packageSubtitle(pkg))
                                        .font(.caption2)
                                        .foregroundStyle(pkg.isDisabled ? .orange : .secondary)
                                }
                                Spacer(minLength: 0)
                                if pkg.isDisabled {
                                    Text(t("plugin.brew.kind.disabled"))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.orange.opacity(0.15))
                                        )
                                } else {
                                    Button(t("plugin.brew.upgrade")) {
                                        Task { await store.upgrade(pkg) }
                                    }
                                    .controlSize(.small)
                                    .disabled(store.isUpgrading || store.isRefreshing)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func packageSubtitle(_ pkg: BrewPackage) -> String {
        let kind = pkg.kind == .cask ? t("plugin.brew.kind.cask") : t("plugin.brew.kind.formula")
        if pkg.isDisabled {
            return "\(pkg.installed) → \(pkg.current) · \(kind) · \(t("plugin.brew.kind.disabled"))"
        }
        return "\(pkg.installed) → \(pkg.current) · \(kind)"
    }
}
