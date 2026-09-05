import AppKit
import Foundation
import Darwin
import AlwmPluginAPI
import AlwmPluginABI

public struct PluginBarItem: Equatable {
    public var id: String
    public var placement: AlwmBarPlacement
    public var display: PluginBarDisplay
    public var signature: String

    public init(
        id: String,
        placement: AlwmBarPlacement,
        display: PluginBarDisplay = .all,
        signature: String
    ) {
        self.id = id
        self.placement = placement
        self.display = display
        self.signature = signature
    }
}

/// Loads enabled `.alwmplugin` bundles from PlugIns.
@MainActor
public final class PluginManager {
    public static let shared = PluginManager()

    public let settings = PluginSettingsStore()
    public private(set) var catalog: [DiscoveredPlugin] = []

    public var onBarRefreshNeeded: (() -> Void)?
    /// Fired on the main queue after a plugin was auto-disabled for crashing mid-load.
    public var onPluginAutoDisabled: ((String) -> Void)?

    private var loaded: [String: LoadedPlugin] = [:]
    private var refreshWorkItem: DispatchWorkItem?
    private var pendingLoadWorkItem: DispatchWorkItem?
    private var pendingAutoDisabledIDs: [String] = []
    nonisolated(unsafe) private var barScale: CGFloat = 1
    nonisolated(unsafe) private var localeCString: UnsafeMutablePointer<CChar>?
    private var hostVTable = AlwmHostContextVTable()
    private var hostUserData: UnsafeMutableRawPointer?

    private init() {
        hostUserData = Unmanaged.passUnretained(self).toOpaque()
        hostVTable = Self.makeHostVTable(userData: hostUserData)
    }

    private nonisolated static func makeHostVTable(userData: UnsafeMutableRawPointer?) -> AlwmHostContextVTable {
        AlwmHostContextVTable(
            userData: userData,
            barScale: { raw in
                guard let raw else { return 1 }
                let mgr = Unmanaged<PluginManager>.fromOpaque(raw).takeUnretainedValue()
                return Double(mgr.barScale)
            },
            localeUTF8: { raw in
                guard let raw else { return nil }
                let mgr = Unmanaged<PluginManager>.fromOpaque(raw).takeUnretainedValue()
                return mgr.localePointer()
            },
            requestBarRefresh: { raw in
                guard let raw else { return }
                let unmanaged = Unmanaged<PluginManager>.fromOpaque(raw)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        unmanaged.takeUnretainedValue().requestBarRefresh()
                    }
                }
            }
        )
    }

    public func refreshCatalog() {
        catalog = PluginCatalog.discover()
    }

    public func reloadFromSettings() {
        refreshCatalog()

        // Last launch died while loading a plugin — quarantine it before touching more bundles.
        if let crashedID = PluginLoadGuard.consumeFailedLoad() {
            let def = catalog.first(where: { $0.id == crashedID }).flatMap {
                AlwmBarPlacement(rawString: $0.manifest.defaultPlacement)
            } ?? .afterWorkspaces
            settings.setEnabled(false, for: crashedID, defaultPlacement: def)
            pendingAutoDisabledIDs.append(crashedID)
            NSLog("ALWM plugins: auto-disabled \(crashedID) after previous load crash")
        }

        let allowedRoot = Bundle.main.builtInPlugInsURL?.standardizedFileURL

        var wanted: Set<String> = []
        var toLoad: [DiscoveredPlugin] = []
        for plugin in catalog {
            let defPlacement = AlwmBarPlacement(rawString: plugin.manifest.defaultPlacement) ?? .afterWorkspaces
            let state = settings.state(for: plugin.id, defaultPlacement: defPlacement)
            guard state.enabled else { continue }
            guard plugin.manifest.apiVersion <= alwmPluginAPIVersion else {
                NSLog("ALWM plugins: skip \(plugin.id) — apiVersion \(plugin.manifest.apiVersion) > \(alwmPluginAPIVersion)")
                continue
            }
            guard let allowedRoot,
                  isUnder(plugin.bundleURL, root: allowedRoot)
            else {
                NSLog("ALWM plugins: \(plugin.id) not under PlugIns — enable after packaging")
                continue
            }
            wanted.insert(plugin.id)
            if loaded[plugin.id] == nil {
                toLoad.append(plugin)
            } else {
                loaded[plugin.id]?.placement = state.placement
                loaded[plugin.id]?.display = state.display
            }
        }

        for id in loaded.keys.filter({ !wanted.contains($0) }) {
            unload(id: id)
        }

        // Don't block app start: load remaining plugins one-by-one on the next turns.
        pendingLoadWorkItem?.cancel()
        if toLoad.isEmpty {
            requestBarRefresh()
            flushAutoDisabledNotices()
            return
        }
        scheduleSequentialLoads(toLoad, index: 0)
    }

    private func scheduleSequentialLoads(_ plugins: [DiscoveredPlugin], index: Int) {
        guard index < plugins.count else {
            requestBarRefresh()
            flushAutoDisabledNotices()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadOne(plugins[index])
            self.scheduleSequentialLoads(plugins, index: index + 1)
        }
        pendingLoadWorkItem = work
        // Small stagger keeps the first paint responsive when many stats plugins are on.
        DispatchQueue.main.asyncAfter(deadline: .now() + (index == 0 ? 0.05 : 0.02), execute: work)
    }

    private func loadOne(_ plugin: DiscoveredPlugin) {
        let defPlacement = AlwmBarPlacement(rawString: plugin.manifest.defaultPlacement) ?? .afterWorkspaces
        let state = settings.state(for: plugin.id, defaultPlacement: defPlacement)
        guard state.enabled, loaded[plugin.id] == nil else { return }

        PluginLoadGuard.begin(plugin.id)
        defer { PluginLoadGuard.end() }

        if let instance = loadBundle(plugin) {
            withUnsafePointer(to: &hostVTable) { ptr in
                instance.table.pointee.load?(instance.table.pointee.userData, ptr)
            }
            loaded[plugin.id] = LoadedPlugin(
                id: plugin.id,
                handle: instance.handle,
                table: instance.table,
                placement: state.placement,
                display: state.display,
                bundleURL: plugin.bundleURL
            )
            requestBarRefresh()
        } else {
            settings.setEnabled(false, for: plugin.id, defaultPlacement: state.placement)
            pendingAutoDisabledIDs.append(plugin.id)
            NSLog("ALWM plugins: failed to load \(plugin.id) — disabled")
        }
    }

    private func flushAutoDisabledNotices() {
        let ids = pendingAutoDisabledIDs
        pendingAutoDisabledIDs.removeAll()
        for id in ids {
            onPluginAutoDisabled?(id)
        }
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        let plugin = catalog.first(where: { $0.id == id })
        let def = AlwmBarPlacement(rawString: plugin?.manifest.defaultPlacement ?? "") ?? .afterWorkspaces
        settings.setEnabled(enabled, for: id, defaultPlacement: def)
        reloadFromSettings()
    }

    public func setPlacement(_ placement: AlwmBarPlacement, id: String) {
        settings.setPlacement(placement, for: id)
        if var entry = loaded[id] {
            entry.placement = placement
            loaded[id] = entry
        }
        requestBarRefresh()
    }

    public func setDisplay(_ display: PluginBarDisplay, id: String) {
        settings.setDisplay(display, for: id)
        if var entry = loaded[id] {
            entry.display = display
            loaded[id] = entry
        }
        requestBarRefresh()
    }

    public func barItemsSnapshot() -> [PluginBarItem] {
        loaded.values.map { entry in
            let sig: String
            if let c = entry.table.pointee.barSignature?(entry.table.pointee.userData) {
                sig = String(cString: c)
            } else {
                sig = ""
            }
            return PluginBarItem(
                id: entry.id,
                placement: entry.placement,
                display: entry.display,
                signature: sig
            )
        }
        .sorted { $0.id < $1.id }
    }

    public func makeBarView(id: String, placement: AlwmBarPlacement, scale: CGFloat) -> NSView? {
        barScale = scale
        guard let entry = loaded[id], entry.placement == placement else { return nil }
        guard let raw = entry.table.pointee.barItem?(entry.table.pointee.userData, Int32(placement.rawValue)) else {
            return nil
        }
        return Unmanaged<NSView>.fromOpaque(raw).takeRetainedValue()
    }

    public func requestBarRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onBarRefreshNeeded?()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    public func updateBarScale(_ scale: CGFloat) {
        barScale = scale
    }

    nonisolated private func localePointer() -> UnsafePointer<CChar>? {
        let text = L10n.resolvedCode
        localeCString?.deallocate()
        let utf8 = Array(text.utf8CString)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
        buf.initialize(from: utf8, count: utf8.count)
        localeCString = buf
        return UnsafePointer(buf)
    }

    private func unload(id: String) {
        guard let entry = loaded.removeValue(forKey: id) else { return }
        entry.table.pointee.unload?(entry.table.pointee.userData)
        entry.table.pointee.destroy?(entry.table.pointee.userData)
        entry.table.deallocate()
        if let handle = entry.handle {
            dlclose(handle)
        }
    }

    private struct Opened {
        var handle: UnsafeMutableRawPointer?
        var table: UnsafeMutablePointer<AlwmPluginVTable>
    }

    private struct LoadedPlugin {
        var id: String
        var handle: UnsafeMutableRawPointer?
        var table: UnsafeMutablePointer<AlwmPluginVTable>
        var placement: AlwmBarPlacement
        var display: PluginBarDisplay
        var bundleURL: URL
    }

    private func loadBundle(_ discovered: DiscoveredPlugin) -> Opened? {
        let url = discovered.bundleURL
        let binary = resolveBinaryURL(bundle: url)
        guard let binary, FileManager.default.fileExists(atPath: binary.path) else {
            NSLog("ALWM plugins: no executable in \(url.path)")
            return nil
        }

        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            let err = String(cString: dlerror())
            NSLog("ALWM plugins: dlopen failed \(binary.lastPathComponent): \(err)")
            return nil
        }

        guard let sym = dlsym(handle, "alwm_plugin_create") else {
            NSLog("ALWM plugins: missing alwm_plugin_create in \(discovered.id)")
            dlclose(handle)
            return nil
        }

        let create = unsafeBitCast(sym, to: AlwmPluginCreateFn.self)
        guard let table = create() else {
            dlclose(handle)
            return nil
        }
        if table.pointee.apiVersion > Int32(alwmPluginAPIVersion) {
            NSLog("ALWM plugins: \(discovered.id) apiVersion too new (\(table.pointee.apiVersion))")
            table.pointee.destroy?(table.pointee.userData)
            table.deallocate()
            dlclose(handle)
            return nil
        }
        return Opened(handle: handle, table: table)
    }

    private func resolveBinaryURL(bundle: URL) -> URL? {
        let fm = FileManager.default
        let contentsMacOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: contentsMacOS, includingPropertiesForKeys: nil),
           let first = items.first(where: { fm.isExecutableFile(atPath: $0.path) || $0.pathExtension == "dylib" }) {
            return first
        }
        if let items = try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) {
            if let dylib = items.first(where: { $0.pathExtension == "dylib" }) { return dylib }
            if let exe = items.first(where: {
                $0.lastPathComponent != "plugin.json"
                    && $0.pathExtension != "md"
                    && $0.lastPathComponent != "previews"
                    && $0.lastPathComponent != "Contents"
                    && (fm.isExecutableFile(atPath: $0.path) || !$0.hasDirectoryPath)
            }), !exe.hasDirectoryPath {
                return exe
            }
        }
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: info) as? [String: Any],
           let name = dict["CFBundleExecutable"] as? String {
            return contentsMacOS.appendingPathComponent(name)
        }
        return nil
    }

    private func isUnder(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
