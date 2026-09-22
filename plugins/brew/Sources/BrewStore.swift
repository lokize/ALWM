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
    /// Homebrew marked the formula/cask as disabled (e.g. Gatekeeper) — upgrade is impossible.
    let isDisabled: Bool

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

    /// Packages that can actually be upgraded (excludes Homebrew-disabled).
    var upgradeablePackages: [BrewPackage] {
        lock.lock()
        defer { lock.unlock() }
        return packages.filter { !$0.isDisabled }
    }

    var outdatedCount: Int {
        upgradeablePackages.count
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
            let parsedJSON = output.stdout
            let brewPath = brew
            let parsed = try await Task.detached {
                let base = try Self.parseOutdatedJSON(parsedJSON)
                return Self.annotateDisabled(base, brew: brewPath)
            }.value
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
        let targets = upgradeablePackages
        let disabledCount = packages.count - targets.count
        await MainActor.run {
            isUpgrading = true
            lastError = nil
            statusLine = PluginL10n.t("plugin.brew.status.upgrading_all", locale: localeCode())
            objectWillChange.send()
        }
        guard !targets.isEmpty else {
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
                if disabledCount > 0 {
                    lastError = PluginL10n.tf(
                        "plugin.brew.error.only_disabled",
                        locale: localeCode(),
                        disabledCount
                    )
                }
                objectWillChange.send()
            }
            return
        }

        do {
            let formulae = targets.filter { $0.kind == .formula }.map(\.name)
            let casks = targets.filter { $0.kind == .cask }.map(\.name)
            _ = try await Task.detached {
                if !formulae.isEmpty {
                    _ = try Self.run(brew, args: ["upgrade", "--formula"] + formulae, timeout: 900)
                }
                if !casks.isEmpty {
                    _ = try Self.run(brew, args: ["upgrade", "--cask"] + casks, timeout: 900)
                }
            }.value
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
                if disabledCount > 0 {
                    lastError = PluginL10n.tf(
                        "plugin.brew.status.skipped_disabled",
                        locale: localeCode(),
                        disabledCount
                    )
                } else {
                    lastError = nil
                }
                objectWillChange.send()
            }
            await refresh()
        } catch {
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
                lastError = error.localizedDescription
                objectWillChange.send()
            }
            await refresh()
        }
    }

    func upgrade(_ pkg: BrewPackage) async {
        guard let brew = Self.brewPath() else { return }
        if pkg.isDisabled {
            await MainActor.run {
                lastError = PluginL10n.tf(
                    "plugin.brew.error.disabled",
                    locale: localeCode(),
                    pkg.name
                )
                objectWillChange.send()
            }
            return
        }
        await MainActor.run {
            isUpgrading = true
            lastError = nil
            statusLine = PluginL10n.tf("plugin.brew.status.upgrading", locale: localeCode(), pkg.name)
            objectWillChange.send()
        }
        var args = ["upgrade"]
        if pkg.kind == .cask { args.append("--cask") }
        else { args.append("--formula") }
        args.append(pkg.name)
        do {
            _ = try await Task.detached {
                try Self.run(brew, args: args, timeout: 900)
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
            await refresh()
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
            let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    current: current,
                    isDisabled: false
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
                    current: current,
                    isDisabled: false
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Mark formulae/casks that Homebrew has disabled (cannot be upgraded).
    private static func annotateDisabled(_ packages: [BrewPackage], brew: String) -> [BrewPackage] {
        guard !packages.isEmpty else { return packages }
        var disabled = Set<String>()

        let caskNames = packages.filter { $0.kind == .cask }.map(\.name)
        if !caskNames.isEmpty,
           let out = try? run(brew, args: ["info", "--json=v2", "--cask"] + caskNames, timeout: 60) {
            disabled.formUnion(disabledTokens(in: out.stdout, key: "casks"))
        }

        let formulaNames = packages.filter { $0.kind == .formula }.map(\.name)
        if !formulaNames.isEmpty,
           let out = try? run(brew, args: ["info", "--json=v2", "--formula"] + formulaNames, timeout: 60) {
            disabled.formUnion(disabledTokens(in: out.stdout, key: "formulae"))
        }

        guard !disabled.isEmpty else { return packages }
        return packages.map { pkg in
            guard disabled.contains(pkg.name) else { return pkg }
            return BrewPackage(
                id: pkg.id,
                name: pkg.name,
                kind: pkg.kind,
                installed: pkg.installed,
                current: pkg.current,
                isDisabled: true
            )
        }
    }

    private static func disabledTokens(in json: String, key: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj[key] as? [[String: Any]] else { return [] }
        var result = Set<String>()
        for item in items {
            let isDisabled = (item["disabled"] as? Bool) == true
            guard isDisabled else { continue }
            if let token = item["token"] as? String {
                result.insert(token)
            } else if let name = item["name"] as? String {
                result.insert(name)
            } else if let names = item["name"] as? [String], let first = names.first {
                result.insert(first)
            }
        }
        return result
    }

    private struct CmdResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    @discardableResult
    private static func run(_ launchPath: String, args: [String], timeout: TimeInterval) throws -> CmdResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        // Inherit the user environment so password prompts / Homebrew paths work from the GUI.
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + path
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Drain pipes while the process runs — otherwise a chatty `brew upgrade`
        // fills the OS pipe buffer and deadlocks until our timeout kills it.
        let outBox = DataBox()
        let errBox = DataBox()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outBox.append(chunk)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errBox.append(chunk)
            }
        }

        try proc.run()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            proc.waitUntilExit()
            group.leave()
        }
        let waited = group.wait(timeout: .now() + timeout)
        if waited == .timedOut {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            Self.terminateProcessTree(proc)
            throw NSError(
                domain: "BrewStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "brew timed out"]
            )
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Pick up any residual bytes after handlers are cleared.
        outBox.append(out.fileHandleForReading.readDataToEndOfFile())
        errBox.append(err.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
        let result = CmdResult(stdout: stdout, stderr: stderr, status: proc.terminationStatus)
        if result.status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty {
                throw NSError(
                    domain: "BrewStore",
                    code: Int(result.status),
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            throw NSError(
                domain: "BrewStore",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "brew exited with status \(result.status)"]
            )
        }
        return result
    }

    private static func terminateProcessTree(_ proc: Process) {
        // Do not signal -pid: brew shares ALWM's process group by default.
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }
    }
}
