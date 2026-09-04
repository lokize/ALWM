import Foundation

enum GitHubAPI {
    private static let base = URL(string: "https://api.github.com")!
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Models use explicit CodingKeys — do not convertFromSnakeCase (breaks nested decode).
        return d
    }()

    static func fetchDashboard(token: String, settings: GitHubPluginSettings) async throws -> GitHubDashboard {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.missingToken }

        let user = try await fetchUser(token: trimmed)
        async let notifications = settings.trackNotifications
            ? fetchNotifications(token: trimmed)
            : []
        async let repoPRs = settings.trackPullRequests
            ? searchIssues(token: trimmed, query: "is:open+is:pr+user:\(user.login)+archived:false")
            : []
        async let reviews = settings.trackReviewRequests
            ? searchIssues(token: trimmed, query: "is:open+is:pr+review-requested:\(user.login)")
            : []
        async let issues = settings.trackAssignedIssues
            ? searchIssues(token: trimmed, query: "is:open+is:issue+assignee:\(user.login)")
            : []
        async let stars = settings.trackStars
            ? fetchStarred(token: trimmed)
            : []

        return try await GitHubDashboard(
            user: user,
            notifications: notifications,
            repoPullRequests: repoPRs,
            reviewRequests: reviews,
            assignedIssues: issues,
            starredRepos: stars
        )
    }

    static func fetchUser(token: String) async throws -> GitHubUser {
        let data = try await request(path: "/user", token: token)
        guard let user = try? decoder.decode(GitHubUser.self, from: data) else {
            throw GitHubError.decodeFailed
        }
        return user
    }

    static func fetchNotifications(token: String) async throws -> [GitHubNotificationItem] {
        let data = try await request(
            path: "/notifications",
            token: token,
            query: [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "per_page", value: "50")]
        )
        guard let list = try? decoder.decode([GitHubNotificationItem].self, from: data) else {
            throw GitHubError.decodeFailed
        }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func markNotificationRead(token: String, threadID: String) async throws {
        _ = try await request(
            path: "/notifications/threads/\(threadID)",
            token: token,
            method: "PATCH",
            body: ["read": true]
        )
    }

    static func markAllNotificationsRead(token: String) async throws {
        _ = try await request(path: "/notifications", token: token, method: "PUT", body: ["read": true])
    }

    static func fetchStarred(token: String) async throws -> [GitHubStarredRepo] {
        let data = try await request(
            path: "/user/starred",
            token: token,
            query: [
                URLQueryItem(name: "per_page", value: "15"),
                URLQueryItem(name: "sort", value: "updated")
            ]
        )
        guard let list = try? decoder.decode([GitHubStarredRepo].self, from: data) else {
            throw GitHubError.decodeFailed
        }
        return list
    }

    private static func searchIssues(token: String, query: String) async throws -> [GitHubIssueItem] {
        let data = try await request(
            path: "/search/issues",
            token: token,
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: "20")
            ]
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else {
            throw GitHubError.decodeFailed
        }
        let itemData = try JSONSerialization.data(withJSONObject: items)
        guard let decoded = try? decoder.decode([GitHubIssueItem].self, from: itemData) else {
            throw GitHubError.decodeFailed
        }
        return decoded
    }

    private static func request(
        path: String,
        token: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        guard let url = apiURL(path: path, query: query) else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("ALWM-GitHub-Plugin/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw GitHubError.unauthorized
        case 403:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw GitHubError.rateLimited(retryAfter: retry)
        default:
            throw GitHubError.badResponse(status: http.statusCode)
        }
    }

    private static func apiURL(path: String, query: [URLQueryItem]) -> URL? {
        var url = base
        for part in path.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
        }
        guard query.isEmpty else {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            return components?.url
        }
        return url
    }
}
