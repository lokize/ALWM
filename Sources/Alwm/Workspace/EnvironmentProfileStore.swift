import Foundation

public struct EnvironmentProfileSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let savedAt: Date
}

private struct EnvironmentProfileDocument: Codable {
    let schemaVersion: Int
    let name: String
    let savedAt: Date
    let files: [String: Data]
}

public enum EnvironmentProfileError: LocalizedError {
    case invalidName
    case notFound
    case unsupportedSchema
    case invalidFilePath
    case missingRequiredState

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Choose a profile name using letters, numbers, spaces, - or _."
        case .notFound: return "The selected environment profile was not found."
        case .unsupportedSchema: return "This environment profile was created by an unsupported ALWM version."
        case .invalidFilePath: return "The profile contains an unsafe file path."
        case .missingRequiredState: return "The profile does not contain the required ALWM settings."
        }
    }
}

/// Versioned, transactional snapshots of ALWM settings and runtime placement.
/// Apps outside the snapshot are never closed when a profile is activated.
public final class EnvironmentProfileStore {
    private let root: URL
    private let profilesRoot: URL
    private let fileManager = FileManager.default
    private let schemaVersion = 1
    private let requiredFiles = ["settings.toml", "hotkeys.toml", "gestures.toml", "workspaces.toml"]

    public init(root: URL = ConfigPaths.root) {
        self.root = root
        profilesRoot = root.appendingPathComponent("environment-profiles", isDirectory: true)
    }

    public func list() -> [EnvironmentProfileSummary] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard let doc = readDocument(at: url), doc.schemaVersion == schemaVersion else { return nil }
            return EnvironmentProfileSummary(id: url.lastPathComponent, name: doc.name, savedAt: doc.savedAt)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func save(name rawName: String) throws -> EnvironmentProfileSummary {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.range(of: #"^[\p{L}\p{N} _-]{1,48}$"#, options: .regularExpression) != nil
        else { throw EnvironmentProfileError.invalidName }
        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let document = EnvironmentProfileDocument(
            schemaVersion: schemaVersion,
            name: name,
            savedAt: Date(),
            files: try captureFiles()
        )
        try write(document, id: id)
        return EnvironmentProfileSummary(id: id, name: name, savedAt: document.savedAt)
    }

    public func activate(id: String, validate: () throws -> Void = {}) throws {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), !id.contains("..") else {
            throw EnvironmentProfileError.invalidName
        }
        guard let document = readDocument(at: profilesRoot.appendingPathComponent(id, isDirectory: false)) else {
            throw EnvironmentProfileError.notFound
        }
        guard document.schemaVersion == schemaVersion else { throw EnvironmentProfileError.unsupportedSchema }
        guard requiredFiles.allSatisfy({ document.files[$0] != nil }) else {
            throw EnvironmentProfileError.missingRequiredState
        }

        let rollback = EnvironmentProfileDocument(
            schemaVersion: schemaVersion,
            name: "rollback",
            savedAt: Date(),
            files: try captureFiles()
        )
        do {
            try applyFiles(document.files)
            try validate()
        } catch {
            try? applyFiles(rollback.files)
            throw error
        }
    }

    private func captureFiles() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let fixed = requiredFiles + ["plugins.toml", "runtime-state.json"]
        for path in fixed {
            let url = root.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url) { result[path] = data }
        }
        if result["plugins.toml"] == nil { result["plugins.toml"] = Data() }
        if result["runtime-state.json"] == nil {
            let emptyRuntime = RuntimeStateStore.Snapshot()
            result["runtime-state.json"] = try JSONEncoder().encode(emptyRuntime)
        }
        let rulesDirectory = root.appendingPathComponent("apprules.d", isDirectory: true)
        if let urls = try? fileManager.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension == "toml" && !url.lastPathComponent.hasSuffix(".sample") {
                result["apprules.d/\(url.lastPathComponent)"] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func applyFiles(_ files: [String: Data]) throws {
        for path in files.keys {
            guard isSafe(path) else { throw EnvironmentProfileError.invalidFilePath }
        }
        let rulesDirectory = root.appendingPathComponent("apprules.d", isDirectory: true)
        if let urls = try? fileManager.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension == "toml" && !url.lastPathComponent.hasSuffix(".sample") {
                try fileManager.removeItem(at: url)
            }
        }
        for (path, data) in files {
            let destination = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
    }

    private func isSafe(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/")
        guard !parts.contains("..") else { return false }
        return requiredFiles.contains(path)
            || path == "plugins.toml" || path == "runtime-state.json"
            || (parts.count == 2 && parts[0] == "apprules.d" && path.hasSuffix(".toml") && !path.hasSuffix(".sample"))
    }

    private func write(_ document: EnvironmentProfileDocument, id: String) throws {
        try fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(document)
        try data.write(to: profilesRoot.appendingPathComponent(id), options: .atomic)
    }

    private func readDocument(at url: URL) -> EnvironmentProfileDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EnvironmentProfileDocument.self, from: data)
    }
}
