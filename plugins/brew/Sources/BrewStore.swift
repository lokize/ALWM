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
            let loc = localeCode()
            _ = try? await Task.detached {
                try Self.run(brew, args: ["update", "--quiet"], timeout: 120, locale: loc)
            }.value
            let output = try await Task.detached {
                try Self.run(brew, args: ["outdated", "--json=v2"], timeout: 90, locale: loc)
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

        // One-by-one so a single broken cask (missing app / sudo) does not abort the rest.
        var failures: [String] = []
        for pkg in targets {
            await MainActor.run {
                statusLine = PluginL10n.tf(
                    "plugin.brew.status.upgrading",
                    locale: localeCode(),
                    pkg.name
                )
                objectWillChange.send()
            }
            var args = ["upgrade"]
            if pkg.kind == .cask { args.append("--cask") }
            else { args.append("--formula") }
            args.append(pkg.name)
            let loc = localeCode()
            do {
                _ = try await Task.detached {
                    try Self.run(brew, args: args, timeout: 900, locale: loc)
                }.value
            } catch {
                failures.append("\(pkg.name): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            isUpgrading = false
            statusLine = ""
            var notes: [String] = []
            if disabledCount > 0 {
                notes.append(PluginL10n.tf(
                    "plugin.brew.status.skipped_disabled",
                    locale: localeCode(),
                    disabledCount
                ))
            }
            if !failures.isEmpty {
                notes.append(failures.joined(separator: "\n"))
            }
            lastError = notes.isEmpty ? nil : notes.joined(separator: "\n")
            objectWillChange.send()
        }
        await refresh()
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
        let loc = localeCode()
        do {
            _ = try await Task.detached {
                try Self.run(brew, args: args, timeout: 900, locale: loc)
            }.value
            await MainActor.run {
                isUpgrading = false
                statusLine = ""
                lastError = nil
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

    /// Escape a string for use inside an AppleScript `"…"` literal.
    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// osascript askpass so Homebrew's `sudo -A` works from the menu-bar app (no TTY).
    /// Regenerated each call so the dialog matches the app language.
    private static func ensureAskpassHelper(locale: String) -> String? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ALWM/Helpers", isDirectory: true)
        let script = dir.appendingPathComponent("brew-sudo-askpass.sh")
        let title = appleScriptEscape(PluginL10n.t("plugin.brew.askpass.title", locale: locale))
        let message = appleScriptEscape(PluginL10n.t("plugin.brew.askpass.message", locale: locale))
        let cancel = appleScriptEscape(PluginL10n.t("plugin.brew.askpass.cancel", locale: locale))
        let ok = appleScriptEscape(PluginL10n.t("plugin.brew.askpass.ok", locale: locale))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let body = """
            #!/bin/bash
            # Used by ALWM Brew plugin — do not run manually.
            osascript <<'APPLESCRIPT'
            try
              tell application "System Events"
                activate
                set dlg to display dialog "\(message)" default answer "" with title "\(title)" with hidden answer buttons {"\(cancel)", "\(ok)"} default button "\(ok)" cancel button "\(cancel)"
                return text returned of dlg
              end tell
            on error
              return
            end try
            APPLESCRIPT
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: script.path
            )
            return script.path
        } catch {
            NSLog("ALWM Brew: failed to write askpass helper: %@", error.localizedDescription)
            return nil
        }
    }

    private static func appendLog(_ text: String) {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let dir = base.appendingPathComponent("Logs/ALWM", isDirectory: true)
        let file = dir.appendingPathComponent("brew.log")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let chunk = "\n—— \(stamp) ——\n\(text)\n"
            if !FileManager.default.fileExists(atPath: file.path) {
                try chunk.write(to: file, atomically: true, encoding: .utf8)
            } else if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = chunk.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            }
        } catch {
            NSLog("ALWM Brew: log write failed: %@", error.localizedDescription)
        }
    }

    /// Prefer `Error:` lines from brew output — brew can exit 0 after partial failures.
    private static func brewFailureMessage(stdout: String, stderr: String, status: Int32) -> String? {
        let combined = [stderr, stdout].joined(separator: "\n")
        let errorLines = combined
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Error:") }
        if !errorLines.isEmpty {
            return errorLines.suffix(3).joined(separator: "\n")
        }
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { return msg }
            return "brew exited with status \(status)"
        }
        if combined.localizedCaseInsensitiveContains("a password is required")
            || combined.localizedCaseInsensitiveContains("a terminal is required to read the password") {
            return "sudo: a password is required (Homebrew upgrade needs admin access)"
        }
        return nil
    }

    @discardableResult
    private static func run(
        _ launchPath: String,
        args: [String],
        timeout: TimeInterval,
        locale: String = PluginL10n.currentCode
    ) throws -> CmdResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + path
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        // Without SUDO_ASKPASS, brew→sudo fails with "a terminal is required" from the GUI.
        if let askpass = ensureAskpassHelper(locale: locale) {
            env["SUDO_ASKPASS"] = askpass
        }
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

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

        let cmdline = ([launchPath] + args).joined(separator: " ")
        NSLog("ALWM Brew: running %@", cmdline)
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
            let msg = "brew timed out"
            appendLog("$ \(cmdline)\n\(msg)")
            throw NSError(
                domain: "BrewStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outBox.append(out.fileHandleForReading.readDataToEndOfFile())
        errBox.append(err.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
        let result = CmdResult(stdout: stdout, stderr: stderr, status: proc.terminationStatus)
        appendLog("$ \(cmdline)\nexit \(result.status)\n\(stderr)\n\(stdout)")

        if let failure = brewFailureMessage(stdout: stdout, stderr: stderr, status: result.status) {
            NSLog("ALWM Brew: failure — %@", failure)
            throw NSError(
                domain: "BrewStore",
                code: Int(result.status == 0 ? 1 : result.status),
                userInfo: [NSLocalizedDescriptionKey: failure]
            )
        }
        return result
    }

    private static func terminateProcessTree(_ proc: Process) {
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
