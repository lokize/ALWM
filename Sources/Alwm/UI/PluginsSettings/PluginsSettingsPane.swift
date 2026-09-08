import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Plugins settings pane

struct PluginsSettingsPane: View {
    @ObservedObject var loc = LocalizationController.shared
    @ObservedObject var installer = PluginInstallService.shared
    @State var items: [SettingsPluginItem] = []
    /// Bar chip order only — kept separate so reordering does not reshuffle the catalog grid
    /// (which was resetting the outer ScrollView to the top).
    @State var barOrderIDs: [String] = []
    @State var detail: SettingsPluginItem?
    @State var tick = 0
    @State var searchText = ""
    @State var categoryFilter: PluginCategory? = nil

    let contentInset: CGFloat = 20
    let cardGap: CGFloat = 12

    var filteredItems: [SettingsPluginItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if let categoryFilter, item.manifest.resolvedCategory != categoryFilter {
                return false
            }
            guard !q.isEmpty else { return true }
            return itemMatches(item, query: q)
        }
    }

    var installedByID: [String: SettingsPluginItem] {
        Dictionary(uniqueKeysWithValues: items.filter(\.isInstalled).map { ($0.id, $0) })
    }

    var orderedInstalledItems: [SettingsPluginItem] {
        let map = installedByID
        var seen = Set<String>()
        var result: [SettingsPluginItem] = []
        for id in barOrderIDs {
            guard let item = map[id], seen.insert(id).inserted else { continue }
            result.append(item)
        }
        for item in items where item.isInstalled && !seen.contains(item.id) {
            result.append(item)
        }
        return result
    }

    var body: some View {
        // NavigationSplitView detail often proposes unbounded height, so a bare
        // ScrollView grows with its content and the window clips it (no scrollbar).
        // GeometryReader + VStack: catalog scrolls; order stays a fixed footer
        // (safeAreaInset was clipped by the Settings detail `.clipped()`).
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        publishBlock

                        if installer.isRestoring {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L10n.t("plugins.restoring"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let err = installer.lastError, !err.isEmpty {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.t("plugins.catalog"))
                                .font(.headline)

                            if items.isEmpty {
                                Text(L10n.t("plugins.empty"))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                pluginSearchBar
                                categoryFilterBar

                                if filteredItems.isEmpty {
                                    Text(L10n.t("plugins.search.empty"))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 12)
                                } else {
                                    PluginsCatalogGrid(
                                        items: filteredItems,
                                        cardGap: cardGap,
                                        onToggle: { item, enabled in
                                            Task { await setEnabled(enabled, item: item) }
                                        },
                                        onDownload: { item in
                                            Task { await download(item) }
                                        },
                                        onUninstall: { item in
                                            uninstall(item)
                                        },
                                        onOpen: { item in
                                            detail = item
                                        }
                                    )
                                }
                            }

                            Text(L10n.t("plugins.footer"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, contentInset)
                    .padding(.vertical, 16)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusEffectDisabled()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scrollIndicators(.visible)
                .background(ForceLegacyVerticalScroller())

                if !orderedInstalledItems.isEmpty {
                    Divider()
                    pluginOrderBlock
                        .padding(.horizontal, contentInset)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(loc.revision)
        .onAppear {
            Task { await reloadAsync() }
            // Ensure enabled plugins are (re)loaded into the workspace bar.
            PluginManager.shared.reloadFromSettings()
        }
        .onChange(of: tick) { _, _ in Task { await reloadAsync() } }
        .onChange(of: installer.remoteCatalog) { _, _ in rebuildItems() }
        .onChange(of: installer.busyIDs) { _, _ in rebuildItems() }
        .onChange(of: installer.isRestoring) { _, _ in
            rebuildItems()
            if !installer.isRestoring {
                PluginManager.shared.reloadFromSettings()
            }
        }
        .sheet(item: $detail) { item in
            if let discovered = item.discovered {
                PluginDetailSheet(
                    plugin: discovered,
                    enabled: item.isEnabled,
                    installed: item.isInstalled,
                    busy: item.isBusy,
                    placement: placement(for: item),
                    display: display(for: item),
                    onEnabled: { enabled in
                        Task { await setEnabled(enabled, item: item) }
                    },
                    onDownload: {
                        Task { await download(item) }
                    },
                    onUninstall: {
                        uninstall(item)
                        detail = nil
                    },
                    onPlacement: { placement in
                        PluginManager.shared.setPlacement(placement, id: item.id)
                        tick &+= 1
                    },
                    onDisplay: { display in
                        PluginManager.shared.setDisplay(display, id: item.id)
                        tick &+= 1
                    },
                    onClose: { detail = nil }
                )
            } else {
                PluginRemoteDetailSheet(
                    item: item,
                    onDownload: {
                        Task { await download(item) }
                    },
                    onClose: { detail = nil }
                )
            }
        }
    }

    var publishBlock: some View {
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

    var pluginSearchBar: some View {
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

    var categoryFilterBar: some View {
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

    func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
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

    /// Bar chip order — outside the catalog scroller (arrows only).
    var pluginOrderBlock: some View {
        let rows = orderedInstalledItems
        let rowHeight: CGFloat = 36
        let listHeight = min(CGFloat(max(rows.count, 1)) * rowHeight, 240)

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("plugins.order"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.t("plugins.order.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(item.manifest.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if item.isEnabled {
                                Text(L10n.t("menu.on"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            Button {
                                moveInstalled(from: index, to: index - 1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .focusable(false)
                            .focusEffectDisabled()
                            .disabled(index == 0)
                            .help(L10n.t("plugins.order.move_up"))

                            Button {
                                moveInstalled(from: index, to: index + 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .focusable(false)
                            .focusEffectDisabled()
                            .disabled(index >= rows.count - 1)
                            .help(L10n.t("plugins.order.move_down"))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if index < rows.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
            .frame(height: listHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focusEffectDisabled()
        }
    }

    static let publishDocsURL =
        "https://github.com/lokize/ALWM/blob/main/docs/plugins.md"

    func reloadAsync() async {
        await installer.refreshCatalog()
        PluginManager.shared.refreshCatalog()
        rebuildItems()
    }

    func rebuildItems() {
        PluginManager.shared.refreshCatalog()
        let discovered = Dictionary(
            uniqueKeysWithValues: PluginManager.shared.catalog.map { ($0.id, $0) }
        )
        let settings = PluginManager.shared.settings
        var byID: [String: SettingsPluginItem] = [:]

        for remote in installer.remoteCatalog {
            let disc = discovered[remote.id]
            let onDisk = disc.map { FileManager.default.fileExists(atPath: $0.bundleURL.path) } ?? false
            let def = AlwmBarPlacement(rawString: remote.defaultPlacement) ?? .afterWorkspaces
            let hasState = settings.states[remote.id] != nil
            let state = settings.state(for: remote.id, defaultPlacement: def)
            let installed = resolveInstalled(
                onDisk: onDisk,
                bundleURL: disc?.bundleURL,
                state: state,
                hasPersistedState: hasState
            )
            byID[remote.id] = SettingsPluginItem(
                id: remote.id,
                manifest: remote.manifest,
                discovered: disc,
                isInstalled: installed,
                isEnabled: state.enabled && onDisk && installed,
                isBusy: installer.busyIDs.contains(remote.id)
            )
        }

        for disc in discovered.values where byID[disc.id] == nil {
            let def = AlwmBarPlacement(rawString: disc.manifest.defaultPlacement) ?? .afterWorkspaces
            let hasState = settings.states[disc.id] != nil
            let state = settings.state(for: disc.id, defaultPlacement: def)
            let onDisk = FileManager.default.fileExists(atPath: disc.bundleURL.path)
            let installed = resolveInstalled(
                onDisk: onDisk,
                bundleURL: disc.bundleURL,
                state: state,
                hasPersistedState: hasState
            )
            byID[disc.id] = SettingsPluginItem(
                id: disc.id,
                manifest: disc.manifest,
                discovered: disc,
                isInstalled: installed,
                isEnabled: state.enabled && onDisk && installed,
                isBusy: installer.busyIDs.contains(disc.id)
            )
        }

        // Catalog grid stays name-sorted — never tied to bar order.
        items = byID.values.sorted {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
        let installedIDs = items.filter(\.isInstalled).map(\.id)
        barOrderIDs = settings.orderedIDs(catalogIDs: installedIDs)
            .filter { installedIDs.contains($0) }
    }

    func moveInstalled(from index: Int, to newIndex: Int) {
        var order = barOrderIDs.isEmpty ? orderedInstalledItems.map(\.id) : barOrderIDs
        // Keep only ids that are still installed.
        let installed = Set(items.filter(\.isInstalled).map(\.id))
        order = order.filter { installed.contains($0) }
        for id in installed where !order.contains(id) {
            order.append(id)
        }
        guard order.indices.contains(index),
              newIndex >= 0,
              newIndex < order.count
        else { return }
        let id = order.remove(at: index)
        order.insert(id, at: newIndex)
        barOrderIDs = order

        PluginManager.shared.reorderBarPlugins(order, refreshBar: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            PluginManager.shared.requestBarRefresh()
        }
    }

    func download(_ item: SettingsPluginItem) async {
        do {
            try await installer.install(id: item.id, enable: true)
            tick &+= 1
        } catch {
            // lastError already set on service for network failures from install path
        }
        rebuildItems()
    }

    func uninstall(_ item: SettingsPluginItem) {
        installer.uninstall(id: item.id)
        tick &+= 1
    }

    func setEnabled(_ enabled: Bool, item: SettingsPluginItem) async {
        if enabled && !item.isInstalled {
            await download(item)
            return
        }
        let onDisk = item.discovered.map { FileManager.default.fileExists(atPath: $0.bundleURL.path) } ?? false
        if enabled && !onDisk {
            await download(item)
            return
        }
        PluginManager.shared.setEnabled(enabled, id: item.id)
        tick &+= 1
    }

    func itemMatches(_ item: SettingsPluginItem, query: String) -> Bool {
        let m = item.manifest
        let category = m.resolvedCategory
        let haystack = [
            m.id, m.name, m.author, m.summary, m.version,
            m.license ?? "", m.category, category.rawValue, L10n.t(category.l10nKey)
        ]
        .joined(separator: " ")
        .lowercased()
        return haystack.contains(query)
    }

    func placement(for item: SettingsPluginItem) -> AlwmBarPlacement {
        let def = AlwmBarPlacement(rawString: item.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: item.id, defaultPlacement: def).placement
    }

    func display(for item: SettingsPluginItem) -> PluginBarDisplay {
        let def = AlwmBarPlacement(rawString: item.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: item.id, defaultPlacement: def).display
    }
}
