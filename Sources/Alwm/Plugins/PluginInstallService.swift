import AppKit
import Foundation
import Combine
import AlwmPluginAPI

/// Remote catalog entry from `plugins-index.json` (GitHub Release or bundled fallback).
public struct RemotePluginInfo: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var version: String
    public var bundle: String
    public var category: String
    public var summary: String
    public var apiVersion: Int
    public var asset: String
    public var defaultPlacement: String
    public var author: String
    public var preview: String?
    public var screenshots: [String]

    public var manifest: PluginManifest {
        PluginManifest(
            id: id,
            name: name,
            author: author.isEmpty ? "Unknown" : author,
            version: version,
            apiVersion: apiVersion,
            summary: summary,
            category: category,
            preview: preview,
            screenshots: screenshots,
            defaultPlacement: defaultPlacement
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, bundle, category, summary, apiVersion, asset
        case defaultPlacement, author, preview, screenshots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        bundle = try c.decodeIfPresent(String.self, forKey: .bundle) ?? "\(id).alwmplugin"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "utilities"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        apiVersion = try c.decodeIfPresent(Int.self, forKey: .apiVersion) ?? 1
        asset = try c.decodeIfPresent(String.self, forKey: .asset) ?? "\(bundle).zip"
        defaultPlacement = try c.decodeIfPresent(String.self, forKey: .defaultPlacement) ?? "afterWorkspaces"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        screenshots = try c.decodeIfPresent([String].self, forKey: .screenshots) ?? []
    }
}

private struct PluginsIndexDTO: Decodable {
    var schemaVersion: Int?
    var plugins: [RemotePluginInfo]
}

/// Downloads / installs / restores `.alwmplugin` bundles under `~/.config/alwm/PlugIns`.
@MainActor
public final class PluginInstallService: ObservableObject {
    public static let shared = PluginInstallService()

    /// Shared path used by catalog discovery (nonisolated).
    nonisolated public static var userPlugInsURL: URL {
        let preferred = ConfigPaths.root.appendingPathComponent("PlugIns", isDirectory: true)
        // APFS is often case-insensitive; the folder may already exist as `plugins`.
        // Prefer the on-disk path so discoveries and loadable-root checks agree.
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: ConfigPaths.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue,
                      url.lastPathComponent.lowercased() == "plugins"
                else { continue }
                return url.standardizedFileURL
            }
        }
        return preferred.standardizedFileURL
    }

    /// Path containment that tolerates APFS case-insensitive folders (`plugins` vs `PlugIns`).
    nonisolated public static func isPath(_ url: URL, under root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath || path.hasPrefix(rootPath + "/") { return true }
        let p = path.lowercased()
        let r = rootPath.lowercased()
        return p == r || p.hasPrefix(r + "/")
    }

    @Published public private(set) var remoteCatalog: [RemotePluginInfo] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isRestoring = false
    @Published public private(set) var busyIDs: Set<String> = []
    @Published public private(set) var lastError: String?

    private var assetURLByName: [String: URL] = [:]
    private var restoreTask: Task<Void, Never>?

    private init() {}

    public func ensureUserPlugInsDir() {
        try? FileManager.default.createDirectory(
            at: Self.userPlugInsURL,
            withIntermediateDirectories: true
        )
    }

    public func localBundleURL(for remote: RemotePluginInfo) -> URL {
        Self.userPlugInsURL.appendingPathComponent(remote.bundle, isDirectory: true)
    }

    /// True only when a real `.alwmplugin` for this id lives under `~/.config/alwm/PlugIns`
    /// (survives app updates). Source tree / app `Contents/PlugIns` / `dist` do not count.
    public func isOnDisk(id: String) -> Bool {
        userInstalledBundleURL(id: id) != nil
    }

    /// Promote / download so an installed plugin survives the next app update.
    public func ensurePersistedBundle(id: String, enable: Bool? = nil) async throws {
        ensureUserPlugInsDir()
        if isOnDisk(id: id) {
            if let enable {
                var state = PluginManager.shared.settings.state(for: id)
                state.installed = true
                if enable { state.enabled = true }
                PluginManager.shared.settings.upsert(state)
            }
            return
        }
        try await install(id: id, enable: enable ?? (PluginManager.shared.settings.states[id]?.enabled ?? true))
    }

    /// Refresh remote index (GitHub latest release) with bundled `plugins-index.json` fallback.
    public func refreshCatalog() async {
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }
        do {
            let (index, assets) = try await fetchRemoteIndex()
            remoteCatalog = index.plugins.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            assetURLByName = assets
        } catch {
            if let bundled = loadBundledIndex() {
                remoteCatalog = bundled.plugins.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// Install from remote, app Resources zips, Contents/PlugIns, or dist. Preserves order/display.
    public func install(id: String, enable: Bool = true) async throws {
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        lastError = nil
        ensureUserPlugInsDir()

        let info = remoteCatalog.first(where: { $0.id == id })
            ?? loadBundledIndex()?.plugins.first(where: { $0.id == id })

        // Prefer copying an already-built bundle (app PlugIns / discover) before network.
        if let source = findPromotableBundle(id: id) {
            let destName = info?.bundle ?? source.lastPathComponent
            let dest = Self.userPlugInsURL.appendingPathComponent(destName, isDirectory: true)
            try replaceItem(at: dest, withCopyOf: source)
            try adHocSign(plugin: dest)
            if let info {
                markInstalled(info, enable: enable)
            } else {
                markInstalledPromoted(id: id, version: nil, enable: enable)
            }
            PluginManager.shared.reloadFromSettings()
            return
        }

        guard let info else {
            throw InstallError.unknownPlugin(id)
        }

        let dest = localBundleURL(for: info)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        if let url = assetURLByName[info.asset] ?? assetURLByName[info.bundle + ".zip"] {
            try await downloadAndExtract(zipURL: url, destBundle: dest, expectedName: info.bundle)
        } else if let localZip = localDistZip(named: info.asset) {
            try extractZip(at: localZip, destBundle: dest, expectedName: info.bundle)
        } else if let localBundle = localDistBundle(named: info.bundle) {
            try FileManager.default.copyItem(at: localBundle, to: dest)
        } else {
            throw InstallError.missingAsset(info.asset)
        }

        try adHocSign(plugin: dest)
        markInstalled(info, enable: enable)
        PluginManager.shared.reloadFromSettings()
    }

    public func uninstall(id: String) {
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        let discovered = PluginCatalog.discover().first { $0.id == id }
        if let url = discovered?.bundleURL,
           isUnder(url, root: Self.userPlugInsURL) {
            try? FileManager.default.removeItem(at: url)
        }
        var state = PluginManager.shared.settings.state(for: id)
        state.installed = false
        state.enabled = false
        state.installedVersion = nil
        PluginManager.shared.settings.upsert(state)
        PluginManager.shared.reloadFromSettings()
    }

    /// Re-materialize installed plugins under `~/.config/alwm/PlugIns` after an app update.
    /// Preserves `enabled`, `order`, `placement`, and `display` from `plugins.toml`.
    public func restoreInstalledIfNeeded() {
        restoreTask?.cancel()
        restoreTask = Task { await performRestore() }
    }

    private func performRestore() async {
        isRestoring = true
        defer { isRestoring = false }
        PluginManager.shared.settings.migrateInstalledFlags()
        // Paint the bar from whatever is already on disk before any network work.
        PluginManager.shared.reloadFromSettings()
        await refreshCatalog()

        let settings = PluginManager.shared.settings
        let needed = settings.states.values.filter(\.installed)
        guard !needed.isEmpty else { return }

        for state in needed.sorted(by: { $0.order < $1.order }) {
            if Task.isCancelled { return }
            if isOnDisk(id: state.id) { continue }
            do {
                try await install(id: state.id, enable: state.enabled)
            } catch {
                lastError = error.localizedDescription
                NSLog("ALWM plugins: restore failed for \(state.id): \(error.localizedDescription)")
            }
        }
        PluginManager.shared.reloadFromSettings()
        Task(priority: .utility) {
            resignUserPlugInsIfNeeded()
            PluginManager.shared.reloadFromSettings()
        }
    }

    // MARK: - Private

    private func userInstalledBundleURL(id: String) -> URL? {
        let root = Self.userPlugInsURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for url in urls where url.pathExtension == "alwmplugin" {
            guard let plugin = PluginCatalog.load(from: url), plugin.id == id else { continue }
            return url
        }
        return nil
    }

    /// Bundles that can be copied into the user PlugIns dir (not already there).
    private func findPromotableBundle(id: String) -> URL? {
        let userRoot = Self.userPlugInsURL.standardizedFileURL
        // App Contents/PlugIns first (debug / ALWM_BUNDLE_PLUGINS builds).
        if let builtIn = Bundle.main.builtInPlugInsURL,
           let urls = try? FileManager.default.contentsOfDirectory(
               at: builtIn,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for url in urls where url.pathExtension == "alwmplugin" {
                if let plugin = PluginCatalog.load(from: url), plugin.id == id {
                    return url
                }
            }
        }
        // Any discovered copy outside the user dir (dist / repo during local runs).
        for plugin in PluginCatalog.discover() where plugin.id == id {
            if Self.isPath(plugin.bundleURL, under: userRoot) { continue }
            if plugin.bundleURL.pathExtension == "alwmplugin",
               FileManager.default.fileExists(atPath: plugin.bundleURL.path) {
                return plugin.bundleURL
            }
        }
        return nil
    }

    private func replaceItem(at dest: URL, withCopyOf source: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
    }

    private func markInstalled(_ info: RemotePluginInfo, enable: Bool) {
        var state = PluginManager.shared.settings.state(
            for: info.id,
            defaultPlacement: AlwmBarPlacement(rawString: info.defaultPlacement) ?? .afterWorkspaces
        )
        if PluginManager.shared.settings.states[info.id] == nil {
            state.order = PluginManager.shared.settings.nextOrderPublic()
        }
        state.installed = true
        state.installedVersion = info.version
        if enable {
            state.enabled = true
        }
        // Never clear enabled/order/placement/display when restoring an existing entry.
        PluginManager.shared.settings.upsert(state)
    }

    private func markInstalledPromoted(id: String, version: String?, enable: Bool) {
        var state = PluginManager.shared.settings.state(for: id)
        if PluginManager.shared.settings.states[id] == nil {
            state.order = PluginManager.shared.settings.nextOrderPublic()
        }
        state.installed = true
        if let version { state.installedVersion = version }
        if enable { state.enabled = true }
        PluginManager.shared.settings.upsert(state)
    }

    private func fetchRemoteIndex() async throws -> (PluginsIndexDTO, [String: URL]) {
        let api = URL(
            string: "https://api.github.com/repos/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)/releases/latest"
        )!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ALWM-Plugins", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.httpStatus(http.statusCode)
        }
        let release = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        var assets: [String: URL] = [:]
        for asset in release.assets {
            if let url = URL(string: asset.browser_download_url) {
                assets[asset.name] = url
            }
        }
        guard let indexURL = assets["plugins-index.json"] else {
            throw InstallError.missingIndex
        }
        let (indexData, indexResponse) = try await URLSession.shared.data(from: indexURL)
        if let http = indexResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.httpStatus(http.statusCode)
        }
        let index = try JSONDecoder().decode(PluginsIndexDTO.self, from: indexData)
        return (index, assets)
    }

    private func loadBundledIndex() -> PluginsIndexDTO? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "plugins-index", withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("plugins-index.json"),
            Bundle.main.resourceURL?
                .appendingPathComponent("ALWM_Alwm.bundle")
                .appendingPathComponent("plugins-index.json")
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let dto = try? JSONDecoder().decode(PluginsIndexDTO.self, from: data) {
                return dto
            }
        }
        // Dev: dist/plugins-index.json next to cwd when packaging locally.
        let dist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/plugins-index.json")
        if let data = try? Data(contentsOf: dist),
           let dto = try? JSONDecoder().decode(PluginsIndexDTO.self, from: data) {
            return dto
        }
        return nil
    }

    private func localDistZip(named asset: String) -> URL? {
        let candidates: [URL?] = [
            // Shipped inside the .app for offline restore after slim updates.
            Bundle.main.resourceURL?.appendingPathComponent("plugins/\(asset)"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/plugins/\(asset)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/plugins/\(asset)"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("plugins/\(asset)")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func localDistBundle(named bundle: String) -> URL? {
        let candidates: [URL?] = [
            Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundle),
            Bundle.main.resourceURL?.appendingPathComponent("plugins/\(bundle)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/plugins/\(bundle)"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func downloadAndExtract(zipURL: URL, destBundle: URL, expectedName: String) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: zipURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.httpStatus(http.statusCode)
        }
        let zipCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-plugin-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: zipCopy)
        try FileManager.default.moveItem(at: tempURL, to: zipCopy)
        defer { try? FileManager.default.removeItem(at: zipCopy) }
        try extractZip(at: zipCopy, destBundle: destBundle, expectedName: expectedName)
    }

    private func extractZip(at zipURL: URL, destBundle: URL, expectedName: String) throws {
        let extractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-plugin-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractRoot) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, extractRoot.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw InstallError.extractFailed }

        let found = findPluginBundle(in: extractRoot, preferredName: expectedName)
        guard let found else { throw InstallError.extractFailed }
        try? FileManager.default.removeItem(at: destBundle)
        try FileManager.default.copyItem(at: found, to: destBundle)
    }

    private func findPluginBundle(in root: URL, preferredName: String) -> URL? {
        let preferred = root.appendingPathComponent(preferredName)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.pathExtension == "alwmplugin" { return url }
        }
        return nil
    }

    private func adHocSign(plugin: URL) throws {
        let identity = Self.hostCodesignIdentity() ?? "-"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = [
            "--force", "--deep", "--sign", identity,
            "--identifier", plugin.deletingPathExtension().lastPathComponent,
            plugin.path
        ]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            NSLog("ALWM plugins: codesign warning for \(plugin.lastPathComponent) identity=\(identity)")
        }
    }

    /// Match the running .app signing identity so user PlugIns pass dyld / AMFI checks.
    private static func hostCodesignIdentity() -> String? {
        let app = Bundle.main.bundleURL
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=4", app.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        // Authority=ALWM Local Signing  /  Authority=Apple Development: …
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Authority=") {
                let name = String(trimmed.dropFirst("Authority=".count))
                if name != "apple generic", !name.isEmpty {
                    return name
                }
            }
        }
        if text.contains("Signature=adhoc") || text.contains("flags=0x2(adhoc)") {
            return "-"
        }
        // Stable local cert used by package.sh
        let sec = Process()
        sec.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        sec.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let out = Pipe()
        sec.standardOutput = out
        sec.standardError = Pipe()
        do {
            try sec.run()
            sec.waitUntilExit()
        } catch {
            return nil
        }
        let secText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if secText.contains("ALWM Local Signing") {
            return "ALWM Local Signing"
        }
        return nil
    }

    /// Re-sign every user PlugIns bundle with the host identity (fixes ad-hoc copies).
    public func resignUserPlugInsIfNeeded() {
        ensureUserPlugInsDir()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Self.userPlugInsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "alwmplugin" {
            do {
                try adHocSign(plugin: url)
            } catch {
                NSLog("ALWM plugins: resign failed \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func isUnder(_ url: URL, root: URL) -> Bool {
        Self.isPath(url, under: root)
    }

    private struct GitHubReleaseDTO: Decodable {
        var assets: [Asset]
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
        }
    }

    public enum InstallError: LocalizedError {
        case unknownPlugin(String)
        case missingAsset(String)
        case missingIndex
        case httpStatus(Int)
        case extractFailed

        public var errorDescription: String? {
            switch self {
            case .unknownPlugin(let id): return "Unknown plugin: \(id)"
            case .missingAsset(let name): return "Plugin asset not found: \(name)"
            case .missingIndex: return "plugins-index.json missing from release"
            case .httpStatus(let code): return "HTTP \(code)"
            case .extractFailed: return "Failed to extract plugin archive"
            }
        }
    }
}
