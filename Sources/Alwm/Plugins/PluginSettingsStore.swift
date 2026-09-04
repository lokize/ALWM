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

    public init(
        id: String,
        enabled: Bool = false,
        placement: AlwmBarPlacement = .afterWorkspaces,
        display: PluginBarDisplay = .all
    ) {
        self.id = id
        self.enabled = enabled
        self.placement = placement
        self.display = display
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
            display: .all
        )
    }

    public func setEnabled(_ enabled: Bool, for id: String, defaultPlacement: AlwmBarPlacement = .afterWorkspaces) {
        var s = state(for: id, defaultPlacement: defaultPlacement)
        s.enabled = enabled
        states[id] = s
        save()
    }

    public func setPlacement(_ placement: AlwmBarPlacement, for id: String) {
        var s = state(for: id, defaultPlacement: placement)
        s.placement = Self.normalized(placement)
        states[id] = s
        save()
    }

    public func setDisplay(_ display: PluginBarDisplay, for id: String) {
        var s = state(for: id)
        s.display = display
        states[id] = s
        save()
    }

    public func upsert(_ state: PluginUserState) {
        states[state.id] = state
        save()
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

        func flush() {
            guard let id = currentID else { return }
            next[id] = PluginUserState(
                id: id,
                enabled: enabled,
                placement: Self.normalized(placement),
                display: display
            )
            currentID = nil
            enabled = false
            placement = .afterWorkspaces
            display = .all
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
            }
        }
        flush()
        states = next
    }

    public func save() {
        var lines: [String] = []
        for id in states.keys.sorted() {
            guard let s = states[id] else { continue }
            lines.append("[[plugins]]")
            lines.append("id = \"\(s.id)\"")
            lines.append("enabled = \(s.enabled)")
            lines.append("placement = \"\(Self.normalized(s.placement).rawString)\"")
            lines.append("display = \"\(s.display.rawString)\"")
            lines.append("")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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
