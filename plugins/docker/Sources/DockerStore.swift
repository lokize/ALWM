import AppKit
import Foundation
import AlwmL10n
import AlwmPluginAPI

// MARK: - Models

struct DockerContainer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let status: String
    let state: String
    let ports: String
    let created: String
    let restartPolicy: String
    let composeProject: String?

    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }
    var isExited: Bool { state == "exited" || state == "created" || state == "dead" }

    var shortID: String { String(id.prefix(12)) }

    var stateLabel: String {
        switch state {
        case "running": return "Running"
        case "paused": return "Paused"
        case "exited": return "Exited"
        case "restarting": return "Restarting"
        case "created": return "Created"
        case "dead": return "Dead"
        default: return state.capitalized
        }
    }
}

enum DockerRestartPolicy: String, CaseIterable, Identifiable, Sendable {
    case no = "no"
    case always = "always"
    case unlessStopped = "unless-stopped"
    case onFailure = "on-failure"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .no: return "No"
        case .always: return "Always"
        case .unlessStopped: return "Unless stopped"
        case .onFailure: return "On failure"
        }
    }

    static func parse(_ raw: String) -> DockerRestartPolicy {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self(rawValue: s) ?? .no
    }
}

struct DockerComposeProject: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var composeYAML: String
    var dockerfile: String?
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    var hasDockerfile: Bool {
        guard let d = dockerfile else { return false }
        return !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DockerComposeStatus: Equatable, Sendable {
    var services: [ComposeServiceRow]
    var raw: String
}

struct ComposeServiceRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let ports: String
}

enum DockerTab: String, CaseIterable, Identifiable {
    case containers
    case compose
    var id: String { rawValue }
}

// MARK: - Store

final class DockerStore: ObservableObject, @unchecked Sendable {
    static let shared = DockerStore()

    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var projects: [DockerComposeProject] = []
    @Published private(set) var dockerAvailable = false
    @Published private(set) var dockerVersion = ""
    @Published private(set) var composeAvailable = false
    @Published private(set) var lastError: String?
    @Published private(set) var busyMessage: String?
    @Published private(set) var lastLogs: String = ""
    @Published private(set) var lastExportPath: String?
    @Published private(set) var composeStatus: DockerComposeStatus?
    @Published var selectedTab: DockerTab = .containers
    @Published var containerFilter: String = ""
    @Published var showAllContainers = true
    @Published var selectedContainerID: String?
    @Published var selectedProjectID: String?

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var lastBarSignature = ""
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Publish UI state only on the main actor (SwiftUI crashes otherwise).
    @MainActor
    private func publishBarIfNeeded() {
        let sig = "\(runningCount)/\(totalCount)/\(dockerAvailable)"
        guard sig != lastBarSignature else { return }
        lastBarSignature = sig
        onChange?()
    }

    var runningCount: Int { containers.filter(\.isRunning).count }
    var totalCount: Int { containers.count }

    var barLabel: String {
        guard dockerAvailable else { return "—" }
        return "\(runningCount)/\(totalCount)"
    }

    var barTint: NSColor {
        if !dockerAvailable { return .secondaryLabelColor }
        if runningCount > 0 { return .systemBlue }
        return .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        if !dockerAvailable {
            return PluginL10n.t("plugin.docker.tooltip.missing", locale: loc)
        }
        return PluginL10n.tf(
            "plugin.docker.tooltip.count",
            locale: loc,
            runningCount,
            totalCount
        )
    }

    var filteredContainers: [DockerContainer] {
        var list = containers
        if !showAllContainers {
            list = list.filter { $0.isRunning || $0.isPaused }
        }
        let q = containerFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || $0.image.lowercased().contains(q)
                    || $0.id.lowercased().contains(q)
                    || ($0.composeProject?.lowercased().contains(q) ?? false)
            }
        }
        return list
    }

    var selectedContainer: DockerContainer? {
        guard let id = selectedContainerID else { return nil }
        return containers.first(where: { $0.id == id })
    }

    var selectedProject: DockerComposeProject? {
        guard let id = selectedProjectID else { return nil }
        return projects.first(where: { $0.id == id })
    }

    private var projectsRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config/alwm/plugins/docker-compose-projects", isDirectory: true)
    }

    private var backupsRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config/alwm/plugins/docker-backups", isDirectory: true)
    }

    func start() {
        loadProjects()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh(quiet: true)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(quiet: Bool = false) async {
        await MainActor.run {
            if !quiet { busyMessage = "Refreshing…" }
        }

        let bin = Self.resolveDockerBinary()
        guard let bin else {
            await MainActor.run {
                dockerAvailable = false
                dockerVersion = ""
                composeAvailable = false
                containers = []
                if !quiet {
                    lastError = "Docker CLI not found. Install Docker Desktop."
                    busyMessage = nil
                }
                publishBarIfNeeded()
            }
            return
        }

        let ver = await Self.run(bin, ["version", "--format", "{{.Client.Version}}"])
        let versionOK = ver.code == 0
        let versionText = ver.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if !versionOK {
            await MainActor.run {
                dockerAvailable = false
                dockerVersion = versionText
                containers = []
                lastError = ver.stderr.isEmpty ? "Cannot reach Docker daemon." : ver.stderr
                if !quiet { busyMessage = nil }
                publishBarIfNeeded()
            }
            return
        }

        let composeCheck = await Self.run(bin, ["compose", "version", "--short"])
        let ids = await Self.run(bin, ["ps", "-aq"])
        guard ids.code == 0 else {
            await MainActor.run {
                dockerAvailable = true
                dockerVersion = versionText
                composeAvailable = composeCheck.code == 0
                lastError = ids.stderr.isEmpty ? "Failed to list containers." : ids.stderr
                if !quiet { busyMessage = nil }
                publishBarIfNeeded()
            }
            return
        }
        let idList = ids.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var parsed: [DockerContainer] = []
        if !idList.isEmpty {
            let fmt = "{{.Id}}\t{{.Name}}\t{{.Config.Image}}\t{{.State.Status}}\t{{range $p,$c:=.NetworkSettings.Ports}}{{$p}} {{end}}\t{{.Created}}\t{{.HostConfig.RestartPolicy.Name}}\t{{index .Config.Labels \"com.docker.compose.project\"}}"
            let insp = await Self.run(bin, ["inspect", "--format", fmt] + idList)
            if insp.code == 0 {
                for line in insp.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 7 else { continue }
                    let rawName = parts[1].hasPrefix("/") ? String(parts[1].dropFirst()) : parts[1]
                    let state = parts[3].lowercased()
                    let project = parts.count > 7
                        ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines)
                        : ""
                    let policy = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
                    parsed.append(DockerContainer(
                        id: parts[0],
                        name: rawName,
                        image: parts[2],
                        status: state,
                        state: state,
                        ports: parts[4].trimmingCharacters(in: .whitespacesAndNewlines),
                        created: parts[5],
                        restartPolicy: policy.isEmpty ? "no" : policy,
                        composeProject: project.isEmpty ? nil : project
                    ))
                }
            } else {
                let list = await Self.run(bin, [
                    "ps", "-a",
                    "--format",
                    "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.State}}\t{{.Ports}}\t{{.CreatedAt}}\t{{.Label \"com.docker.compose.project\"}}"
                ])
                for line in list.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 7 else { continue }
                    let project = parts.count > 7 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    parsed.append(DockerContainer(
                        id: parts[0],
                        name: parts[1],
                        image: parts[2],
                        status: parts[3],
                        state: parts[4].lowercased(),
                        ports: parts[5],
                        created: parts[6],
                        restartPolicy: "no",
                        composeProject: project.isEmpty ? nil : project
                    ))
                }
            }
        }

        await MainActor.run {
            dockerAvailable = true
            dockerVersion = versionText
            composeAvailable = composeCheck.code == 0
            containers = parsed
            if let sel = selectedContainerID, !parsed.contains(where: { $0.id == sel }) {
                selectedContainerID = nil
            }
            lastError = nil
            if !quiet { busyMessage = nil }
            publishBarIfNeeded()
        }
    }

    // MARK: Container actions

    func startContainer(_ c: DockerContainer) async { await runAction(["start", c.id], busy: "Starting \(c.name)…") }
    func stopContainer(_ c: DockerContainer) async { await runAction(["stop", c.id], busy: "Stopping \(c.name)…") }
    func restartContainer(_ c: DockerContainer) async { await runAction(["restart", c.id], busy: "Restarting \(c.name)…") }
    func pauseContainer(_ c: DockerContainer) async { await runAction(["pause", c.id], busy: "Pausing \(c.name)…") }
    func unpauseContainer(_ c: DockerContainer) async { await runAction(["unpause", c.id], busy: "Unpausing \(c.name)…") }
    func killContainer(_ c: DockerContainer) async { await runAction(["kill", c.id], busy: "Killing \(c.name)…") }

    func removeContainer(_ c: DockerContainer, force: Bool) async {
        var args = ["rm"]
        if force { args.append("-f") }
        args.append(c.id)
        await runAction(args, busy: "Removing \(c.name)…")
        await MainActor.run {
            if selectedContainerID == c.id { selectedContainerID = nil }
        }
    }

    func setRestartPolicy(_ c: DockerContainer, policy: DockerRestartPolicy) async {
        await runAction(
            ["update", "--restart=\(policy.rawValue)", c.id],
            busy: "Updating restart policy…"
        )
    }

    func exportContainer(_ c: DockerContainer) async {
        guard let bin = Self.resolveDockerBinary() else { return }
        await MainActor.run { busyMessage = "Exporting \(c.name)…" }

        let fm = FileManager.default
        try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeName = c.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let out = backupsRoot.appendingPathComponent("\(safeName)-\(stamp).tar")

        let r = await Self.run(bin, ["export", "-o", out.path, c.id])
        await MainActor.run {
            busyMessage = nil
            if r.code == 0 {
                lastExportPath = out.path
                lastError = nil
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } else {
                lastError = r.stderr.isEmpty ? "Export failed." : r.stderr
            }
        }
    }

    func fetchLogs(_ c: DockerContainer, lines: Int = 120) async {
        guard let bin = Self.resolveDockerBinary() else { return }
        await MainActor.run { busyMessage = "Fetching logs…" }
        let r = await Self.run(bin, ["logs", "--tail", "\(lines)", c.id])
        await MainActor.run {
            busyMessage = nil
            lastLogs = r.stdout.isEmpty ? r.stderr : r.stdout
            if r.code != 0 && lastLogs.isEmpty {
                lastError = "Could not read logs."
            }
        }
    }

    // MARK: Compose projects

    func loadProjects() {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = []
            return
        }

        var loaded: [DockerComposeProject] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let metaURL = dir.appendingPathComponent("project.json")
            let composeURL = dir.appendingPathComponent("docker-compose.yml")
            guard let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(ProjectMeta.self, from: metaData),
                  let yaml = try? String(contentsOf: composeURL, encoding: .utf8)
            else { continue }
            let dockerURL = dir.appendingPathComponent("Dockerfile")
            let docker = (try? String(contentsOf: dockerURL, encoding: .utf8))
            loaded.append(DockerComposeProject(
                id: meta.id,
                name: meta.name,
                composeYAML: yaml,
                dockerfile: docker,
                notes: meta.notes,
                createdAt: meta.createdAt,
                updatedAt: meta.updatedAt
            ))
        }
        projects = loaded.sorted { $0.updatedAt > $1.updatedAt }
        if let sel = selectedProjectID, !projects.contains(where: { $0.id == sel }) {
            selectedProjectID = nil
            composeStatus = nil
        }
    }

    @discardableResult
    func saveProject(
        id: String? = nil,
        name: String,
        composeYAML: String,
        dockerfile: String?,
        notes: String
    ) -> DockerComposeProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Project name is required."
            return nil
        }
        let yaml = composeYAML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !yaml.isEmpty else {
            lastError = "docker-compose.yml content is required."
            return nil
        }

        let projectID = id ?? UUID().uuidString
        let existing = projects.first(where: { $0.id == projectID })
        let folderName = Self.sanitizeFolderName(trimmed) + "-" + String(projectID.prefix(8))
        let dir: URL
        if let existing {
            dir = projectDirectory(for: existing) ?? projectsRoot.appendingPathComponent(folderName, isDirectory: true)
        } else {
            dir = projectsRoot.appendingPathComponent(folderName, isDirectory: true)
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try yaml.write(to: dir.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)

            let dockerURL = dir.appendingPathComponent("Dockerfile")
            let dockerTrim = dockerfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if dockerTrim.isEmpty {
                if fm.fileExists(atPath: dockerURL.path) {
                    try? fm.removeItem(at: dockerURL)
                }
            } else {
                try dockerTrim.write(to: dockerURL, atomically: true, encoding: .utf8)
            }

            let now = Date()
            let meta = ProjectMeta(
                id: projectID,
                name: trimmed,
                notes: notes,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            let metaData = try encoder.encode(meta)
            try metaData.write(to: dir.appendingPathComponent("project.json"), options: .atomic)

            let saved = DockerComposeProject(
                id: projectID,
                name: trimmed,
                composeYAML: yaml,
                dockerfile: dockerTrim.isEmpty ? nil : dockerTrim,
                notes: notes,
                createdAt: meta.createdAt,
                updatedAt: meta.updatedAt
            )
            loadProjects()
            selectedProjectID = projectID
            lastError = nil
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func deleteProject(_ p: DockerComposeProject) {
        if let dir = projectDirectory(for: p) {
            try? FileManager.default.removeItem(at: dir)
        }
        if selectedProjectID == p.id {
            selectedProjectID = nil
            composeStatus = nil
        }
        loadProjects()
    }

    func openProjectFolder(_ p: DockerComposeProject) {
        guard let dir = projectDirectory(for: p) else { return }
        NSWorkspace.shared.open(dir)
    }

    func composeUp(_ p: DockerComposeProject, build: Bool = false) async {
        var args = ["up", "-d"]
        if build { args.append("--build") }
        await runCompose(p, args, busy: "Compose up \(p.name)…")
        await refreshComposeStatus(p)
        await refresh(quiet: true)
    }

    func composeDown(_ p: DockerComposeProject, volumes: Bool = false) async {
        var args = ["down"]
        if volumes { args.append("-v") }
        await runCompose(p, args, busy: "Compose down \(p.name)…")
        await refreshComposeStatus(p)
        await refresh(quiet: true)
    }

    func composeStop(_ p: DockerComposeProject) async {
        await runCompose(p, ["stop"], busy: "Stopping \(p.name)…")
        await refreshComposeStatus(p)
        await refresh(quiet: true)
    }

    func composeStart(_ p: DockerComposeProject) async {
        await runCompose(p, ["start"], busy: "Starting \(p.name)…")
        await refreshComposeStatus(p)
        await refresh(quiet: true)
    }

    func composePull(_ p: DockerComposeProject) async {
        await runCompose(p, ["pull"], busy: "Pulling \(p.name)…")
    }

    func refreshComposeStatus(_ p: DockerComposeProject) async {
        guard let bin = Self.resolveDockerBinary(), let dir = projectDirectory(for: p) else {
            await MainActor.run { composeStatus = nil }
            return
        }
        let r = await Self.run(bin, ["compose", "ps", "--format", "{{.Name}}\t{{.Status}}\t{{.Ports}}"], cwd: dir.path)
        guard r.code == 0 else {
            await MainActor.run {
                composeStatus = DockerComposeStatus(services: [], raw: r.stderr)
            }
            return
        }
        var rows: [ComposeServiceRow] = []
        for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            rows.append(ComposeServiceRow(
                id: parts[0],
                name: parts[0],
                status: parts[1],
                ports: parts.count > 2 ? parts[2] : ""
            ))
        }
        await MainActor.run {
            composeStatus = DockerComposeStatus(services: rows, raw: r.stdout)
        }
    }

    // MARK: Private

    private func runAction(_ args: [String], busy: String) async {
        guard let bin = Self.resolveDockerBinary() else { return }
        await MainActor.run { busyMessage = busy }
        let r = await Self.run(bin, args)
        await MainActor.run {
            busyMessage = nil
            if r.code != 0 {
                lastError = r.stderr.isEmpty ? "Command failed: docker \(args.joined(separator: " "))" : r.stderr
            } else {
                lastError = nil
            }
        }
        await refresh(quiet: true)
    }

    private func runCompose(_ p: DockerComposeProject, _ args: [String], busy: String) async {
        let available = await MainActor.run { composeAvailable }
        guard let bin = Self.resolveDockerBinary(), available else {
            await MainActor.run { lastError = "Docker Compose not available." }
            return
        }
        guard let dir = projectDirectory(for: p) else {
            await MainActor.run { lastError = "Project folder missing." }
            return
        }
        await MainActor.run { busyMessage = busy }
        let r = await Self.run(bin, ["compose"] + args, cwd: dir.path)
        await MainActor.run {
            busyMessage = nil
            if r.code != 0 {
                lastError = r.stderr.isEmpty ? "Compose failed." : r.stderr
            } else {
                lastError = nil
            }
        }
    }

    private func projectDirectory(for p: DockerComposeProject) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(ProjectMeta.self, from: data),
                  meta.id == p.id
            else { continue }
            return dir
        }
        return nil
    }

    private static func sanitizeFolderName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let s = String(cleaned).lowercased()
        return s.isEmpty ? "project" : String(s.prefix(40))
    }

    private static func resolveDockerBinary() -> String? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let which = runSync("/usr/bin/which", ["docker"])
        let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private struct CmdResult: Sendable {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ launchPath: String, _ args: [String], cwd: String? = nil) async -> CmdResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(launchPath, args, cwd: cwd))
            }
        }
    }

    private static func runSync(_ launchPath: String, _ args: [String], cwd: String? = nil) -> CmdResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:" + path
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return CmdResult(code: -1, stdout: "", stderr: error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CmdResult(code: p.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private struct ProjectMeta: Codable {
        let id: String
        let name: String
        let notes: String
        let createdAt: Date
        let updatedAt: Date
    }
}
