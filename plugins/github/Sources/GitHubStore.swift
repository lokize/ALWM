import Combine
import Foundation
import UserNotifications
import AlwmL10n

final class GitHubWatcherStore: ObservableObject, @unchecked Sendable {
    static let shared = GitHubWatcherStore()

    @Published private(set) var settings: GitHubPluginSettings = .default
    @Published private(set) var dashboard: GitHubDashboard = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshAt: Date?

    private let url: URL
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    var localeCode: () -> String = { PluginL10n.currentCode }

    private func loc() -> String { PluginL10n.resolveCode(localeCode()) }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc()) }

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("dev.alwm.github.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GitHubPluginSettings.self, from: data)
        else {
            settings = .default
            return
        }
        settings = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
        emitChange()
    }

    func setToken(_ token: String) {
        settings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        save()
        restartTimer()
        scheduleRefresh(notify: false)
    }

    func setInterval(_ minutes: Int) {
        settings.checkIntervalMinutes = min(120, max(5, minutes))
        save()
        restartTimer()
    }

    func setNotifyOnNew(_ enabled: Bool) {
        settings.notifyOnNew = enabled
        save()
    }

    func setTracking(notifications: Bool? = nil, pullRequests: Bool? = nil, reviews: Bool? = nil, issues: Bool? = nil, stars: Bool? = nil) {
        if let notifications { settings.trackNotifications = notifications }
        if let pullRequests { settings.trackPullRequests = pullRequests }
        if let reviews { settings.trackReviewRequests = reviews }
        if let issues { settings.trackAssignedIssues = issues }
        if let stars { settings.trackStars = stars }
        save()
        scheduleRefresh(notify: false)
    }

    func startMonitoring() {
        GitHubNotifier.requestAuthorization()
        restartTimer()
        scheduleRefresh(notify: true)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    var hasToken: Bool {
        !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var barTooltip: String {
        if !hasToken { return t("plugin.github.tooltip.configure_token") }
        if isRefreshing { return t("plugin.github.tooltip.refreshing") }
        var lines: [String] = []
        if let user = dashboard.user {
            lines.append(user.name ?? user.login)
        }
        let unread = dashboard.unreadCount
        if unread > 0 { lines.append(PluginL10n.tf("plugin.github.tooltip.unread", locale: loc(), unread)) }
        if !dashboard.repoPullRequests.isEmpty {
            lines.append(PluginL10n.tf("plugin.github.tooltip.prs", locale: loc(), dashboard.repoPullRequests.count))
        }
        if !dashboard.reviewRequests.isEmpty {
            lines.append(PluginL10n.tf("plugin.github.tooltip.reviews", locale: loc(), dashboard.reviewRequests.count))
        }
        if !dashboard.assignedIssues.isEmpty {
            lines.append(PluginL10n.tf("plugin.github.tooltip.issues", locale: loc(), dashboard.assignedIssues.count))
        }
        if lines.isEmpty { lines.append(t("plugin.github.tooltip.all_clear")) }
        lines.append(t("plugin.common.click_to_open"))
        return lines.joined(separator: "\n")
    }

    var highlightItems: [GitHubBarHighlight] {
        let locale = loc()
        var out: [GitHubBarHighlight] = []

        // One highlight per content tab — latest item from each category.
        if let n = dashboard.notifications.filter(\.unread).max(by: { $0.updatedAt < $1.updatedAt }) {
            out.append(.notification(n))
        }

        let prCandidates: [(GitHubIssueItem, String)] =
            dashboard.reviewRequests.map {
                ($0, PluginL10n.t("plugin.github.highlight.review", locale: locale))
            } + dashboard.repoPullRequests.map {
                ($0, PluginL10n.t("plugin.github.highlight.pr", locale: locale))
            }
        if let latest = prCandidates.max(by: { $0.0.updatedAt < $1.0.updatedAt }) {
            out.append(.pullRequest(latest.0, kind: latest.1))
        }

        if let issue = dashboard.assignedIssues.max(by: { $0.updatedAt < $1.updatedAt }) {
            out.append(.issue(issue))
        }

        if let star = dashboard.starredRepos.first {
            out.append(.star(star))
        }

        if out.isEmpty, let user = dashboard.user {
            out.append(.profile(user, stars: dashboard.starredRepos.count))
        }
        return out
    }

    var totalUnreadBadge: Int {
        tabUnreadCount(.notifications) + tabUnreadCount(.pullRequests)
            + tabUnreadCount(.issues) + tabUnreadCount(.stars)
    }

    func tabUnreadCount(_ tab: GitHubPanelTab) -> Int {
        switch tab {
        case .notifications:
            return dashboard.unreadCount
        case .pullRequests:
            let ack = Set(settings.acknowledgedPRIDs)
            return (dashboard.reviewRequests + dashboard.repoPullRequests).filter { !ack.contains($0.id) }.count
        case .issues:
            let ack = Set(settings.acknowledgedIssueIDs)
            return dashboard.assignedIssues.filter { !ack.contains($0.id) }.count
        case .stars:
            let seen = Set(settings.seenStarRepoIDs)
            return dashboard.starredRepos.filter { !seen.contains($0.id) }.count
        case .settings:
            return 0
        }
    }

    func isPRUnread(_ item: GitHubIssueItem) -> Bool {
        !Set(settings.acknowledgedPRIDs).contains(item.id)
    }

    func isIssueUnread(_ item: GitHubIssueItem) -> Bool {
        !Set(settings.acknowledgedIssueIDs).contains(item.id)
    }

    func isStarUnread(_ repo: GitHubStarredRepo) -> Bool {
        !Set(settings.seenStarRepoIDs).contains(repo.id)
    }

    @MainActor
    func markAllRead(for tab: GitHubPanelTab) async {
        switch tab {
        case .notifications:
            await markAllRead()
        case .pullRequests:
            var ids = Set(settings.acknowledgedPRIDs)
            ids.formUnion(dashboard.reviewRequests.map(\.id))
            ids.formUnion(dashboard.repoPullRequests.map(\.id))
            settings.acknowledgedPRIDs = Array(ids).sorted()
            save()
            emitChange()
        case .issues:
            var ids = Set(settings.acknowledgedIssueIDs)
            ids.formUnion(dashboard.assignedIssues.map(\.id))
            settings.acknowledgedIssueIDs = Array(ids).sorted()
            save()
            emitChange()
        case .stars:
            var ids = Set(settings.seenStarRepoIDs)
            ids.formUnion(dashboard.starredRepos.map(\.id))
            settings.seenStarRepoIDs = Array(ids).sorted()
            save()
            emitChange()
        case .settings:
            break
        }
    }

    @MainActor
    func markRead(pr item: GitHubIssueItem) {
        var ids = Set(settings.acknowledgedPRIDs)
        ids.insert(item.id)
        settings.acknowledgedPRIDs = Array(ids).sorted()
        save()
        emitChange()
    }

    @MainActor
    func markRead(issue item: GitHubIssueItem) {
        var ids = Set(settings.acknowledgedIssueIDs)
        ids.insert(item.id)
        settings.acknowledgedIssueIDs = Array(ids).sorted()
        save()
        emitChange()
    }

    @MainActor
    func markSeen(star repo: GitHubStarredRepo) {
        var ids = Set(settings.seenStarRepoIDs)
        ids.insert(repo.id)
        settings.seenStarRepoIDs = Array(ids).sorted()
        save()
        emitChange()
    }

    func scheduleRefresh(notify: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.refresh(notify: notify)
        }
    }

    @MainActor
    func refresh(notify: Bool) async {
        guard hasToken else {
            dashboard = .empty
            lastError = nil
            emitChange()
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        emitChange()

        let token = settings.token
        let snapshot = settings
        do {
            let next = try await GitHubAPI.fetchDashboard(token: token, settings: snapshot)
            guard !Task.isCancelled else {
                isRefreshing = false
                emitChange()
                return
            }
            if notify, snapshot.notifyOnNew {
                notifyNewItems(in: next)
            }
            dashboard = next
            settings.knownNotificationIDs = next.notifications.map(\.id)
            save()
        } catch is CancellationError {
            // ignored
        } catch {
            if !Task.isCancelled {
                setError(from: error)
            }
        }
        isRefreshing = false
        lastRefreshAt = Date()
        emitChange()
    }

    @MainActor
    func markRead(_ item: GitHubNotificationItem) async {
        guard let threadID = item.threadID else { return }
        do {
            try await GitHubAPI.markNotificationRead(token: settings.token, threadID: threadID)
            await refresh(notify: false)
        } catch {
            setError(from: error)
        }
    }

    @MainActor
    func markAllRead() async {
        do {
            try await GitHubAPI.markAllNotificationsRead(token: settings.token)
            await refresh(notify: false)
        } catch {
            setError(from: error)
        }
    }

    @MainActor
    private func setError(from error: Error) {
        if let gh = error as? GitHubError {
            lastError = gh.localizedDescription(locale: loc())
        } else {
            lastError = error.localizedDescription
        }
    }

    private func notifyNewItems(in dashboard: GitHubDashboard) {
        let known = Set(settings.knownNotificationIDs)
        guard !known.isEmpty else { return }
        for item in dashboard.notifications where item.unread && !known.contains(item.id) {
            GitHubNotifier.notify(item: item, locale: loc())
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard hasToken else { return }
        let interval = TimeInterval(settings.checkIntervalMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.scheduleRefresh(notify: true)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func emitChange() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }
    }
}

enum GitHubBarHighlight: Equatable {
    case notification(GitHubNotificationItem)
    case pullRequest(GitHubIssueItem, kind: String)
    case issue(GitHubIssueItem)
    case star(GitHubStarredRepo)
    case profile(GitHubUser, stars: Int)

    func title(locale: String) -> String {
        switch self {
        case .notification(let n):
            return n.subjectTitle
        case .pullRequest(let pr, let kind):
            return "\(kind) #\(pr.number)"
        case .issue(let issue):
            return "\(PluginL10n.t("plugin.github.highlight.issue", locale: locale)) #\(issue.number)"
        case .star(let repo):
            return repo.fullName
        case .profile(let user, _):
            return user.login
        }
    }

    func subtitle(locale: String) -> String {
        switch self {
        case .notification(let n):
            return "\(n.repositoryFullName) · \(n.reasonLabel(locale: locale))"
        case .pullRequest(let pr, _):
            return pr.repoFullName
        case .issue(let issue):
            return issue.repoFullName
        case .star(let repo):
            if let lang = repo.language, !lang.isEmpty { return lang }
            return "★ \(repo.stargazersCount)"
        case .profile(_, let stars):
            return PluginL10n.tf("plugin.github.highlight.recent_stars", locale: locale, stars)
        }
    }

    var title: String { title(locale: PluginLocaleBridge.currentCode) }
    var subtitle: String { subtitle(locale: PluginLocaleBridge.currentCode) }
}

enum GitHubNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(item: GitHubNotificationItem, locale: String) {
        let content = UNMutableNotificationContent()
        content.title = PluginL10n.tf("plugin.github.notify.title", locale: locale, item.reasonLabel(locale: locale))
        content.subtitle = item.repositoryFullName
        content.body = item.subjectTitle
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "github-\(item.id)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
