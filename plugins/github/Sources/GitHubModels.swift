import Foundation
import AlwmL10n

enum GitHubError: LocalizedError, Sendable {
    case missingToken
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case badResponse(status: Int)
    case decodeFailed

    func localizedDescription(locale: String) -> String {
        switch self {
        case .missingToken:
            return PluginL10n.t("plugin.github.error.missing_token", locale: locale)
        case .unauthorized:
            return PluginL10n.t("plugin.github.error.unauthorized", locale: locale)
        case .rateLimited(let retry):
            if let retry, retry > 0 {
                return PluginL10n.tf("plugin.github.error.rate_limited_retry", locale: locale, Int(retry))
            }
            return PluginL10n.t("plugin.github.error.rate_limited", locale: locale)
        case .badResponse(let status):
            return PluginL10n.tf("plugin.github.error.bad_response", locale: locale, status)
        case .decodeFailed:
            return PluginL10n.t("plugin.github.error.decode_failed", locale: locale)
        }
    }

    var errorDescription: String? {
        localizedDescription(locale: PluginLocaleBridge.currentCode)
    }
}

struct GitHubUser: Codable, Equatable, Sendable {
    var login: String
    var name: String?
    var avatarURL: String?
    var htmlURL: String?
    var publicRepos: Int
    var followers: Int
    var following: Int

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
        case publicRepos = "public_repos"
        case followers, following
    }
}

struct GitHubNotificationItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var unread: Bool
    var reason: String
    var title: String
    var updatedAt: Date
    var repositoryFullName: String
    var subjectTitle: String
    var subjectType: String
    var subjectURL: String?
    var threadID: String?

    enum CodingKeys: String, CodingKey {
        case id, unread, reason, title, updatedAt = "updated_at", repository, subject, url
    }

    enum RepositoryKeys: String, CodingKey {
        case fullName = "full_name"
    }

    enum SubjectKeys: String, CodingKey {
        case title, type, url
    }

    init(
        id: String,
        unread: Bool,
        reason: String,
        title: String,
        updatedAt: Date,
        repositoryFullName: String,
        subjectTitle: String,
        subjectType: String,
        subjectURL: String?,
        threadID: String?
    ) {
        self.id = id
        self.unread = unread
        self.reason = reason
        self.title = title
        self.updatedAt = updatedAt
        self.repositoryFullName = repositoryFullName
        self.subjectTitle = subjectTitle
        self.subjectType = subjectType
        self.subjectURL = subjectURL
        self.threadID = threadID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        updatedAt = try Self.decodeDate(c, key: .updatedAt) ?? .distantPast
        let repo = try c.nestedContainer(keyedBy: RepositoryKeys.self, forKey: .repository)
        repositoryFullName = try repo.decodeIfPresent(String.self, forKey: .fullName) ?? "?"
        let sub = try c.nestedContainer(keyedBy: SubjectKeys.self, forKey: .subject)
        subjectTitle = try sub.decodeIfPresent(String.self, forKey: .title) ?? title
        subjectType = try sub.decodeIfPresent(String.self, forKey: .type) ?? "Unknown"
        subjectURL = try sub.decodeIfPresent(String.self, forKey: .url)
        if let threadURL = try c.decodeIfPresent(String.self, forKey: .url) {
            threadID = threadURL.split(separator: "/").last.map(String.init)
        } else {
            threadID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(unread, forKey: .unread)
        try c.encode(reason, forKey: .reason)
        try c.encode(title, forKey: .title)
        try c.encode(updatedAt, forKey: .updatedAt)
        var repo = c.nestedContainer(keyedBy: RepositoryKeys.self, forKey: .repository)
        try repo.encode(repositoryFullName, forKey: .fullName)
        var sub = c.nestedContainer(keyedBy: SubjectKeys.self, forKey: .subject)
        try sub.encode(subjectTitle, forKey: .title)
        try sub.encode(subjectType, forKey: .type)
        try sub.encodeIfPresent(subjectURL, forKey: .url)
    }

    func reasonLabel(locale: String) -> String {
        switch reason {
        case "mention": return PluginL10n.t("plugin.github.reason.mention", locale: locale)
        case "review_requested": return PluginL10n.t("plugin.github.reason.review_requested", locale: locale)
        case "assign": return PluginL10n.t("plugin.github.reason.assign", locale: locale)
        case "author": return PluginL10n.t("plugin.github.reason.author", locale: locale)
        case "comment": return PluginL10n.t("plugin.github.reason.comment", locale: locale)
        case "team_mention": return PluginL10n.t("plugin.github.reason.team_mention", locale: locale)
        case "invitation": return PluginL10n.t("plugin.github.reason.invitation", locale: locale)
        case "security_alert": return PluginL10n.t("plugin.github.reason.security_alert", locale: locale)
        case "subscribed": return PluginL10n.t("plugin.github.reason.subscribed", locale: locale)
        default: return reason.capitalized
        }
    }

    var reasonLabel: String {
        reasonLabel(locale: PluginLocaleBridge.currentCode)
    }

    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date? {
        if let s = try c.decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: s)
                ?? ISO8601DateFormatter().date(from: s.replacingOccurrences(of: "Z", with: "+00:00"))
        }
        return nil
    }
}

struct GitHubIssueItem: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var number: Int
    var title: String
    var htmlURL: String
    var repoFullName: String
    var updatedAt: Date
    var userLogin: String
    var labels: [String]

    enum CodingKeys: String, CodingKey {
        case id, number, title
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
        case updatedAt = "updated_at"
        case user, labels
    }

    enum UserKeys: String, CodingKey {
        case login
    }

    enum LabelKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
        if let repoURL = try c.decodeIfPresent(String.self, forKey: .repositoryURL),
           let url = URL(string: repoURL) {
            let parts = url.path.split(separator: "/").filter { $0 != "repos" }
            repoFullName = parts.prefix(2).joined(separator: "/")
        } else {
            repoFullName = "?"
        }
        if let s = try c.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = ISO8601DateFormatter().date(from: s) ?? .distantPast
        } else {
            updatedAt = .distantPast
        }
        if let u = try? c.nestedContainer(keyedBy: UserKeys.self, forKey: .user) {
            userLogin = try u.decodeIfPresent(String.self, forKey: .login) ?? "?"
        } else {
            userLogin = "?"
        }
        if var labelsContainer = try? c.nestedUnkeyedContainer(forKey: .labels) {
            var names: [String] = []
            while !labelsContainer.isAtEnd {
                if let label = try? labelsContainer.nestedContainer(keyedBy: LabelKeys.self),
                   let name = try label.decodeIfPresent(String.self, forKey: .name) {
                    names.append(name)
                } else {
                    _ = try? labelsContainer.decode(AnyCodable.self)
                }
            }
            labels = names
        } else {
            labels = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(htmlURL, forKey: .htmlURL)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Minimal helper to skip unknown label shapes during decode.
private struct AnyCodable: Decodable {}

struct GitHubStarredRepo: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var fullName: String
    var htmlURL: String
    var description: String?
    var stargazersCount: Int
    var language: String?
    var starredAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, fullName = "full_name"
        case htmlURL = "html_url"
        case description
        case stargazersCount = "stargazers_count"
        case language
        case starredAt = "starred_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        fullName = try c.decode(String.self, forKey: .fullName)
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        stargazersCount = try c.decodeIfPresent(Int.self, forKey: .stargazersCount) ?? 0
        language = try c.decodeIfPresent(String.self, forKey: .language)
        if let s = try c.decodeIfPresent(String.self, forKey: .starredAt) {
            starredAt = ISO8601DateFormatter().date(from: s)
        } else {
            starredAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fullName, forKey: .fullName)
        try c.encode(htmlURL, forKey: .htmlURL)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(stargazersCount, forKey: .stargazersCount)
        try c.encodeIfPresent(language, forKey: .language)
    }
}

struct GitHubDashboard: Equatable, Sendable {
    var user: GitHubUser?
    var notifications: [GitHubNotificationItem]
    var repoPullRequests: [GitHubIssueItem]
    var reviewRequests: [GitHubIssueItem]
    var assignedIssues: [GitHubIssueItem]
    var starredRepos: [GitHubStarredRepo]

    static let empty = GitHubDashboard(
        user: nil,
        notifications: [],
        repoPullRequests: [],
        reviewRequests: [],
        assignedIssues: [],
        starredRepos: []
    )

    var unreadCount: Int { notifications.filter(\.unread).count }

    var openPRCount: Int { repoPullRequests.count + reviewRequests.count }
}

enum GitHubPanelTab: Int, CaseIterable {
    case notifications = 0
    case pullRequests = 1
    case issues = 2
    case stars = 3
    case settings = 4
}

struct GitHubPluginSettings: Codable, Equatable, Sendable {
    var token: String
    var checkIntervalMinutes: Int
    var notifyOnNew: Bool
    var trackNotifications: Bool
    var trackPullRequests: Bool
    var trackReviewRequests: Bool
    var trackAssignedIssues: Bool
    var trackStars: Bool
    var knownNotificationIDs: [String]
    /// Locally dismissed PR/issue/star items (not on GitHub — panel “read” state).
    var acknowledgedPRIDs: [Int]
    var acknowledgedIssueIDs: [Int]
    var seenStarRepoIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case token, checkIntervalMinutes, notifyOnNew
        case trackNotifications, trackPullRequests, trackReviewRequests
        case trackAssignedIssues, trackStars, knownNotificationIDs
        case acknowledgedPRIDs, acknowledgedIssueIDs, seenStarRepoIDs
    }

    init(
        token: String,
        checkIntervalMinutes: Int,
        notifyOnNew: Bool,
        trackNotifications: Bool,
        trackPullRequests: Bool,
        trackReviewRequests: Bool,
        trackAssignedIssues: Bool,
        trackStars: Bool,
        knownNotificationIDs: [String],
        acknowledgedPRIDs: [Int],
        acknowledgedIssueIDs: [Int],
        seenStarRepoIDs: [Int]
    ) {
        self.token = token
        self.checkIntervalMinutes = checkIntervalMinutes
        self.notifyOnNew = notifyOnNew
        self.trackNotifications = trackNotifications
        self.trackPullRequests = trackPullRequests
        self.trackReviewRequests = trackReviewRequests
        self.trackAssignedIssues = trackAssignedIssues
        self.trackStars = trackStars
        self.knownNotificationIDs = knownNotificationIDs
        self.acknowledgedPRIDs = acknowledgedPRIDs
        self.acknowledgedIssueIDs = acknowledgedIssueIDs
        self.seenStarRepoIDs = seenStarRepoIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        checkIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .checkIntervalMinutes) ?? 15
        notifyOnNew = try c.decodeIfPresent(Bool.self, forKey: .notifyOnNew) ?? true
        trackNotifications = try c.decodeIfPresent(Bool.self, forKey: .trackNotifications) ?? true
        trackPullRequests = try c.decodeIfPresent(Bool.self, forKey: .trackPullRequests) ?? true
        trackReviewRequests = try c.decodeIfPresent(Bool.self, forKey: .trackReviewRequests) ?? true
        trackAssignedIssues = try c.decodeIfPresent(Bool.self, forKey: .trackAssignedIssues) ?? true
        trackStars = try c.decodeIfPresent(Bool.self, forKey: .trackStars) ?? true
        knownNotificationIDs = try c.decodeIfPresent([String].self, forKey: .knownNotificationIDs) ?? []
        acknowledgedPRIDs = try c.decodeIfPresent([Int].self, forKey: .acknowledgedPRIDs) ?? []
        acknowledgedIssueIDs = try c.decodeIfPresent([Int].self, forKey: .acknowledgedIssueIDs) ?? []
        seenStarRepoIDs = try c.decodeIfPresent([Int].self, forKey: .seenStarRepoIDs) ?? []
    }

    static let `default` = GitHubPluginSettings(
        token: "",
        checkIntervalMinutes: 15,
        notifyOnNew: true,
        trackNotifications: true,
        trackPullRequests: true,
        trackReviewRequests: true,
        trackAssignedIssues: true,
        trackStars: true,
        knownNotificationIDs: [],
        acknowledgedPRIDs: [],
        acknowledgedIssueIDs: [],
        seenStarRepoIDs: []
    )
}
