import AppKit
import Combine
import Foundation
import AlwmL10n

struct BrewPackage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: Kind
    let installed: String
    let current: String

    enum Kind: String, Sendable {
        case formula
        case cask
    }
}

final class BrewStore: ObservableObject, @unchecked Sendable {
    static let shared = BrewStore()

    @Published private(set) var packages: [BrewPackage] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUpgrading = false
    @Published private(set) var brewAvailable = true
    @Published private(set) var lastChecked: Date?
    @Published var lastError: String?
    @Published var statusLine: String = ""

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private var refreshTimer: Timer?
    private let lock = NSLock()

    private init() {}

    var outdatedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return packages.count
    }

    var barLabel: String {
        let n = outdatedCount
        return n > 0 ? "\(n)" : "0"
    }

    var barTint: NSColor {
        if !brewAvailable { return .secondaryLabelColor }
        return outdatedCount > 0 ? .systemOrange : .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        if !brewAvailable {
            return PluginL10n.t("plugin.brew.tooltip.missing", locale: loc)
        }
        let n = outdatedCount
        if n == 0 {
            return PluginL10n.t("plugin.brew.tooltip.ok", locale: loc)
        }
        if n == 1 {
            return PluginL10n.t("plugin.brew.tooltip.one", locale: loc)
        }
        return PluginL10n.tf("plugin.brew.tooltip.count", locale: loc, n)
    }

    func start() {
        if refreshTimer == nil {
            let t = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
                Task { await self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        await MainActor.run {
            isRefreshing = true
            lastError = nil
            statusLine = PluginL10n.t("plugin.brew.status.checking", locale: localeCode())
            objectWillChange.send()
        }
        guard let brew = Self.brewPath() else {
            await MainActor.run {
                brewAvailable = false
                packages = []
                isRefreshing = false
                statusLine = ""
                lastError = PluginL10n.t("plugin.brew.error.missing", locale: localeCode())
                objectWillChange.send()
                onChange?()
            }
            return
        }

        do {
            // Quiet update of the brew index (best-effort; ignore failures).
            _ = try? await Task.detached {
                try Self.run(brew, args: ["update", "--quiet"], timeout: 120)
            }.value
            let output = try await Task.detached {
                try Self.run(brew, args: ["outdated", "--json=v2"], timeout: 90)
            }.value
            let parsed = try Self.parseOutdatedJSON(output)
            await MainActor.run {
                brewAvailable = true
                packages = parsed
                lastChecked = Date()
                isRefreshing = false
                statusLine = ""
                lastError = nil
                objectWillChange.send()
                onChange?()
            }
        } catch {
            await MainActor.run {
                isRefreshing = false
                statusLine = ""
                lastError = error.localizedDescription
                objectWillChange.send()
                onChange?()
            }
        }
    }

    func upgradeAll() async {
        guard let brew = Self.brewPath() else { return }
        await MainActor.run {
            isUpgrading = true
            statusLine = PluginL10n.t("plugin.brew.status.upgrading_all", locale: localeCode())
            objectWillChange.send()
        }
        do {
            _ = try await Task.detached {
                try Self.run(brew, args: ["upgrade"], timeout: 600)
            }.value
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
            }
            await refresh()
        } catch {
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
                lastError = error.localizedDescription
                objectWillChange.send()
            }
        }
    }

    func upgrade(_ pkg: BrewPackage) async {
        guard let brew = Self.brewPath() else { return }
        await MainActor.run {
            isUpgrading = true
            statusLine = PluginL10n.tf("plugin.brew.status.upgrading", locale: localeCode(), pkg.name)
            objectWillChange.send()
        }
        var args = ["upgrade"]
        if pkg.kind == .cask { args.append("--cask") }
        args.append(pkg.name)
        do {
            _ = try await Task.detached {
                try Self.run(brew, args: args, timeout: 600)
            }.value
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
            }
            await refresh()
        } catch {
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
                lastError = error.localizedDescription
                objectWillChange.send()
            }
        }
    }

    static func brewPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback: which brew via /bin/zsh
        if let out = try? run("/bin/zsh", args: ["-lc", "command -v brew"], timeout: 5) {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func parseOutdatedJSON(_ json: String) throws -> [BrewPackage] {
        guard let data = json.data(using: .utf8) else { return [] }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var result: [BrewPackage] = []

        if let formulae = obj["formulae"] as? [[String: Any]] {
            for f in formulae {
                guard let name = f["name"] as? String else { continue }
                let installed = (f["installed_versions"] as? [String])?.first ?? "—"
                let current = f["current_version"] as? String ?? "—"
                result.append(BrewPackage(
                    id: "formula:\(name)",
                    name: name,
                    kind: .formula,
                    installed: installed,
                    current: current
                ))
            }
        }
        if let casks = obj["casks"] as? [[String: Any]] {
            for c in casks {
                let name: String?
                if let token = c["token"] as? String {
                    name = token
                } else if let n = c["name"] as? String {
                    name = n
                } else if let arr = c["name"] as? [String] {
                    name = arr.first
                } else {
                    name = nil
                }
                guard let name else { continue }
                let installed = (c["installed_versions"] as? [String])?.first
                    ?? (c["installed_version"] as? String)
                    ?? "—"
                let current = c["current_version"] as? String ?? "—"
                result.append(BrewPackage(
                    id: "cask:\(name)",
                    name: name,
                    kind: .cask,
                    installed: installed,
                    current: current
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    private static func run(_ launchPath: String, args: [String], timeout: TimeInterval) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8"
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        try proc.run()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            proc.waitUntilExit()
            group.leave()
        }
        let waited = group.wait(timeout: .now() + timeout)
        if waited == .timedOut {
            proc.terminate()
            throw NSError(
                domain: "BrewStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "brew timed out"]
            )
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            // `brew outdated` exits 0 even when empty; other commands may fail.
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty {
                throw NSError(
                    domain: "BrewStore",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
        }
        return stdout
    }
}
