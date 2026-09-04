import AppKit
import Foundation

/// Checks GitHub Releases and installs ALWM updates from the published DMG.
@MainActor
public final class AppUpdateService: ObservableObject {
    public static let shared = AppUpdateService()

    /// Public repo that hosts release DMGs.
    public static let githubOwner = "lokize"
    public static let githubRepo = "ALWM"

    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var latestVersion: String?
    @Published public private(set) var dmgURL: URL?

    public var installedVersion: String { AlwmVersion.installed }

    public var isUpdateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.compareVersions(installedVersion, latest) == .orderedAscending
    }

    private var checkTask: Task<Void, Never>?

    private init() {}

    public func checkForUpdates(force: Bool = false) {
        if !force, case .checking = phase { return }
        if !force, case .downloading = phase { return }
        if !force, case .installing = phase { return }
        checkTask?.cancel()
        checkTask = Task { await performCheck() }
    }

    public func installUpdate() {
        guard isUpdateAvailable, let url = dmgURL, let version = latestVersion else { return }
        Task { await performInstall(dmgURL: url, version: version) }
    }

    private func performCheck() async {
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            guard !Task.isCancelled else { return }
            latestVersion = release.version
            dmgURL = release.dmgURL
            if Self.compareVersions(installedVersion, release.version) == .orderedAscending {
                phase = .available
            } else {
                phase = .upToDate
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func performInstall(dmgURL: URL, version: String) async {
        phase = .downloading
        do {
            let dmgFile = try await downloadDMG(from: dmgURL, version: version)
            phase = .installing
            let stagedApp = try await mountAndExtractApp(dmg: dmgFile)
            try scheduleReplaceAndRelaunch(newApp: stagedApp)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - GitHub

    private struct LatestRelease {
        var version: String
        var dmgURL: URL
    }

    private func fetchLatestRelease() async throws -> LatestRelease {
        let api = URL(string: "https://api.github.com/repos/\(Self.githubOwner)/\(Self.githubRepo)/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ALWM-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        let version = decoded.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let asset = decoded.assets.first(where: {
            $0.name.lowercased().hasSuffix(".dmg") && $0.name.uppercased().contains("ALWM")
        }) ?? decoded.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError.noDMG
        }
        guard let url = URL(string: asset.browser_download_url) else {
            throw UpdateError.noDMG
        }
        return LatestRelease(version: version, dmgURL: url)
    }

    private struct GitHubReleaseDTO: Decodable {
        var tag_name: String
        var assets: [Asset]
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
        }
    }

    // MARK: - Download / install

    private func downloadDMG(from url: URL, version: String) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALWM-\(version)-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func mountAndExtractApp(dmg: URL) async throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-dmg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachStatus = try await runProcess(
            "/usr/bin/hdiutil",
            [
                "attach", dmg.path,
                "-mountpoint", mountPoint.path,
                "-nobrowse",
                "-readonly",
                "-quiet"
            ]
        )
        guard attachStatus == 0 else {
            throw UpdateError.mountFailed
        }

        defer {
            Task.detached {
                _ = try? await Self.runProcessStatic(
                    "/usr/bin/hdiutil",
                    ["detach", mountPoint.path, "-quiet", "-force"]
                )
            }
        }

        let mountedApp = mountPoint.appendingPathComponent("ALWM.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw UpdateError.appMissingInDMG
        }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALWM-update-\(UUID().uuidString).app", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        let dittoStatus = try await runProcess(
            "/usr/bin/ditto",
            [mountedApp.path, staged.path]
        )
        guard dittoStatus == 0 else {
            throw UpdateError.copyFailed
        }

        // Detach before relaunch helper runs.
        _ = try await runProcess(
            "/usr/bin/hdiutil",
            ["detach", mountPoint.path, "-quiet", "-force"]
        )
        return staged
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) async throws -> Int32 {
        try await Self.runProcessStatic(launchPath, arguments)
    }

    nonisolated private static func runProcessStatic(_ launchPath: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: launchPath)
                    proc.arguments = arguments
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try proc.run()
                    proc.waitUntilExit()
                    continuation.resume(returning: proc.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func scheduleReplaceAndRelaunch(newApp: URL) throws {
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app" else {
            throw UpdateError.invalidInstallLocation
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail
        PID=\(pid)
        SRC=\(shellEscape(newApp.path))
        DST=\(shellEscape(destination.path))
        while kill -0 "$PID" 2>/dev/null; do sleep 0.15; done
        sleep 0.4
        rm -rf "$DST"
        /usr/bin/ditto "$SRC" "$DST"
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
        /usr/bin/open "$DST"
        rm -rf "$SRC"
        rm -f -- "$0"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-update-relaunch-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        try proc.run()

        // Quit so the helper can replace the bundle and reopen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Version compare

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parseVersion(lhs)
        let b = parseVersion(rhs)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    public enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case noDMG
        case mountFailed
        case appMissingInDMG
        case copyFailed
        case invalidInstallLocation

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "GitHub HTTP \(code)"
            case .noDMG: return "No DMG asset in the latest release"
            case .mountFailed: return "Could not mount the DMG"
            case .appMissingInDMG: return "ALWM.app not found in the DMG"
            case .copyFailed: return "Could not copy ALWM.app from the DMG"
            case .invalidInstallLocation: return "ALWM is not running from an .app bundle"
            }
        }
    }
}
