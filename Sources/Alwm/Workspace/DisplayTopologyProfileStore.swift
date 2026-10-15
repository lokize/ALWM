import CoreGraphics
import Foundation

private struct DisplayTopologyProfile: Codable {
    let schemaVersion: Int
    let signature: String
    let displayIdentities: [String]
    let workspaceByDisplay: [String: String]
    let monitorIndexByDisplay: [String: Int]
    let updatedAt: Date
}

/// Remembers workspace-to-display placement for previously used display combinations.
public final class DisplayTopologyProfileStore {
    private let url: URL
    private let fileManager = FileManager.default
    private let schemaVersion = 1

    public init(url: URL = ConfigPaths.root.appendingPathComponent("display-topologies.json")) {
        self.url = url
    }

    public static func signature(for monitors: [MonitorInfo]) -> String {
        monitors.map(\.stableIdentity).sorted().joined(separator: "|")
    }

    public func remember(
        monitors: [MonitorInfo],
        activeWorkspaceByMonitor: [CGDirectDisplayID: String],
        logicalIndexByMonitor: [CGDirectDisplayID: Int]
    ) {
        guard !monitors.isEmpty else { return }
        var profiles = load()
        let workspaceMap = Dictionary(uniqueKeysWithValues: monitors.compactMap { monitor in
            activeWorkspaceByMonitor[monitor.id].map { (monitor.stableIdentity, $0) }
        })
        let indexMap = Dictionary(uniqueKeysWithValues: monitors.compactMap { monitor in
            logicalIndexByMonitor[monitor.id].map { (monitor.stableIdentity, $0) }
        })
        let signature = Self.signature(for: monitors)
        profiles[signature] = DisplayTopologyProfile(
            schemaVersion: schemaVersion,
            signature: signature,
            displayIdentities: monitors.map(\.stableIdentity).sorted(),
            workspaceByDisplay: workspaceMap,
            monitorIndexByDisplay: indexMap,
            updatedAt: Date()
        )
        save(profiles)
    }

    @discardableResult
    public func restore(_ monitors: [MonitorInfo], into runtimeState: RuntimeStateStore) -> Bool {
        guard !monitors.isEmpty,
              let profile = load()[Self.signature(for: monitors)],
              profile.schemaVersion == schemaVersion,
              profile.displayIdentities == monitors.map(\.stableIdentity).sorted()
        else { return false }

        for monitor in monitors {
            if let workspace = profile.workspaceByDisplay[monitor.stableIdentity] {
                runtimeState.setLastWorkspace(workspace, on: monitor.id)
            }
            if let index = profile.monitorIndexByDisplay[monitor.stableIdentity] {
                runtimeState.setMonitorIndex(index, for: monitor.id)
            }
        }
        runtimeState.save()
        return true
    }

    private func load() -> [String: DisplayTopologyProfile] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DisplayTopologyProfile].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ profiles: [String: DisplayTopologyProfile]) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(profiles).write(to: url, options: .atomic)
        } catch {
            NSLog("ALWM: display topology profile save failed: %@", error.localizedDescription)
        }
    }
}
