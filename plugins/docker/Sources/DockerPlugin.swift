import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

private final class DockerChipHost: NSView {
    var onLeftClick: (() -> Void)?
    var menuBuilder: (() -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuBuilder?()
    }
}

/// Docker + Compose manager chip for the ALWM workspace bar.
public final class DockerPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.docker"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = DockerStore.shared
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
        store.start()
    }

    public func unload() {
        DockerStore.shared.stop()
        DockerStore.shared.onChange = nil
        DockerStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            DockerPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = DockerStore.shared
        let scale = context?.barScale ?? 1
        let chip = StatsBarChipView(
            symbolName: "shippingbox.fill",
            value: store.barLabel,
            tint: store.barTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = nil

        let host = DockerChipHost()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            chip.topAnchor.constraint(equalTo: host.topAnchor),
            chip.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.heightAnchor.constraint(equalToConstant: chip.fittingSize.height),
            host.widthAnchor.constraint(equalToConstant: max(chip.fittingSize.width, 1))
        ])
        host.onLeftClick = { [weak host] in
            let geometry = PluginPanelAnchor.geometry(of: host)
            Task { @MainActor in
                PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.docker")
                DockerPanelController.toggle(anchoredTo: geometry)
            }
        }
        host.menuBuilder = { [weak self] in
            self?.makeContextMenu() ?? NSMenu()
        }
        return host
    }

    public func barSignature() -> String {
        let store = DockerStore.shared
        return "docker:\(store.runningCount):\(store.totalCount):\(store.dockerAvailable):\(PluginL10n.currentCode)"
    }

    private func makeContextMenu() -> NSMenu {
        let loc = DockerStore.shared.localeCode()
        let menu = NSMenu()

        let open = NSMenuItem(
            title: PluginL10n.t("plugin.docker.menu.open", locale: loc),
            action: #selector(DockerMenuTarget.openPanel(_:)),
            keyEquivalent: ""
        )
        open.target = DockerMenuTarget.shared
        menu.addItem(open)

        let refresh = NSMenuItem(
            title: PluginL10n.t("plugin.common.refresh", locale: loc),
            action: #selector(DockerMenuTarget.refresh(_:)),
            keyEquivalent: ""
        )
        refresh.target = DockerMenuTarget.shared
        menu.addItem(refresh)

        return menu
    }
}

private final class DockerMenuTarget: NSObject, @unchecked Sendable {
    static let shared = DockerMenuTarget()

    @objc func openPanel(_ sender: Any?) {
        Task { @MainActor in
            DockerPanelController.toggle(anchoredTo: nil)
        }
    }

    @objc func refresh(_ sender: Any?) {
        Task {
            await DockerStore.shared.refresh()
        }
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: DockerPlugin())
}
