import AppKit
import SwiftUI
import AlwmPluginAPI

/// Settings → Plugins.
struct PluginsSettingsPane: View {
    @ObservedObject private var loc = LocalizationController.shared
    @State private var plugins: [DiscoveredPlugin] = []
    @State private var detail: DiscoveredPlugin?
    @State private var tick = 0

    var body: some View {
        Form {
            Section {
                Button {
                    if let url = URL(string: Self.publishDocsURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L10n.t("plugins.publish"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                Text(L10n.t("plugins.publish.help"))
                    .font(.caption)
            }

            Section {
                if plugins.isEmpty {
                    Text(L10n.t("plugins.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(plugins) { plugin in
                        PluginCardRow(
                            plugin: plugin,
                            enabled: isEnabled(plugin),
                            onToggle: { enabled in
                                PluginManager.shared.setEnabled(enabled, id: plugin.id)
                                tick &+= 1
                            },
                            onOpen: { detail = plugin }
                        )
                    }
                }
            } header: {
                Text(L10n.t("plugins.catalog"))
            } footer: {
                Text(L10n.t("plugins.footer"))
                    .font(.caption)
            }
        }
        .id(loc.revision)
        .onAppear(perform: reload)
        .onChange(of: tick) { _, _ in reload() }
        .sheet(item: $detail) { plugin in
            PluginDetailSheet(
                plugin: plugin,
                enabled: isEnabled(plugin),
                placement: placement(for: plugin),
                display: display(for: plugin),
                onEnabled: { enabled in
                    PluginManager.shared.setEnabled(enabled, id: plugin.id)
                    tick &+= 1
                },
                onPlacement: { placement in
                    PluginManager.shared.setPlacement(placement, id: plugin.id)
                    tick &+= 1
                },
                onDisplay: { display in
                    PluginManager.shared.setDisplay(display, id: plugin.id)
                    tick &+= 1
                },
                onClose: { detail = nil }
            )
        }
    }

    private static let publishDocsURL =
        "https://github.com/lokize/ALWM---Tiling-window-manager-for-macOS/blob/main/docs/plugins.md"

    private func reload() {
        PluginManager.shared.refreshCatalog()
        plugins = PluginManager.shared.catalog
    }

    private func isEnabled(_ plugin: DiscoveredPlugin) -> Bool {
        let def = AlwmBarPlacement(rawString: plugin.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: plugin.id, defaultPlacement: def).enabled
    }

    private func placement(for plugin: DiscoveredPlugin) -> AlwmBarPlacement {
        let def = AlwmBarPlacement(rawString: plugin.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: plugin.id, defaultPlacement: def).placement
    }

    private func display(for plugin: DiscoveredPlugin) -> PluginBarDisplay {
        let def = AlwmBarPlacement(rawString: plugin.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: plugin.id, defaultPlacement: def).display
    }
}

private struct PluginCardRow: View {
    @ObservedObject private var loc = LocalizationController.shared
    let plugin: DiscoveredPlugin
    let enabled: Bool
    var onToggle: (Bool) -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            previewThumb
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plugin.manifest.name)
                        .font(.headline)
                    Text("v\(plugin.manifest.version)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(plugin.manifest.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !catalogSummary.isEmpty {
                    Text(catalogSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(L10n.t("plugins.enable"))

            Button(L10n.t("plugins.details")) { onOpen() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var catalogSummary: String {
        _ = loc.revision
        return PluginCatalogCopy.summary(for: plugin)
    }

    @ViewBuilder
    private var previewThumb: some View {
        if let url = plugin.previewURL,
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: "puzzlepiece.extension")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PluginDetailSheet: View {
    let plugin: DiscoveredPlugin
    let enabled: Bool
    let placement: AlwmBarPlacement
    let display: PluginBarDisplay
    var onEnabled: (Bool) -> Void
    var onPlacement: (AlwmBarPlacement) -> Void
    var onDisplay: (PluginBarDisplay) -> Void
    var onClose: () -> Void

    @ObservedObject private var loc = LocalizationController.shared
    @State private var monitors: [MonitorInfo] = []
    @State private var galleryIndex: Int?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.manifest.name).font(.title2.weight(.semibold))
                        Text("\(plugin.manifest.author) · v\(plugin.manifest.version)")
                            .foregroundStyle(.secondary)
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

                        Toggle(L10n.t("plugins.enable"), isOn: Binding(
                            get: { enabled },
                            set: { onEnabled($0) }
                        ))

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

    private var galleryStrip: some View {
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

    private func refreshMonitors() {
        let store = MonitorStore()
        store.refresh()
        monitors = store.monitors
    }

    private func monitorLabel(_ mon: MonitorInfo, index: Int) -> String {
        let name = mon.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(format: L10n.t("plugins.display.unnamed"), index + 1)
        }
        return name
    }

    private var galleryURLs: [URL] {
        var urls: [URL] = []
        if let p = plugin.previewURL { urls.append(p) }
        for s in plugin.screenshotURLs where !urls.contains(s) {
            urls.append(s)
        }
        return urls
    }

    private var readmeText: String? {
        _ = loc.revision
        return PluginCatalogCopy.readmeText(for: plugin)
    }
}

private struct PluginGallerySlider: View {
    let urls: [URL]
    let index: Int
    var onIndexChange: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 16) {
                HStack {
                    Text(L10n.tf("plugins.gallery.counter", index + 1, urls.count))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button(L10n.t("plugins.gallery.close")) { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                HStack(spacing: 16) {
                    navButton(systemName: "chevron.left", help: L10n.t("plugins.gallery.prev")) {
                        onIndexChange(max(0, index - 1))
                    }
                    .disabled(index <= 0)

                    imageView
                        .frame(maxWidth: 860, maxHeight: 520)

                    navButton(systemName: "chevron.right", help: L10n.t("plugins.gallery.next")) {
                        onIndexChange(min(urls.count - 1, index + 1))
                    }
                    .disabled(index >= urls.count - 1)
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 24)
            }
        }
        .focusable()
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left where index > 0:
                onIndexChange(index - 1)
            case .right where index < urls.count - 1:
                onIndexChange(index + 1)
            default:
                break
            }
        }
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private var imageView: some View {
        if urls.indices.contains(index), let img = NSImage(contentsOf: urls[index]) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }

    private func navButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }
}
