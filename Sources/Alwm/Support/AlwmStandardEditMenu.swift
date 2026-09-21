import AppKit

/// Agent (LSUIElement) apps have no system Edit menu, so ⌘X/C/V/A never reach
/// text fields via `performKeyEquivalent`. Installing a hidden Edit menu restores
/// cut/copy/paste/select-all for plugin panels, notepad, settings, etc.
public enum AlwmStandardEditMenu {
    @MainActor
    public static func install() {
        if let existing = NSApp.mainMenu,
           existing.items.contains(where: { $0.submenu?.title == "Edit" || $0.title == "Edit" }) {
            return
        }

        let mainMenu = NSMenu()

        // App menu (required for a valid main menu hierarchy).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About ALWM",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ALWM",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit

        edit.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        edit.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        edit.addItem(.separator())
        edit.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        edit.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        edit.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        edit.addItem(
            withTitle: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "V"
        )
        edit.addItem(
            withTitle: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        edit.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        NSApp.mainMenu = mainMenu
    }
}
