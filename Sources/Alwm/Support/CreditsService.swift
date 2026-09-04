import AppKit
import Foundation

/// Loads GitHub contributors and Stripe donate supporters for the About pane.
@MainActor
public final class CreditsService: ObservableObject {
    public static let shared = CreditsService()

    public struct Person: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let detail: String?
        public let avatarURL: URL?
        public let profileURL: URL?
    }

    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published public private(set) var contributors: [Person] = []
    @Published public private(set) var donors: [Person] = []
    @Published public private(set) var contributorsState: LoadState = .idle
    @Published public private(set) var donorsState: LoadState = .idle

    private var loadTask: Task<Void, Never>?
    private var avatarCache: [URL: NSImage] = [:]

    private static let contributorsURL = URL(
        string: "https://api.github.com/repos/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)/contributors?per_page=100"
    )!
    private static let remoteDonorsURL = URL(
        string: "https://raw.githubusercontent.com/\(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo)/main/Sources/Alwm/Resources/donors.json"
    )!

    private init() {}

    public func refreshIfNeeded(force: Bool = false) {
        if !force, contributorsState == .ready || contributorsState == .loading { return }
        loadTask?.cancel()
        loadTask = Task { await self.loadAll() }
    }

    public func avatarImage(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = avatarCache[url] { return cached }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = NSImage(data: data)
            else { return nil }
            avatarCache[url] = image
            return image
        } catch {
            return nil
        }
    }

    private func loadAll() async {
        contributorsState = .loading
        donorsState = .loading
        async let contrib = fetchContributors()
        async let donor = fetchDonors()
        let (c, d) = await (contrib, donor)
        guard !Task.isCancelled else { return }
        switch c {
        case .success(let people):
            contributors = people
            contributorsState = .ready
        case .failure(let error):
            if contributors.isEmpty {
                contributorsState = .failed(error.localizedDescription)
            } else {
                contributorsState = .ready
            }
        }
        switch d {
        case .success(let people):
            donors = people
            donorsState = .ready
        case .failure(let error):
            if donors.isEmpty {
                donorsState = .failed(error.localizedDescription)
            } else {
                donorsState = .ready
            }
        }
    }

    private func fetchContributors() async -> Result<[Person], Error> {
        do {
            var request = URLRequest(url: Self.contributorsURL)
            request.setValue("ALWM/\(AlwmVersion.installed)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode([GitHubContributor].self, from: data)
            let people = decoded
                .filter { $0.type != "Bot" && !($0.login?.hasSuffix("[bot]") ?? false) }
                .compactMap { item -> Person? in
                    guard let login = item.login, !login.isEmpty else { return nil }
                    return Person(
                        id: "gh:\(login)",
                        name: login,
                        detail: item.contributions.map { "\($0)" },
                        avatarURL: item.avatar_url.flatMap(URL.init(string:)),
                        profileURL: item.html_url.flatMap(URL.init(string:))
                            ?? URL(string: "https://github.com/\(login)")
                    )
                }
            return .success(people)
        } catch {
            return .failure(error)
        }
    }

    private func fetchDonors() async -> Result<[Person], Error> {
        if let remote = await loadDonors(from: Self.remoteDonorsURL) {
            return .success(remote)
        }
        if let bundled = loadBundledDonors() {
            return .success(bundled)
        }
        return .success([])
    }

    private func loadDonors(from url: URL) async -> [Person]? {
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("ALWM/\(AlwmVersion.installed)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseDonors(data)
        } catch {
            return nil
        }
    }

    private func loadBundledDonors() -> [Person]? {
        guard let url = AlwmResources.url(forResource: "donors", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return parseDonors(data)
    }

    private func parseDonors(_ data: Data) -> [Person]? {
        guard let decoded = try? JSONDecoder().decode(DonorsFile.self, from: data) else { return nil }
        return decoded.donors.map { entry in
            Person(
                id: entry.id ?? "donor:\(entry.name)",
                name: entry.name,
                detail: entry.note,
                avatarURL: entry.avatarURL.flatMap(URL.init(string:)),
                profileURL: entry.url.flatMap(URL.init(string:))
            )
        }
    }
}

private struct GitHubContributor: Decodable {
    let login: String?
    let avatar_url: String?
    let html_url: String?
    let contributions: Int?
    let type: String?
}

private struct DonorsFile: Decodable {
    let donors: [DonorEntry]
}

private struct DonorEntry: Decodable {
    let id: String?
    let name: String
    let note: String?
    let avatarURL: String?
    let url: String?
}
