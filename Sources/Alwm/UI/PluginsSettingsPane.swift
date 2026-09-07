import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.
private struct SettingsPluginItem: Identifiable, Equatable {
    var id: String
    var manifest: PluginManifest
    var discovered: DiscoveredPlugin?
    var isInstalled: Bool
    var isEnabled: Bool
    var isBusy: Bool
}

/// Whether a discovered bundle lives under the user PlugIns directory.
private func isUserInstalledBundle(_ url: URL) -> Bool {
    let root = PluginInstallService.userPlugInsURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path == root || path.hasPrefix(root + "/")
}

/// Installed for UI: user PlugIns on disk, or bundled unless soft-uninstalled.
private func resolveInstalled(
    onDisk: Bool,
    bundleURL: URL?,
    state: PluginUserState,
    hasPersistedState: Bool
) -> Bool {
    if let bundleURL, isUserInstalledBundle(bundleURL) {
        return onDisk
    }
    if onDisk {
        // Bundled / dist copy: honor soft-uninstall (`installed = false` in plugins.toml).
        if hasPersistedState { return state.installed }
        return true
    }
    return state.installed
}

/// Settings → Plugins.
struct PluginsSettingsPane: View {
    @ObservedObject private var loc = LocalizationController.shared
    @ObservedObject private var installer = PluginInstallService.shared
    @State private var items: [SettingsPluginItem] = []
    /// Bar chip order only — kept separate so reordering does not reshuffle the catalog grid
    /// (which was resetting the outer ScrollView to the top).
    @State private var barOrderIDs: [String] = []
    @State private var detail: SettingsPluginItem?
    @State private var tick = 0
    @State private var searchText = ""
    @State private var categoryFilter: PluginCategory? = nil
    @State private var draggingOrderID: String? = nil

    private let contentInset: CGFloat = 20
    private let cardGap: CGFloat = 12

    private var filteredItems: [SettingsPluginItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if let categoryFilter, item.manifest.resolvedCategory != categoryFilter {
                return false
            }
            guard !q.isEmpty else { return true }
            return itemMatches(item, query: q)
        }
    }

    private var installedByID: [String: SettingsPluginItem] {
        Dictionary(uniqueKeysWithValues: items.filter(\.isInstalled).map { ($0.id, $0) })
    }

    private var orderedInstalledItems: [SettingsPluginItem] {
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
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: cardGap),
                                        GridItem(.flexible(), spacing: cardGap)
                                    ],
                                    spacing: cardGap
                                ) {
                                    ForEach(filteredItems) { item in
                                        PluginCardRow(
                                            item: item,
                                            onToggle: { enabled in
                                                Task { await setEnabled(enabled, item: item) }
                                            },
                                            onDownload: {
                                                Task { await download(item) }
                                            },
                                            onUninstall: {
                                                uninstall(item)
                                            },
                                            onOpen: { detail = item }
                                        )
                                    }
                                }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(loc.revision)

            // Order lives outside the catalog ScrollView so LazyVGrid remounts
            // never reset the viewport when barOrderIDs changes.
            if !orderedInstalledItems.isEmpty {
                Divider()
                pluginOrderBlock
                    .padding(.horizontal, contentInset)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .onAppear { Task { await reloadAsync() } }
        .onChange(of: tick) { _, _ in Task { await reloadAsync() } }
        .onChange(of: installer.remoteCatalog) { _, _ in rebuildItems() }
        .onChange(of: installer.busyIDs) { _, _ in rebuildItems() }
        .onChange(of: installer.isRestoring) { _, _ in rebuildItems() }
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

    /// Fixed footer order panel (not inside the catalog ScrollView).
    private var pluginOrderBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("plugins.order"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.t("plugins.order.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let rows = orderedInstalledItems
            let listHeight = min(240, CGFloat(max(rows.count, 1)) * 36)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .help(L10n.t("plugins.order.drag"))
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
                            .disabled(index == 0)
                            .help(L10n.t("plugins.order.move_up"))

                            Button {
                                moveInstalled(from: index, to: index + 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index >= rows.count - 1)
                            .help(L10n.t("plugins.order.move_down"))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(draggingOrderID == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onDrag {
                            draggingOrderID = item.id
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: PluginOrderDropDelegate(
                                targetID: item.id,
                                orderedIDs: rows.map(\.id),
                                draggingID: $draggingOrderID,
                                onMove: { from, to in moveInstalled(from: from, to: to) }
                            )
                        )
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
        }
    }

    private static let publishDocsURL =
        "https://github.com/lokize/ALWM/blob/main/docs/plugins.md"

    private func reloadAsync() async {
        await installer.refreshCatalog()
        PluginManager.shared.refreshCatalog()
        rebuildItems()
    }

    private func rebuildItems() {
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

    private func moveInstalled(from index: Int, to newIndex: Int) {
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

        let rest = items.map(\.id).filter { !installed.contains($0) }
        // Persist order; refresh the workspace bar after a beat so Settings layout
        // is not invalidated in the same turn as the local list update.
        PluginManager.shared.reorderBarPlugins(order + rest, refreshBar: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PluginManager.shared.requestBarRefresh()
        }
    }

    private func download(_ item: SettingsPluginItem) async {
        do {
            try await installer.install(id: item.id, enable: true)
            tick &+= 1
        } catch {
            // lastError already set on service for network failures from install path
        }
        rebuildItems()
    }

    private func uninstall(_ item: SettingsPluginItem) {
        installer.uninstall(id: item.id)
        tick &+= 1
    }

    private func setEnabled(_ enabled: Bool, item: SettingsPluginItem) async {
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

    private func itemMatches(_ item: SettingsPluginItem, query: String) -> Bool {
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

    private func placement(for item: SettingsPluginItem) -> AlwmBarPlacement {
        let def = AlwmBarPlacement(rawString: item.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: item.id, defaultPlacement: def).placement
    }

    private func display(for item: SettingsPluginItem) -> PluginBarDisplay {
        let def = AlwmBarPlacement(rawString: item.manifest.defaultPlacement) ?? .afterWorkspaces
        return PluginManager.shared.settings.state(for: item.id, defaultPlacement: def).display
    }
}

/// Drop target for bar-order rows — updates local order only (no ScrollView rebuild).
private struct PluginOrderDropDelegate: DropDelegate {
    let targetID: String
    let orderedIDs: [String]
    @Binding var draggingID: String?
    let onMove: (Int, Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Reorder already applied in `dropEntered` while dragging.
        draggingID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let fromID = draggingID,
              fromID != targetID,
              let from = orderedIDs.firstIndex(of: fromID),
              let to = orderedIDs.firstIndex(of: targetID),
              from != to
        else { return }
        onMove(from, to)
    }
}

private struct PluginAuthorLabel: View {
    enum Style {
        case card
        case detail
    }

    let author: String
    var style: Style = .card

    private var isOfficial: Bool {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.caseInsensitiveCompare("Lokize") == .orderedSame
            || name.caseInsensitiveCompare("ALWM") == .orderedSame
    }

    var body: some View {
        if isOfficial {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(style == .card ? .caption2 : .caption)
                Text(L10n.t("plugins.badge.official"))
                    .font(style == .card ? .caption2.weight(.bold) : .caption.weight(.semibold))
            }
            .padding(.horizontal, style == .card ? 6 : 8)
            .padding(.vertical, style == .card ? 1 : 2)
            .background(Color.blue.opacity(0.18))
            .foregroundStyle(Color.blue)
            .clipShape(Capsule())
            .accessibilityLabel(L10n.t("plugins.badge.official"))
        } else {
            Text(author)
                .font(style == .card ? .caption : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct PluginCardRow: View {
    @ObservedObject private var loc = LocalizationController.shared
    let item: SettingsPluginItem
    var onToggle: (Bool) -> Void
    var onDownload: () -> Void
    var onUninstall: () -> Void
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                previewThumb
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.manifest.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("v\(item.manifest.version)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 6) {
                        Text(L10n.t(item.manifest.resolvedCategory.l10nKey))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        PluginAuthorLabel(author: item.manifest.author, style: .card)
                    }
                }
                Spacer(minLength: 0)

                if item.isEnabled {
                    Text(L10n.t("plugins.badge.active"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.22))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                } else if item.isInstalled {
                    Text(L10n.t("plugins.badge.installed"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.18))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
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
                if item.isBusy {
                    ProgressView().controlSize(.small)
                } else if item.isInstalled {
                    Toggle(L10n.t("plugins.enable"), isOn: Binding(
                        get: { item.isEnabled },
                        set: { onToggle($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(L10n.t("plugins.enable"))
                }

                Spacer(minLength: 0)

                if item.isBusy {
                    EmptyView()
                } else if !item.isInstalled {
                    Button(L10n.t("plugins.install")) { onDownload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button(L10n.t("plugins.uninstall")) { onUninstall() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
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
                    item.isEnabled ? Color.green.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: item.isEnabled ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var catalogSummary: String {
        _ = loc.revision
        return PluginCatalogCopy.summary(id: item.id, fallback: item.manifest.summary)
    }

    @ViewBuilder
    private var previewThumb: some View {
        if let url = item.discovered?.previewURL,
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

private struct PluginRemoteDetailSheet: View {
    let item: SettingsPluginItem
    var onDownload: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.manifest.name).font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        PluginAuthorLabel(author: item.manifest.author, style: .detail)
                        Text("v\(item.manifest.version)")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L10n.t("plugins.close")) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(PluginCatalogCopy.summary(id: item.id, fallback: item.manifest.summary))
                .foregroundStyle(.secondary)
            if item.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.t("plugins.install")) { onDownload() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 240)
    }
}

private struct PluginDetailSheet: View {
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
