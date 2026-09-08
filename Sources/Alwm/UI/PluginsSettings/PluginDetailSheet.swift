import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Installed plugin detail sheet

struct PluginDetailSheet: View {
    let plugin: DiscoveredPlugin
    let enabled: Bool
    let installed: Bool
    let busy: Bool
    let placement: AlwmBarPlacement
    let display: PluginBarDisplay
    var onEnabled: (Bool) -> Void
    var onDownload: () -> Void
    var onUninstall: () -> Void
    var onPlacement: (AlwmBarPlacement) -> Void
    var onDisplay: (PluginBarDisplay) -> Void
    var onClose: () -> Void

    @ObservedObject var loc = LocalizationController.shared
    @State var monitors: [MonitorInfo] = []
    @State var galleryIndex: Int?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.manifest.name).font(.title2.weight(.semibold))
                        HStack(spacing: 8) {
                            Text(L10n.t(plugin.manifest.resolvedCategory.l10nKey))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                            PluginAuthorLabel(author: plugin.manifest.author, style: .detail)
                            Text("v\(plugin.manifest.version)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(L10n.t("plugins.close")) { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(20)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !galleryURLs.isEmpty {
                            galleryStrip
                        }

                        if busy {
                            ProgressView().controlSize(.small)
                        } else if installed {
                            Toggle(L10n.t("plugins.enable"), isOn: Binding(
                                get: { enabled },
                                set: { onEnabled($0) }
                            ))
                            Button(L10n.t("plugins.uninstall"), role: .destructive, action: onUninstall)
                        } else {
                            Button(L10n.t("plugins.install"), action: onDownload)
                                .buttonStyle(.borderedProminent)
                        }

                        if installed {
                            Picker(L10n.t("plugins.placement"), selection: Binding(
                                get: { placement == .afterCommand ? .afterWorkspaces : placement },
                                set: { onPlacement($0) }
                            )) {
                                Text(L10n.t("plugins.placement.before")).tag(AlwmBarPlacement.beforeWorkspaces)
                                Text(L10n.t("plugins.placement.after_ws")).tag(AlwmBarPlacement.afterWorkspaces)
                            }
                            .pickerStyle(.segmented)

                            Picker(L10n.t("plugins.display"), selection: Binding(
                                get: { display.rawString },
                                set: { onDisplay(PluginBarDisplay(rawString: $0)) }
                            )) {
                                Text(L10n.t("plugins.display.all")).tag(PluginBarDisplay.all.rawString)
                                ForEach(Array(monitors.enumerated()), id: \.element.id) { index, mon in
                                    Text(monitorLabel(mon, index: index)).tag(PluginBarDisplay.display(mon.id).rawString)
                                }
                            }

                            if case .display(let id) = display,
                               !monitors.contains(where: { $0.id == id }) {
                                Text(L10n.t("plugins.display.missing"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if let readme = readmeText {
                            Text(L10n.t("plugins.readme")).font(.headline)
                            Text(LocalizedStringKey(readme))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            let summary = PluginCatalogCopy.summary(for: plugin)
                            if !summary.isEmpty {
                                Text(summary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(20)
                }
            }

            if let galleryIndex {
                PluginGallerySlider(
                    urls: galleryURLs,
                    index: galleryIndex,
                    onIndexChange: { self.galleryIndex = $0 },
                    onClose: { self.galleryIndex = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: galleryIndex != nil)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear(perform: refreshMonitors)
    }

    var galleryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("plugins.gallery.title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(galleryURLs.enumerated()), id: \.element.path) { index, url in
                        if let img = NSImage(contentsOf: url) {
                            Button {
                                galleryIndex = index
                            } label: {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(L10n.t("plugins.gallery.enlarge"))
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    func refreshMonitors() {
        let store = MonitorStore()
        store.refresh()
        monitors = store.monitors
    }

    func monitorLabel(_ mon: MonitorInfo, index: Int) -> String {
        let name = mon.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(format: L10n.t("plugins.display.unnamed"), index + 1)
        }
        return name
    }

    var galleryURLs: [URL] {
        var urls: [URL] = []
        if let p = plugin.previewURL { urls.append(p) }
        for s in plugin.screenshotURLs where !urls.contains(s) {
            urls.append(s)
        }
        return urls
    }

    var readmeText: String? {
        _ = loc.revision
        return PluginCatalogCopy.readmeText(for: plugin)
    }
}
