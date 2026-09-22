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
            highlight: store.barHighlight,
            highlightCount: store.highlightItems.count,
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
        return "github:\(PluginL10n.currentCode):\(store.hasToken):\(d.unreadCount):\(d.repoPullRequests.count):\(d.reviewRequests.count):\(d.assignedIssues.count):\(store.isRefreshing):\(store.highlightItems.count):\(store.barCycleIndex):\(store.settings.barCycleSeconds)"
    }
}

// MARK: - Bar chip

private final class GitHubBarChipView: NSView {
    private let unread: Int
    private let highlight: GitHubBarHighlight?
    private let highlightCount: Int
    private let hasToken: Bool
    private let isRefreshing: Bool
    private let scale: CGFloat
    private let locale: String

    private let row = NSStackView()
    private let iconView = NSImageView()
    private let badgeField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    init(
        unread: Int,
        highlight: GitHubBarHighlight?,
        highlightCount: Int,
        hasToken: Bool,
        isRefreshing: Bool,
        scale: CGFloat,
        locale: String,
        tooltip: String
    ) {
        self.unread = unread
        self.highlight = highlight
        self.highlightCount = highlightCount
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
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let geometry = PluginPanelAnchor.geometry(of: self)
        Task { @MainActor in
            PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.github")
            GitHubPanelController.toggle(anchoredTo: geometry)
        }
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

    private func render() {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        row.addArrangedSubview(iconView)

        if unread > 0 {
            badgeField.stringValue = unread > 99 ? "99+" : "\(unread)"
            badgeField.alphaValue = 1
        } else {
            badgeField.stringValue = ""
            badgeField.alphaValue = 0
        }
        row.addArrangedSubview(badgeField)

        if !hasToken {
            titleField.stringValue = PluginL10n.t("plugin.github.title", locale: locale)
            row.addArrangedSubview(titleField)
            return
        }

        guard let item = highlight else {
            titleField.stringValue = unread > 0
                ? PluginL10n.t("plugin.github.title", locale: locale)
                : PluginL10n.t("plugin.github.bar.ok", locale: locale)
            row.addArrangedSubview(titleField)
            return
        }

        titleField.stringValue = PluginBarChipLayout.short(item.title(locale: locale), max: 14)
        subtitleField.stringValue = PluginBarChipLayout.short(item.subtitle(locale: locale), max: 12)
        row.addArrangedSubview(titleField)
        row.addArrangedSubview(subtitleField)
        _ = highlightCount
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: GitHubPlugin())
}
