import AppKit
import SwiftUI
import AlwmL10n

@MainActor
enum GitHubPanelController {
    private static var window: NSWindow?

    static func close() {
        window?.orderOut(nil)
    }

    static func toggle(relativeTo view: NSView?) {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        open(relativeTo: view)
    }

    static func open(relativeTo view: NSView?) {
        let store = GitHubWatcherStore.shared
        let root = GitHubPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let win = window ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.title = PluginL10n.t("plugin.github.title", locale: store.localeCode())
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 440, height: 480)

        if let view, let screen = view.window?.screen ?? NSScreen.main {
            let rect = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
                ?? NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 1)
            var origin = NSPoint(x: rect.midX - 260, y: rect.minY - 660)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - 530)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 12), screen.visibleFrame.maxY - 500)
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct GitHubPanelView: View {
    @ObservedObject private var store = GitHubWatcherStore.shared
    @State private var tokenDraft = ""
    @State private var selectedTab = 0

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.hasToken {
                tokenSetup
            } else {
                tabBar
                Divider()
                Group {
                    switch selectedTab {
                    case 0: notificationsTab
                    case 1: pullRequestsTab
                    case 2: issuesTab
                    case 3: starsTab
                    default: settingsTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 440, minHeight: 480)
        .onAppear {
            tokenDraft = store.settings.token
        }
    }

    private var tabs: [(id: Int, title: String, icon: String)] {
        [
            (0, t("plugin.github.tab.notifications"), "bell.fill"),
            (1, t("plugin.github.tab.prs"), "arrow.triangle.pull"),
            (2, t("plugin.github.tab.issues"), "exclamationmark.circle"),
            (3, t("plugin.github.tab.stars"), "star.fill"),
            (4, t("plugin.github.tab.settings"), "gearshape")
        ]
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.id) { tab in
                    tabChip(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func tabChip(_ tab: (id: Int, title: String, icon: String)) -> some View {
        let count = store.tabUnreadCount(GitHubPanelTab(rawValue: tab.id) ?? .settings)
        return Button {
            selectedTab = tab.id
        } label: {
            HStack(spacing: 5) {
                Label(tab.title, systemImage: tab.icon)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Color.red))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(selectedTab == tab.id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .foregroundStyle(selectedTab == tab.id ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab.id ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(t("plugin.github.title"))
                    .font(.headline)
                if let user = store.dashboard.user {
                    Text("@\(user.login)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            if store.hasToken {
                summaryBadges
            }
            Button {
                store.scheduleRefresh(notify: false)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(t("plugin.common.refresh"))
            .disabled(store.isRefreshing || !store.hasToken)
        }
        .padding(14)
    }

    private var summaryBadges: some View {
        HStack(spacing: 8) {
            if store.tabUnreadCount(.notifications) > 0 {
                badge("\(store.tabUnreadCount(.notifications))", color: .red, label: t("plugin.github.badge.unread"))
            }
            if store.tabUnreadCount(.pullRequests) > 0 {
                badge("\(store.tabUnreadCount(.pullRequests))", color: .purple, label: t("plugin.github.badge.prs"))
            }
            if store.tabUnreadCount(.issues) > 0 {
                badge("\(store.tabUnreadCount(.issues))", color: .orange, label: t("plugin.github.tab.issues"))
            }
        }
    }

    private func badge(_ count: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Text(count)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var tokenSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("plugin.github.token.title"))
                .font(.subheadline.weight(.semibold))
            Text(t("plugin.github.token.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(t("plugin.github.token.placeholder"), text: $tokenDraft)
                .textFieldStyle(.roundedBorder)
            Button(t("plugin.github.token.save_connect")) {
                store.setToken(tokenDraft)
            }
            .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(16)
    }

    private var notificationsTab: some View {
        listTab(empty: t("plugin.github.notifications.empty"), showMarkAll: !store.dashboard.notifications.isEmpty) {
            ForEach(store.dashboard.notifications) { item in
                notificationRow(item)
            }
        }
    }

    private func notificationRow(_ item: GitHubNotificationItem) -> some View {
        listCard(highlighted: item.unread) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if item.unread {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    }
                    Text(item.reasonLabel(locale: loc))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.unread ? .primary : .secondary)
                    Spacer()
                    Text(item.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.subjectTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.repositoryFullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if let url = item.subjectURL, let link = URL(string: url) {
                        Button(t("plugin.common.open")) { NSWorkspace.shared.open(link) }
                            .font(.caption)
                    }
                    if item.unread, item.threadID != nil {
                        Button(t("plugin.github.notifications.mark_read")) {
                            Task { @MainActor in await store.markRead(item) }
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var pullRequestsTab: some View {
        let hasItems = !store.dashboard.reviewRequests.isEmpty || !store.dashboard.repoPullRequests.isEmpty
        return listTab(empty: t("plugin.github.prs.empty"), showMarkAll: hasItems) {
            if !store.dashboard.reviewRequests.isEmpty {
                sectionHeader(t("plugin.github.prs.pending_reviews"))
                ForEach(store.dashboard.reviewRequests) {
                    issueRow($0, prefix: t("plugin.github.highlight.review"), isUnread: store.isPRUnread($0))
                }
            }
            if !store.dashboard.repoPullRequests.isEmpty {
                sectionHeader(t("plugin.github.prs.in_your_repos"))
                ForEach(store.dashboard.repoPullRequests) {
                    issueRow($0, prefix: t("plugin.github.highlight.pr"), isUnread: store.isPRUnread($0))
                }
            }
        }
    }

    private var issuesTab: some View {
        listTab(empty: t("plugin.github.issues.empty"), showMarkAll: !store.dashboard.assignedIssues.isEmpty) {
            ForEach(store.dashboard.assignedIssues) {
                issueRow($0, prefix: t("plugin.github.highlight.issue"), isUnread: store.isIssueUnread($0))
            }
        }
    }

    private var starsTab: some View {
        listTab(empty: t("plugin.github.stars.empty"), showMarkAll: !store.dashboard.starredRepos.isEmpty) {
            ForEach(store.dashboard.starredRepos) { repo in
                starRow(repo, isUnread: store.isStarUnread(repo))
            }
        }
    }

    private func starRow(_ repo: GitHubStarredRepo, isUnread: Bool) -> some View {
        listCard(highlighted: isUnread) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if isUnread {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    }
                    Text(repo.fullName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("★ \(repo.stargazersCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let desc = repo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if let lang = repo.language {
                        Text(lang)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    Button(t("plugin.common.open")) {
                        if let url = URL(string: repo.htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    if isUnread {
                        Button(t("plugin.github.notifications.mark_read")) {
                            store.markSeen(star: repo)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(t("plugin.github.token.title"))
                    .font(.subheadline.weight(.semibold))
                SecureField(t("plugin.github.token.placeholder"), text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                Button(t("plugin.github.token.update")) { store.setToken(tokenDraft) }
                    .disabled(tokenDraft == store.settings.token)

                Divider()

                Text(t("plugin.common.interval_minutes"))
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(store.settings.checkIntervalMinutes) },
                            set: { store.setInterval(Int($0.rounded())) }
                        ),
                        in: 5...120,
                        step: 5
                    )
                    Text("\(store.settings.checkIntervalMinutes)")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                Toggle(t("plugin.github.settings.notify"), isOn: Binding(
                    get: { store.settings.notifyOnNew },
                    set: { store.setNotifyOnNew($0) }
                ))

                Text(t("plugin.github.settings.monitor"))
                    .font(.subheadline.weight(.semibold))
                Toggle(t("plugin.github.settings.track.notifications"), isOn: Binding(
                    get: { store.settings.trackNotifications },
                    set: { store.setTracking(notifications: $0) }
                ))
                Toggle(t("plugin.github.settings.track.prs"), isOn: Binding(
                    get: { store.settings.trackPullRequests },
                    set: { store.setTracking(pullRequests: $0) }
                ))
                Toggle(t("plugin.github.settings.track.reviews"), isOn: Binding(
                    get: { store.settings.trackReviewRequests },
                    set: { store.setTracking(reviews: $0) }
                ))
                Toggle(t("plugin.github.settings.track.issues"), isOn: Binding(
                    get: { store.settings.trackAssignedIssues },
                    set: { store.setTracking(issues: $0) }
                ))
                Toggle(t("plugin.github.settings.track.stars"), isOn: Binding(
                    get: { store.settings.trackStars },
                    set: { store.setTracking(stars: $0) }
                ))

                if let err = store.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let at = store.lastRefreshAt {
                    Text(PluginL10n.tf("plugin.common.last_refresh", locale: loc, at.formatted(date: .omitted, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    private func issueRow(_ item: GitHubIssueItem, prefix: String, isUnread: Bool) -> some View {
        listCard(highlighted: isUnread) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    if isUnread {
                        Circle().fill(.red).frame(width: 8, height: 8)
                            .padding(.top, 4)
                    }
                    Text("\(prefix) #\(item.number) · \(item.title)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(item.repoFullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.labels.isEmpty {
                    Text(item.labels.prefix(3).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Button(t("plugin.github.open_github")) {
                        if let url = URL(string: item.htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    if isUnread {
                        Button(t("plugin.github.notifications.mark_read")) {
                            if store.dashboard.reviewRequests.contains(where: { $0.id == item.id })
                                || store.dashboard.repoPullRequests.contains(where: { $0.id == item.id }) {
                                store.markRead(pr: item)
                            } else {
                                store.markRead(issue: item)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    /// Shared card chrome — full-width column so PR/Issue rows align like Notifications/Stars.
    private func listCard<Content: View>(highlighted: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlighted ? Color.red.opacity(0.06) : Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func listTab<Content: View>(
        empty: String,
        showMarkAll: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            if isEmptyCurrentTab {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showMarkAll, let tab = GitHubPanelTab(rawValue: selectedTab) {
                        markAllBar(for: tab)
                    }
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
        }
    }

    private func markAllBar(for tab: GitHubPanelTab) -> some View {
        HStack {
            Spacer()
            Button(t("plugin.github.notifications.mark_all")) {
                Task { @MainActor in await store.markAllRead(for: tab) }
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    private var isEmptyCurrentTab: Bool {
        switch selectedTab {
        case 0: return store.dashboard.notifications.isEmpty
        case 1: return store.dashboard.repoPullRequests.isEmpty && store.dashboard.reviewRequests.isEmpty
        case 2: return store.dashboard.assignedIssues.isEmpty
        case 3: return store.dashboard.starredRepos.isEmpty
        default: return false
        }
    }
}
