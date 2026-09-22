import AppKit
import Foundation
import AlwmPluginAPI
import AlwmPluginABI
import AlwmL10n
import AlwmStatsKit

/// Hosts the stats chip and adds a right-click context menu.
private final class ClipboardChipHost: NSView {
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

/// Clipboard history chip for the ALWM workspace bar.
public final class ClipboardPlugin: AlwmPlugin {
    public let pluginID = "dev.alwm.clipboard"

    private weak var context: AlwmPluginContext?
    private var languageObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var hotkeyGlobal: Any?
    private var hotkeyLocal: Any?

    public init() {}

    public func load(context: AlwmPluginContext) {
        self.context = context
        let store = ClipboardStore.shared
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
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            ClipboardStore.shared.stop()
        }
        store.start()
        installHotkey()
    }

    public func unload() {
        removeHotkey()
        ClipboardStore.shared.stop()
        ClipboardStore.shared.onChange = nil
        ClipboardStore.shared.localeCode = { PluginL10n.currentCode }
        Task { @MainActor in
            ClipboardPanelController.close()
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        context = nil
    }

    public func barItem(placement: AlwmBarPlacement) -> NSView? {
        _ = placement
        let store = ClipboardStore.shared
        let scale = context?.barScale ?? 1
        let chip = StatsBarChipView(
            symbolName: "clipboard",
            value: store.barLabel,
            tint: store.barTint,
            scale: scale,
            tooltip: store.tooltip
        )
        chip.onClick = nil

        let host = ClipboardChipHost()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            chip.topAnchor.constraint(equalTo: host.topAnchor),
            chip.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        // Chip draws; host owns all clicks (left + right-click menu).
        chip.onClick = nil
        host.onLeftClick = { [weak host] in
            let geometry = PluginPanelAnchor.geometry(of: host)
            Task { @MainActor in
                PluginPanelAnchor.remember(geometry, forPlugin: "dev.alwm.clipboard")
                ClipboardPanelController.toggle(anchoredTo: geometry)
            }
        }
        host.menuBuilder = { [weak self] in
            self?.makeContextMenu() ?? NSMenu()
        }
        return host
    }

    public func barSignature() -> String {
        let store = ClipboardStore.shared
        return "clip:\(store.itemCount):\(store.filter.rawValue):\(PluginL10n.currentCode)"
    }

    private func makeContextMenu() -> NSMenu {
        let loc = ClipboardStore.shared.localeCode()
        let menu = NSMenu()
        menu.addItem(withTitle: PluginL10n.t("plugin.clipboard.menu.open", locale: loc), action: nil, keyEquivalent: "")
        menu.items.last?.target = nil
        let open = menu.items.last!
        open.representedObject = "open"
        // Use closures via custom target helper
        let target = ClipboardMenuTarget.shared
        open.target = target
        open.action = #selector(ClipboardMenuTarget.openPanel)

        let paste = menu.addItem(
            withTitle: PluginL10n.t("plugin.clipboard.menu.paste_last", locale: loc),
            action: #selector(ClipboardMenuTarget.pasteLast),
            keyEquivalent: ""
        )
        paste.target = target
        paste.isEnabled = ClipboardStore.shared.itemCount > 0

        menu.addItem(.separator())

        let clear = menu.addItem(
            withTitle: PluginL10n.t("plugin.clipboard.menu.clear_unpinned", locale: loc),
            action: #selector(ClipboardMenuTarget.clearUnpinned),
            keyEquivalent: ""
        )
        clear.target = target

        let clearAll = menu.addItem(
            withTitle: PluginL10n.t("plugin.clipboard.menu.clear_all", locale: loc),
            action: #selector(ClipboardMenuTarget.clearAll),
            keyEquivalent: ""
        )
        clearAll.target = target

        return menu
    }

    /// ⌘⇧V toggles the clipboard history panel.
    private func installHotkey() {
        removeHotkey()
        let open: () -> Void = {
            DispatchQueue.main.async {
                Task { @MainActor in
                    let geo = PluginPanelAnchor.remembered(forPlugin: "dev.alwm.clipboard")
                    ClipboardPanelController.toggle(anchoredTo: geo)
                }
            }
        }
        let handler: (NSEvent) -> Void = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), flags.contains(.shift),
                  !flags.contains(.option), !flags.contains(.control)
            else { return }
            // keyCode 9 = V
            guard event.keyCode == 9 else { return }
            open()
        }
        hotkeyGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
        }
        hotkeyLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), flags.contains(.shift),
               !flags.contains(.option), !flags.contains(.control),
               event.keyCode == 9 {
                open()
                return nil
            }
            return event
        }
    }

    private func removeHotkey() {
        if let hotkeyGlobal {
            NSEvent.removeMonitor(hotkeyGlobal)
            self.hotkeyGlobal = nil
        }
        if let hotkeyLocal {
            NSEvent.removeMonitor(hotkeyLocal)
            self.hotkeyLocal = nil
        }
    }
}

@objc
private final class ClipboardMenuTarget: NSObject, @unchecked Sendable {
    static let shared = ClipboardMenuTarget()

    @objc func openPanel() {
        Task { @MainActor in
            let geo = PluginPanelAnchor.remembered(forPlugin: "dev.alwm.clipboard")
            ClipboardPanelController.toggle(anchoredTo: geo)
        }
    }

    @objc func pasteLast() {
        ClipboardStore.shared.pasteMostRecent()
    }

    @objc func clearUnpinned() {
        ClipboardStore.shared.clearUnpinned()
    }

    @objc func clearAll() {
        ClipboardStore.shared.clearAll()
    }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: ClipboardPlugin())
}
