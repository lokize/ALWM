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
            // GitHub DMGs are ad-hoc signed (CDHash changes every build → TCC resets).
            // Re-sign with the same stable identity as the running install when possible.
            try await resignForStableTCC(app: stagedApp)
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

    // MARK: - Code signing (preserve TCC)

    /// Prefer the identity of the currently installed app; fall back to local ALWM cert.
    private func preferredSigningIdentity() async -> String? {
        if let running = await signingIdentity(of: Bundle.main.bundleURL),
           running != "-",
           !running.isEmpty {
            return running
        }
        if await codesigningIdentityExists("ALWM Local Signing") {
            return "ALWM Local Signing"
        }
        return nil
    }

    private func resignForStableTCC(app: URL) async throws {
        guard let identity = await preferredSigningIdentity() else {
            NSLog("[ALWM] Update: no stable codesign identity — permissions may need re-grant after install")
            return
        }

        let entitlements = try entitlementsFileForSigning(app: app)

        // Nested code first (plugins / dylibs), then the app with --deep.
        if let frameworks = optionalDirectory(app.appendingPathComponent("Contents/Frameworks")) {
            let files = (try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "dylib" || file.lastPathComponent.hasPrefix("lib") {
                _ = try await runProcess("/usr/bin/codesign", [
                    "--force", "--sign", identity,
                    "--identifier", "dev.alwm.ALWM.frameworks",
                    file.path
                ])
            }
        }
        if let plugins = optionalDirectory(app.appendingPathComponent("Contents/PlugIns")) {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
            for plug in bundles where plug.pathExtension == "alwmplugin" {
                _ = try await runProcess("/usr/bin/codesign", [
                    "--force", "--deep", "--sign", identity,
                    "--identifier", plug.deletingPathExtension().lastPathComponent,
                    plug.path
                ])
            }
        }

        let status = try await runProcess("/usr/bin/codesign", [
            "--force", "--deep",
            "--sign", identity,
            "--identifier", "dev.alwm.ALWM",
            "--entitlements", entitlements.path,
            app.path
        ])
        guard status == 0 else {
            throw UpdateError.resignFailed
        }
        NSLog("[ALWM] Update: re-signed with identity '%@' (TCC-stable)", identity)
    }

    private func entitlementsFileForSigning(app: URL) throws -> URL {
        let bundled = app.appendingPathComponent("Contents/Resources/Alwm.entitlements")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let fromRunning = Bundle.main.url(forResource: "Alwm", withExtension: "entitlements")
        if let fromRunning, FileManager.default.fileExists(atPath: fromRunning.path) {
            return fromRunning
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-update-entitlements-\(UUID().uuidString).plist")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.app-sandbox</key>
            <false/>
        </dict>
        </plist>
        """
        try xml.write(to: temp, atomically: true, encoding: .utf8)
        return temp
    }

    private func optionalDirectory(_ url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    private func signingIdentity(of app: URL) async -> String? {
        let output = await runProcessOutput("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        if output.contains("Signature=adhoc") || output.contains("flags=0x2(adhoc)") {
            return "-"
        }
        // Prefer the leaf Authority= line (last one is usually Apple; first after Executable is signer).
        let authorities = output.split(separator: "\n")
            .compactMap { line -> String? in
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix("Authority=") else { return nil }
                return String(s.dropFirst("Authority=".count))
            }
        return authorities.first
    }

    private func codesigningIdentityExists(_ name: String) async -> Bool {
        let output = await runProcessOutput("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        return output.contains(name) && !output.contains("CSSMERR_TP_NOT_TRUSTED")
    }

    private func runProcessOutput(_ launchPath: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                    + err.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
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
        let destination = preferredInstallDestination()
        guard destination.pathExtension == "app" else {
            throw UpdateError.invalidInstallLocation
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-update.log").path
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-update-relaunch-\(UUID().uuidString).sh")

        let script = """
        #!/bin/bash
        exec >>\(shellEscape(logPath)) 2>&1
        set -euxo pipefail
        echo "ALWM update helper start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "PID=\(pid) SRC=\(shellEscape(newApp.path)) DST=\(shellEscape(destination.path))"
        PID=\(pid)
        SRC=\(shellEscape(newApp.path))
        DST=\(shellEscape(destination.path))

        # Wait for the running app to exit (parent would kill us if we stayed attached).
        for _ in $(seq 1 200); do
          if ! kill -0 "$PID" 2>/dev/null; then
            break
          fi
          sleep 0.15
        done
        kill -9 "$PID" 2>/dev/null || true
        # Clear any leftover ALWM instances before replacing the bundle.
        /usr/bin/pkill -9 -x ALWM 2>/dev/null || true
        sleep 0.6

        if [[ ! -d "$SRC/Contents/MacOS" ]]; then
          echo "error: staged app missing: $SRC"
          exit 1
        fi

        /bin/rm -rf "$DST"
        /usr/bin/ditto "$SRC" "$DST"
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
        /bin/chmod -R u+rwX "$DST" || true
        /bin/chmod +x "$DST/Contents/MacOS/ALWM" 2>/dev/null || true

        echo "Launching $DST"
        # LSUIElement agent: open -n starts a new instance; -g keeps focus quiet.
        if ! /usr/bin/open -n -g "$DST"; then
          echo "open -n -g failed — trying open -n"
          /usr/bin/open -n "$DST" || true
        fi
        sleep 1
        if ! /usr/bin/pgrep -x ALWM >/dev/null 2>&1; then
          echo "pgrep miss — launching binary directly"
          nohup "$DST/Contents/MacOS/ALWM" >/dev/null 2>&1 &
          disown || true
          sleep 0.8
        fi
        if /usr/bin/pgrep -x ALWM >/dev/null 2>&1; then
          echo "ALWM is running after update"
        else
          echo "error: ALWM failed to relaunch"
          exit 1
        fi

        /bin/rm -rf "$SRC"
        echo "ALWM update helper done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        /bin/rm -f -- "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Detach from ALWM's process group so NSApp.terminate does not kill the helper.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [
            "-c",
            "(/usr/bin/nohup \(shellEscape(scriptURL.path)) >/dev/null 2>&1 &)"
        ]
        try launcher.run()
        launcher.waitUntilExit()
        guard launcher.terminationStatus == 0 else {
            throw UpdateError.relaunchHelperFailed
        }

        // Give nohup a beat to start waiting on our PID, then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
            // Hard exit if terminate is deferred by a window/sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                exit(0)
            }
        }
    }

    /// Prefer ~/Applications/ALWM.app when that is the install we manage.
    private func preferredInstallDestination() -> URL {
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let homeApp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ALWM.app")
        if running.path == homeApp.path { return homeApp }
        if running.path.hasSuffix("/Applications/ALWM.app") { return running }
        if FileManager.default.fileExists(atPath: homeApp.path) {
            // Updates from a stray copy still land in the managed install location.
            return homeApp
        }
        return running
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
        case resignFailed
        case relaunchHelperFailed

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "GitHub HTTP \(code)"
            case .noDMG: return "No DMG asset in the latest release"
            case .mountFailed: return "Could not mount the DMG"
            case .appMissingInDMG: return "ALWM.app not found in the DMG"
            case .copyFailed: return "Could not copy ALWM.app from the DMG"
            case .invalidInstallLocation: return "ALWM is not running from an .app bundle"
            case .resignFailed: return "Could not re-sign the update (permissions may reset)"
            case .relaunchHelperFailed: return "Could not start the update relaunch helper"
            }
        }
    }
}
