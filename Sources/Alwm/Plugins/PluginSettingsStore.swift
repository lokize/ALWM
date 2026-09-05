import Foundation
import CoreGraphics
import AlwmPluginAPI

/// Which monitors show a plugin chip.
public enum PluginBarDisplay: Equatable, Sendable, Hashable {
    case all
    case display(CGDirectDisplayID)

    public var rawString: String {
        switch self {
        case .all: return "all"
        case .display(let id): return "\(id)"
        }
    }

    public init(rawString: String?) {
        guard let raw = rawString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "all"
        else {
            self = .all
            return
        }
        if let id = UInt32(raw) {
            self = .display(id)
        } else {
            self = .all
        }
    }

    public func matches(_ monitorID: CGDirectDisplayID) -> Bool {
        switch self {
        case .all: return true
        case .display(let id): return id == monitorID
        }
    }
}

public struct PluginUserState: Equatable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var placement: AlwmBarPlacement
    public var display: PluginBarDisplay
    /// Lower values appear first on the workspace bar (within the same placement).
    public var order: Int

    public init(
        id: String,
        enabled: Bool = false,
        placement: AlwmBarPlacement = .afterWorkspaces,
        display: PluginBarDisplay = .all,
        order: Int = 0
    ) {
        self.id = id
        self.enabled = enabled
        self.placement = placement
        self.display = display
        self.order = order
    }
}

public final class PluginSettingsStore: @unchecked Sendable {
    public private(set) var states: [String: PluginUserState] = [:]
    private let url: URL

    public init(url: URL = ConfigPaths.root.appendingPathComponent("plugins.toml")) {
        self.url = url
        load()
    }

    public func state(for id: String, defaultPlacement: AlwmBarPlacement = .afterWorkspaces) -> PluginUserState {
        if var existing = states[id] {
            let normalized = Self.normalized(existing.placement)
            if existing.placement != normalized {
                existing.placement = normalized
                states[id] = existing
            }
            return existing
        }
        return PluginUserState(
            id: id,
            enabled: false,
            placement: Self.normalized(defaultPlacement),
            display: .all,
            order: nextOrder()
        )
    }

    public func setEnabled(_ enabled: Bool, for id: String, defaultPlacement: AlwmBarPlacement = .afterWorkspaces) {
        var s = state(for: id, defaultPlacement: defaultPlacement)
        if states[id] == nil {
            s.order = nextOrder()
        }
        s.enabled = enabled
        states[id] = s
        save()
    }

    public func setPlacement(_ placement: AlwmBarPlacement, for id: String) {
        var s = state(for: id, defaultPlacement: placement)
        if states[id] == nil {
            s.order = nextOrder()
        }
        s.placement = Self.normalized(placement)
        states[id] = s
        save()
    }

    public func setDisplay(_ display: PluginBarDisplay, for id: String) {
        var s = state(for: id)
        if states[id] == nil {
            s.order = nextOrder()
        }
        s.display = display
        states[id] = s
        save()
    }

    public func upsert(_ state: PluginUserState) {
        states[state.id] = state
        save()
    }

    /// Stable bar order for catalog IDs (unknown ids append at the end).
    public func orderedIDs(catalogIDs: [String]) -> [String] {
        let known = Set(catalogIDs)
        let ranked = states.values
            .filter { known.contains($0.id) }
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.id < b.id
            }
            .map(\.id)
        var seen = Set(ranked)
        var result = ranked
        for id in catalogIDs.sorted() where !seen.contains(id) {
            result.append(id)
            seen.insert(id)
        }
        return result
    }

    /// Persist a full bar order (catalog order from the settings UI).
    public func reorder(_ ids: [String]) {
        for (index, id) in ids.enumerated() {
            var s = state(for: id)
            s.order = index
            states[id] = s
        }
        save()
    }

    public func sortKey(for id: String) -> Int {
        states[id]?.order ?? Int.max / 2
    }

    public func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            states = [:]
            return
        }
        var next: [String: PluginUserState] = [:]
        var currentID: String?
        var enabled = false
        var placement = AlwmBarPlacement.afterWorkspaces
        var display = PluginBarDisplay.all
        var order: Int?
        var fileIndex = 0

        func flush() {
            guard let id = currentID else { return }
            next[id] = PluginUserState(
                id: id,
                enabled: enabled,
                placement: Self.normalized(placement),
                display: display,
                order: order ?? fileIndex
            )
            fileIndex += 1
            currentID = nil
            enabled = false
            placement = .afterWorkspaces
            display = .all
            order = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[plugins]]" {
                flush()
                continue
            }
            if line.hasPrefix("id") {
                currentID = Self.stringValue(line)
            } else if line.hasPrefix("enabled") {
                enabled = Self.boolValue(line)
            } else if line.hasPrefix("placement"),
                      let raw = Self.stringValue(line),
                      let p = AlwmBarPlacement(rawString: raw) {
                placement = p
            } else if line.hasPrefix("display") {
                display = PluginBarDisplay(rawString: Self.stringValue(line))
            } else if line.hasPrefix("order"),
                      let raw = Self.stringValue(line),
                      let value = Int(raw) {
                order = value
            }
        }
        flush()
        states = next
    }

    public func save() {
        var lines: [String] = []
        let ordered = states.values.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.id < b.id
        }
        for s in ordered {
            lines.append("[[plugins]]")
            lines.append("id = \"\(s.id)\"")
            lines.append("enabled = \(s.enabled)")
            lines.append("placement = \"\(Self.normalized(s.placement).rawString)\"")
            lines.append("display = \"\(s.display.rawString)\"")
            lines.append("order = \(s.order)")
            lines.append("")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func nextOrder() -> Int {
        (states.values.map(\.order).max() ?? -1) + 1
    }

    /// `afterCommand` is obsolete (⌘ chip removed from the bar).
    private static func normalized(_ placement: AlwmBarPlacement) -> AlwmBarPlacement {
        placement == .afterCommand ? .afterWorkspaces : placement
    }

    private static func stringValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v.removeFirst(); v.removeLast()
        }
        return v
    }

    private static func boolValue(_ line: String) -> Bool {
        guard let raw = stringValue(line) else { return false }
        return raw == "true" || raw == "1"
    }
}
