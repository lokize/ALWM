import AppKit
import SwiftUI
import AlwmPluginAPI

/// Settings → Plugins.
struct PluginsSettingsPane: View {
    @ObservedObject private var loc = LocalizationController.shared
    @State private var plugins: [DiscoveredPlugin] = []
    @State private var detail: DiscoveredPlugin?
    @State private var tick = 0
    @State private var searchText = ""
    @State private var categoryFilter: PluginCategory? = nil

    private let contentInset: CGFloat = 20
    private let cardGap: CGFloat = 12

    private var filteredPlugins: [DiscoveredPlugin] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return plugins.filter { plugin in
            if let categoryFilter, plugin.manifest.resolvedCategory != categoryFilter {
                return false
            }
            guard !q.isEmpty else { return true }
            return pluginMatches(plugin, query: q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                publishBlock

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("plugins.catalog"))
                        .font(.headline)

                    if plugins.isEmpty {
                        Text(L10n.t("plugins.empty"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        pluginSearchBar
                        categoryFilterBar

                        if filteredPlugins.isEmpty {
                            Text(L10n.t("plugins.search.empty"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: cardGap),
                                    GridItem(.flexible(), spacing: cardGap)
                                ],
                                spacing: cardGap
                            ) {
                                ForEach(filteredPlugins) { plugin in
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
                        }

                        // Order list after the catalog grid so search/filters stay above cards.
                        pluginOrderBlock
                    }

                    Text(L10n.t("plugins.footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, contentInset)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var publishBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = URL(string: Self.publishDocsURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(L10n.t("plugins.publish"), systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Text(L10n.t("plugins.publish.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var pluginSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t("plugins.search"), text: $searchText)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("plugins.search.clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(
                    title: L10n.t("plugins.category.all"),
                    selected: categoryFilter == nil
                ) {
                    categoryFilter = nil
                }
                ForEach(PluginCategory.allCases) { category in
                    categoryChip(
                        title: L10n.t(category.l10nKey),
                        selected: categoryFilter == category
                    ) {
                        categoryFilter = categoryFilter == category ? nil : category
                    }
                }
            }
        }
    }

    private func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var pluginOrderBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("plugins.order"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.t("plugins.order.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(plugins) { plugin in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .help(L10n.t("plugins.order.drag"))
                        Text(plugin.manifest.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if isEnabled(plugin) {
                            Text(L10n.t("menu.on"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.primary.opacity(0.08))
                                )
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowSeparator(.visible)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: movePlugins)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 32)
            .frame(height: max(40, CGFloat(plugins.count) * 36))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.bottom, 4)
    }

    private static let publishDocsURL =
        "https://github.com/lokize/ALWM/blob/main/docs/plugins.md"

    private func reload() {
        PluginManager.shared.refreshCatalog()
        plugins = PluginManager.shared.orderedCatalog()
    }

    private func movePlugins(from source: IndexSet, to destination: Int) {
        // Update local order only — bumping `tick` / reload() rebuilds the outer
        // ScrollView and jumps scroll position back to the top.
        plugins.move(fromOffsets: source, toOffset: destination)
        PluginManager.shared.reorderBarPlugins(plugins.map(\.id))
    }

    private func pluginMatches(_ plugin: DiscoveredPlugin, query: String) -> Bool {
        let m = plugin.manifest
        let category = m.resolvedCategory
        let haystack = [
            m.id,
            m.name,
            m.author,
            m.summary,
            m.version,
            m.license ?? "",
            m.category,
            category.rawValue,
            L10n.t(category.l10nKey)
        ]
        .joined(separator: " ")
        .lowercased()
        return haystack.contains(query)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                previewThumb
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(plugin.manifest.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("v\(plugin.manifest.version)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 6) {
                        Text(L10n.t(plugin.manifest.resolvedCategory.l10nKey))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        Text(plugin.manifest.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)

                if enabled {
                    Text(L10n.t("plugins.badge.active"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.22))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                        .accessibilityLabel(L10n.t("plugins.badge.active"))
                }
            }

            if !catalogSummary.isEmpty {
                Text(catalogSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Toggle(L10n.t("plugins.enable"), isOn: Binding(
                    get: { enabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(L10n.t("plugins.enable"))

                Spacer(minLength: 0)

                Button(L10n.t("plugins.details")) { onOpen() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    enabled ? Color.green.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: enabled ? 1.5 : 1
                )
        )
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
                    .font(.title3)
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
                        HStack(spacing: 8) {
                            Text(L10n.t(plugin.manifest.resolvedCategory.l10nKey))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                            Text("\(plugin.manifest.author) · v\(plugin.manifest.version)")
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
