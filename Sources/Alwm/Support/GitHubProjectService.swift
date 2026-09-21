import AppKit
import Foundation

/// Public star count for `lokize/ALWM`, plus starring when a GitHub token is available
/// (plugin settings or `gh` CLI).
@MainActor
public final class GitHubProjectService: ObservableObject {
    public static let shared = GitHubProjectService()

    public static var repositoryURL: URL {
        URL(string: "https://github.com/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)")!
    }

    public enum StarPhase: Equatable {
        case idle
        case loading
        case ready
        case starring
        case failed(String)
    }

    @Published public private(set) var starCount: Int?
    @Published public private(set) var isStarred = false
    @Published public private(set) var hasAuthToken = false
    @Published public private(set) var phase: StarPhase = .idle

    private var loadTask: Task<Void, Never>?
    private var starTask: Task<Void, Never>?

    private init() {}

    public var formattedStarCount: String {
        guard let starCount else { return "—" }
        return Self.formatCount(starCount)
    }

    public func refreshIfNeeded(force: Bool = false) {
        if !force, phase == .loading || phase == .starring { return }
        if !force, phase == .ready, starCount != nil { return }
        loadTask?.cancel()
        loadTask = Task { await self.load() }
    }

    public func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    /// Stars the repo when authenticated; otherwise opens GitHub in the browser.
    public func starOrOpen() {
        if isStarred {
            openRepository()
            return
        }
        starTask?.cancel()
        starTask = Task { await self.performStar() }
    }

    private func load() async {
        phase = .loading
        let token = await Self.resolveToken()
        hasAuthToken = token != nil
        do {
            async let count = Self.fetchStarCount()
            async let starred: Bool = {
                guard let token else { return false }
                return try await Self.fetchIsStarred(token: token)
            }()
            let (c, s) = try await (count, starred)
            guard !Task.isCancelled else { return }
            starCount = c
            isStarred = s
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            if starCount == nil {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .ready
            }
        }
    }

    private func performStar() async {
        guard let token = await Self.resolveToken() else {
            hasAuthToken = false
            openRepository()
            return
        }
        hasAuthToken = true
        phase = .starring
        do {
            try await Self.putStar(token: token)
            guard !Task.isCancelled else { return }
            isStarred = true
            if let current = starCount {
                starCount = current + 1
            } else {
                starCount = try? await Self.fetchStarCount()
            }
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
            openRepository()
        }
    }

    // MARK: - Networking

    private static func fetchStarCount() async throws -> Int {
        let url = URL(
            string: "https://api.github.com/repos/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)"
        )!
        var request = URLRequest(url: url)
        request.setValue("ALWM/\(AlwmVersion.installed)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(RepoDTO.self, from: data)
        return decoded.stargazers_count
    }

    private static func fetchIsStarred(token: String) async throws -> Bool {
        let url = URL(
            string: "https://api.github.com/user/starred/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)"
        )!
        var request = URLRequest(url: url)
        Self.applyAuth(&request, token: token)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 204 { return true }
        if http.statusCode == 404 { return false }
        throw URLError(.badServerResponse)
    }

    private static func putStar(token: String) async throws {
        let url = URL(
            string: "https://api.github.com/user/starred/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)"
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        Self.applyAuth(&request, token: token)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 204 || http.statusCode == 304
        else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    private static func applyAuth(_ request: inout URLRequest, token: String) {
        request.setValue("ALWM/\(AlwmVersion.installed)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Auth

    private static func resolveToken() async -> String? {
        if let plugin = pluginToken(), !plugin.isEmpty { return plugin }
        if let gh = await ghCLIToken(), !gh.isEmpty { return gh }
        return nil
    }

    private static func pluginToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins/dev.alwm.github.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String
        else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func ghCLIToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["gh", "auth", "token"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(2.5)
                    while process.isRunning, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        process.terminate()
                        continuation.resume(returning: nil)
                        return
                    }
                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let token = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (token?.isEmpty == false) ? token : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func formatCount(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 10_000 {
            let k = Double(value) / 1_000
            return String(format: "%.1fk", k).replacingOccurrences(of: ".0k", with: "k")
        }
        if value < 1_000_000 {
            return "\(value / 1_000)k"
        }
        let m = Double(value) / 1_000_000
        return String(format: "%.1fM", m).replacingOccurrences(of: ".0M", with: "M")
    }

    private struct RepoDTO: Decodable {
        let stargazers_count: Int
    }
}
