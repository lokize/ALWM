import AppKit
import Foundation

/// Public star count for `lokize/ALWM`, plus starring when a GitHub token is available
/// (plugin settings or `gh` CLI).
///
/// Uses the **unauthenticated** public quota for star counts so it does not compete with
/// the GitHub plugin token. Refreshes are throttled; 403/429 honor Retry-After.
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
    private var lastSuccessfulLoad: Date?
    private var lastStarredCheck: Date?
    private var rateLimitedUntil: Date?

    private static let defaultsPrefix = "alwm.githubProject."
    private static let starredMinInterval: TimeInterval = 24 * 60 * 60

    private init() {
        restoreCache()
    }

    public var formattedStarCount: String {
        guard let starCount else { return "—" }
        return Self.formatCount(starCount)
    }

    public func refreshIfNeeded(force: Bool = false) {
        if !force, phase == .loading || phase == .starring { return }
        if !force, let until = rateLimitedUntil, until > Date() { return }
        if !force,
           phase == .ready,
           starCount != nil,
           let last = lastSuccessfulLoad,
           Date().timeIntervalSince(last) < GitHubAPIRateLimit.starsMinInterval {
            return
        }
        loadTask?.cancel()
        loadTask = Task { await self.load(force: force) }
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

    private func load(force: Bool) async {
        phase = .loading
        let token = await Self.resolveToken()
        hasAuthToken = token != nil
        do {
            let count = try await Self.fetchStarCount()
            var starred = isStarred
            let shouldCheckStarred = force
                || lastStarredCheck == nil
                || Date().timeIntervalSince(lastStarredCheck ?? .distantPast) >= Self.starredMinInterval
            if shouldCheckStarred, let token {
                starred = try await Self.fetchIsStarred(token: token)
                lastStarredCheck = Date()
            }
            guard !Task.isCancelled else { return }
            starCount = count
            isStarred = starred
            lastSuccessfulLoad = Date()
            rateLimitedUntil = nil
            persistCache()
            phase = .ready
        } catch let error as StarAPIError where error.isRateLimited {
            guard !Task.isCancelled else { return }
            rateLimitedUntil = error.retryUntil ?? Date().addingTimeInterval(15 * 60)
            phase = starCount != nil ? .ready : .idle
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
            // Confirm current state with auth only when the user acts.
            if try await Self.fetchIsStarred(token: token) {
                isStarred = true
                lastStarredCheck = Date()
                persistCache()
                phase = .ready
                openRepository()
                return
            }
            try await Self.putStar(token: token)
            guard !Task.isCancelled else { return }
            isStarred = true
            lastStarredCheck = Date()
            if let current = starCount {
                starCount = current + 1
            } else {
                starCount = try? await Self.fetchStarCount()
            }
            lastSuccessfulLoad = Date()
            persistCache()
            phase = .ready
        } catch let error as StarAPIError where error.isRateLimited {
            guard !Task.isCancelled else { return }
            rateLimitedUntil = error.retryUntil ?? Date().addingTimeInterval(15 * 60)
            phase = starCount != nil ? .ready : .failed(error.localizedDescription)
            openRepository()
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
            openRepository()
        }
    }

    // MARK: - Cache

    private func restoreCache() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.defaultsPrefix + "starCount") != nil {
            starCount = d.integer(forKey: Self.defaultsPrefix + "starCount")
        }
        isStarred = d.bool(forKey: Self.defaultsPrefix + "isStarred")
        if let ts = d.object(forKey: Self.defaultsPrefix + "loadedAt") as? Date {
            lastSuccessfulLoad = ts
        }
        if let ts = d.object(forKey: Self.defaultsPrefix + "starredAt") as? Date {
            lastStarredCheck = ts
        }
        if starCount != nil {
            phase = .ready
        }
    }

    private func persistCache() {
        let d = UserDefaults.standard
        if let starCount {
            d.set(starCount, forKey: Self.defaultsPrefix + "starCount")
        }
        d.set(isStarred, forKey: Self.defaultsPrefix + "isStarred")
        d.set(lastSuccessfulLoad ?? Date(), forKey: Self.defaultsPrefix + "loadedAt")
        if let lastStarredCheck {
            d.set(lastStarredCheck, forKey: Self.defaultsPrefix + "starredAt")
        }
    }

    // MARK: - Networking

    private enum StarAPIError: LocalizedError {
        case rateLimited(until: Date?)
        case badResponse

        var isRateLimited: Bool {
            if case .rateLimited = self { return true }
            return false
        }

        var retryUntil: Date? {
            if case .rateLimited(let until) = self { return until }
            return nil
        }

        var errorDescription: String? {
            switch self {
            case .rateLimited: return "GitHub API rate limit"
            case .badResponse: return "GitHub request failed"
            }
        }
    }

    private static func fetchStarCount() async throws -> Int {
        let url = URL(
            string: "https://api.github.com/repos/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)"
        )!
        var request = URLRequest(url: url)
        request.setValue("ALWM/\(AlwmVersion.installed)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Public — no Authorization (keeps plugin token quota free).
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StarAPIError.badResponse
        }
        if GitHubAPIRateLimit.isRateLimited(http) {
            throw StarAPIError.rateLimited(until: GitHubAPIRateLimit.retryAfter(from: http))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StarAPIError.badResponse
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
            throw StarAPIError.badResponse
        }
        if GitHubAPIRateLimit.isRateLimited(http) {
            throw StarAPIError.rateLimited(until: GitHubAPIRateLimit.retryAfter(from: http))
        }
        if http.statusCode == 204 { return true }
        if http.statusCode == 404 { return false }
        throw StarAPIError.badResponse
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
        guard let http = response as? HTTPURLResponse else {
            throw StarAPIError.badResponse
        }
        if GitHubAPIRateLimit.isRateLimited(http) {
            throw StarAPIError.rateLimited(until: GitHubAPIRateLimit.retryAfter(from: http))
        }
        guard http.statusCode == 204 || http.statusCode == 304 else {
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
