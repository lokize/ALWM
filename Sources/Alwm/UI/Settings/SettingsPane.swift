import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Settings navigation panes

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, about, diagnostics
    case layout, monitors, workspaces, rules
    case workspaceBar, borders
    case gesturesFocus, hotkeys
    case quake, capture, notepad, plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("pane.general")
        case .about: return L10n.t("pane.about")
        case .diagnostics: return L10n.t("pane.diagnostics")
        case .layout: return L10n.t("pane.layout")
        case .monitors: return L10n.t("pane.monitors")
        case .workspaces: return L10n.t("pane.workspaces")
        case .rules: return L10n.t("pane.rules")
        case .workspaceBar: return L10n.t("pane.workspace_bar")
        case .borders: return L10n.t("pane.borders")
        case .gesturesFocus: return L10n.t("pane.gestures")
        case .hotkeys: return L10n.t("pane.hotkeys")
        case .quake: return L10n.t("pane.quake")
        case .capture: return L10n.t("pane.capture")
        case .notepad: return L10n.t("pane.notepad")
        case .plugins: return L10n.t("pane.plugins")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .about: return "info.circle"
        case .diagnostics: return "stethoscope"
        case .layout: return "rectangle.split.3x1"
        case .monitors: return "display.2"
        case .workspaces: return "square.grid.2x2"
        case .rules: return "list.bullet.rectangle"
        case .workspaceBar: return "menubar.rectangle"
        case .borders: return "square.dashed"
        case .gesturesFocus: return "hand.point.up.left"
        case .hotkeys: return "keyboard"
        case .quake: return "terminal"
        case .capture: return "camera.viewfinder"
        case .notepad: return "note.text"
        case .plugins: return "puzzlepiece.extension"
        }
    }
}

