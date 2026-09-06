import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n

public final class GitHubPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.github"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = GitHubWatcherStore.shared
        store.localeCode = { [weak self] in
            if let id = self?.context?.localeIdentifier, !id.isEmpty {
                return PluginL10n.resolveCode(id)
            }
            return PluginL10n.currentCode
        }
        store.onChange = { [weak self] in
            self?.context?.requestBarRefresh()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .alwmLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.context?.requestBarRefresh()
        }
        store.startMonitoring()
    }

    public func unload() {
        let store = GitHubWatcherStore.shared
        store.stopMonitoring()
        store.onChange = nil
        store.localeCode = { PluginL10n.currentCode }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        Task { @MainActor in
            GitHubPanelController.close()
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = GitHubWatcherStore.shared
        let scale = context?.barScale ?? 1
        let locale = store.localeCode()
        return GitHubBarChipView(
            unread: store.totalUnreadBadge,
            highlights: store.highlightItems,
            hasToken: store.hasToken,
            isRefreshing: store.isRefreshing,
            scale: scale,
            locale: locale,
            tooltip: store.barTooltip
        )
    }

    public func barSignature() -> String {
        let store = GitHubWatcherStore.shared
        let d = store.dashboard
        return "github:\(PluginL10n.currentCode):\(store.hasToken):\(d.unreadCount):\(d.repoPullRequests.count):\(d.reviewRequests.count):\(d.assignedIssues.count):\(store.isRefreshing):\(store.highlightItems.count)"
    }
}

// MARK: - Bar chip

private final class GitHubBarChipView: NSView {
    private let unread: Int
    private let highlights: [GitHubBarHighlight]
    private let hasToken: Bool
    private let isRefreshing: Bool
    private let scale: CGFloat
    private let locale: String

    private let row = NSStackView()
    private let iconView = NSImageView()
    private let badgeField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    private var index = 0
    nonisolated(unsafe) private var cycleTimer: Timer?
    private var tracking: NSTrackingArea?

    init(
        unread: Int,
        highlights: [GitHubBarHighlight],
        hasToken: Bool,
        isRefreshing: Bool,
        scale: CGFloat,
        locale: String,
        tooltip: String
    ) {
        self.unread = unread
        self.highlights = highlights
        self.hasToken = hasToken
        self.isRefreshing = isRefreshing
        self.scale = scale
        self.locale = locale
        super.init(frame: .zero)
        toolTip = tooltip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        build()
        render(animated: false)
        if highlights.count > 1 {
            startCycle()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        cycleTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, highlights.count > 1 {
            startCycle()
        } else {
            stopCycle()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard highlights.count > 1 else { return }
        startCycle()
    }

    override func mouseExited(with event: NSEvent) {
        // Keep auto-rotation — only snap back to the first highlight when hover ends.
        if highlights.count > 1, index != 0 {
            index = 0
            render(animated: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        GitHubPanelController.toggle(relativeTo: self)
    }

    private func build() {
        let fontSize = max(9, 10 * scale)
        let padX = max(4, 5 * scale)
        let chipW = PluginBarChipLayout.chipWidth(scale: scale)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = max(3, 3.5 * scale)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)

        let symbol = NSImage(
            systemSymbolName: isRefreshing ? "arrow.triangle.2.circlepath" : "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: PluginL10n.t("plugin.github.title", locale: locale)
        )
        let iconConfig = NSImage.SymbolConfiguration(pointSize: PluginBarChipLayout.iconSide(scale: scale), weight: .semibold)
        iconView.image = symbol?.withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = hasToken ? .labelColor : .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconSide = PluginBarChipLayout.iconSide(scale: scale)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: iconSide),
            iconView.heightAnchor.constraint(equalToConstant: iconSide)
        ])

        let badgeW = PluginBarChipLayout.badgeWidth(scale: scale)
        badgeField.font = .monospacedDigitSystemFont(ofSize: max(8, fontSize - 1), weight: .bold)
        badgeField.textColor = .white
        badgeField.isEditable = false
        badgeField.isBezeled = false
        badgeField.drawsBackground = true
        badgeField.backgroundColor = .systemRed
        badgeField.wantsLayer = true
        badgeField.layer?.cornerRadius = max(5, 5.5 * scale)
        badgeField.layer?.cornerCurve = .continuous
        badgeField.alignment = .center
        badgeField.widthAnchor.constraint(equalToConstant: badgeW).isActive = true

        let titleW = PluginBarChipLayout.titleWidth(scale: scale)
        titleField.font = .systemFont(ofSize: fontSize, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.isEditable = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.widthAnchor.constraint(equalToConstant: titleW).isActive = true

        let subtitleW = PluginBarChipLayout.subtitleWidth(scale: scale)
        subtitleField.font = .systemFont(ofSize: max(8, fontSize - 1), weight: .medium)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.isEditable = false
        subtitleField.isBezeled = false
        subtitleField.drawsBackground = false
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.widthAnchor.constraint(equalToConstant: subtitleW).isActive = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: chipW),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padX),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: max(14, 16 * scale))
        ])
    }

    private func render(animated: Bool) {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }

        let apply = { [weak self] in
            guard let self else { return }
            self.row.arrangedSubviews.forEach { self.row.removeArrangedSubview($0); $0.removeFromSuperview() }
            self.row.addArrangedSubview(self.iconView)

            // Badge slot is always present so chip width stays stable when count changes.
            if self.unread > 0 {
                self.badgeField.stringValue = self.unread > 99 ? "99+" : "\(self.unread)"
                self.badgeField.alphaValue = 1
            } else {
                self.badgeField.stringValue = ""
                self.badgeField.alphaValue = 0
            }
            self.row.addArrangedSubview(self.badgeField)

            if !self.hasToken {
                self.titleField.stringValue = PluginL10n.t("plugin.github.title", locale: self.locale)
                self.row.addArrangedSubview(self.titleField)
                return
            }

            if self.highlights.isEmpty {
                self.titleField.stringValue = self.unread > 0
                    ? PluginL10n.t("plugin.github.title", locale: self.locale)
                    : PluginL10n.t("plugin.github.bar.ok", locale: self.locale)
                self.row.addArrangedSubview(self.titleField)
                return
            }

            let item = self.highlights[self.index % self.highlights.count]
            self.titleField.stringValue = PluginBarChipLayout.short(item.title(locale: self.locale), max: 14)
            self.subtitleField.stringValue = PluginBarChipLayout.short(item.subtitle(locale: self.locale), max: 12)
            self.row.addArrangedSubview(self.titleField)
            self.row.addArrangedSubview(self.subtitleField)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                row.animator().alphaValue = 0.2
            } completionHandler: {
                apply()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    self.row.animator().alphaValue = 1
                }
            }
        } else {
            apply()
        }
    }

    private func startCycle() {
        stopCycle()
        let t = Timer(timeInterval: PluginBarChipLayout.cycleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.highlights.count > 1 else { return }
                self.index = (self.index + 1) % self.highlights.count
                self.render(animated: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        cycleTimer = t
    }

    private func stopCycle() {
        cycleTimer?.invalidate()
        cycleTimer = nil
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: GitHubPlugin())
}
