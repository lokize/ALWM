import Foundation

/// Shared action catalog: titles, descriptions, and chord formatting for Settings + Command Palette.
public enum HotkeyActions {
    public static let all: [String] = [
        "focus.left", "focus.right", "focus.up", "focus.down",
        "move.left", "move.right", "move.up", "move.down",
        "scroll.columns", "scroll.stack", "scroll.left", "scroll.right",
        "workspace.prev", "workspace.next",
    ] + (1...AlwmConfig.defaultWorkspaceHotkeyCount).flatMap { n -> [String] in
        let id = String(n)
        return ["workspace.\(id)", "move.to.workspace.\(id)"]
    } + [
        "resize.left", "resize.right", "resize.up", "resize.down",
        "quake.toggle", "notepad.toggle", "notepad.new", "palette.toggle",
        "capture.region", "capture.display", "capture.record.toggle",
        "float.toggle", "float.on", "float.off",
        "column.maximize",
        "settings.open", "relayout", "debug.dump"
    ]

    /// Base catalog plus dynamic workspace switch/send actions for configured workspaces.
    public static func catalog(workspaces: [WorkspaceDefinition] = []) -> [String] {
        var actions = all
        let known = Set(actions)
        for ws in workspaces {
            let switchAction = "workspace.\(ws.id)"
            let moveAction = "move.to.workspace.\(ws.id)"
            if !known.contains(switchAction) {
                actions.append(switchAction)
            }
            if !known.contains(moveAction) {
                actions.append(moveAction)
            }
        }
        return actions
    }

    /// Actions that make sense for trackpad gesture bindings (includes continuous scroll).
    public static let gestureActions: [String] = all

    public static func title(for action: String) -> String {
        switch action {
        case "focus.left": return L10n.t("action.focus.left")
        case "focus.right": return L10n.t("action.focus.right")
        case "focus.up": return L10n.t("action.focus.up")
        case "focus.down": return L10n.t("action.focus.down")
        case "move.left": return L10n.t("action.move.left")
        case "move.right": return L10n.t("action.move.right")
        case "move.up": return L10n.t("action.move.up")
        case "move.down": return L10n.t("action.move.down")
        case "scroll.columns": return L10n.t("action.scroll.columns")
        case "scroll.stack": return L10n.t("action.scroll.stack")
        case "scroll.left": return L10n.t("action.scroll.left")
        case "scroll.right": return L10n.t("action.scroll.right")
        case "workspace.prev": return L10n.t("action.workspace.prev")
        case "workspace.next": return L10n.t("action.workspace.next")
        case "workspace.1", "workspace.2", "workspace.3", "workspace.4":
            return L10n.tf("action.workspace.n", String(action.dropFirst("workspace.".count)))
        case "move.to.workspace.1", "move.to.workspace.2", "move.to.workspace.3", "move.to.workspace.4":
            return L10n.tf("action.move.to.workspace.n", String(action.dropFirst("move.to.workspace.".count)))
        case "resize.left": return L10n.t("action.resize.left")
        case "resize.right": return L10n.t("action.resize.right")
        case "resize.up": return L10n.t("action.resize.up")
        case "resize.down": return L10n.t("action.resize.down")
        case "overview.toggle": return L10n.t("action.overview.toggle")
        case "quake.toggle": return L10n.t("action.quake.toggle")
        case "notepad.toggle": return L10n.t("action.notepad.toggle")
        case "notepad.new": return L10n.t("action.notepad.new")
        case "palette.toggle": return L10n.t("action.palette.toggle")
        case "capture.region": return L10n.t("action.capture.region")
        case "capture.display": return L10n.t("action.capture.display")
        case "capture.record.toggle": return L10n.t("action.capture.record.toggle")
        case "float.toggle": return L10n.t("action.float.toggle")
        case "float.on": return L10n.t("action.float.on")
        case "float.off": return L10n.t("action.float.off")
        case "column.maximize", "maximize.column": return L10n.t("action.column.maximize")
        case "settings.open": return L10n.t("action.settings.open")
        case "relayout": return L10n.t("action.relayout")
        case "debug.dump": return L10n.t("action.debug.dump")
        default:
            if action.hasPrefix("workspace.") {
                return L10n.tf("action.workspace.n", String(action.dropFirst("workspace.".count)))
            }
            if action.hasPrefix("move.to.workspace.") {
                return L10n.tf("action.move.to.workspace.n", String(action.dropFirst("move.to.workspace.".count)))
            }
            return action
        }
    }

    public static func detail(for action: String) -> String {
        switch action {
        case "focus.left", "focus.right", "focus.up", "focus.down":
            return "Muda o foco entre janelas tileadas na direção indicada."
        case "move.left", "move.right", "move.up", "move.down":
            return "Reposiciona a janela no layout atual (niri: colunas/stack · dwindle: BSP)."
        case "scroll.columns":
            return "Desloca a faixa de colunas continuamente com o gesto (estilo niri)."
        case "scroll.stack":
            return "Rola as janelas empilhadas na coluna focada com o gesto vertical (rápido + inércia)."
        case "scroll.left", "scroll.right":
            return "Desloca a faixa de colunas no estilo niri."
        case "workspace.prev", "workspace.next":
            return "Cicla os workspaces visíveis no monitor atual."
        case "workspace.1", "workspace.2", "workspace.3", "workspace.4":
            return "Troca para esse workspace e mostra só as janelas dele."
        case "move.to.workspace.1", "move.to.workspace.2", "move.to.workspace.3", "move.to.workspace.4":
            return "Envia a janela focada para esse workspace (ela fica só lá)."
        case "resize.left", "resize.right":
            return "Ajusta a largura da coluna ou do split focado."
        case "resize.up", "resize.down":
            return "Ajusta a altura do tile focado na coluna; o vizinho (acima/abaixo) compensa."
        case "overview.toggle":
            return "Mostra o overview dos workspaces do monitor."
        case "quake.toggle":
            return "Mostra ou esconde o terminal Quake (sempre float)."
        case "notepad.toggle":
            return "Abre ou fecha o bloco de notas ALWM (painel Quake)."
        case "notepad.new":
            return "Abre o bloco de notas e cria uma página nova."
        case "palette.toggle":
            return "Abre esta palette para rodar ações por nome ou atalho."
        case "capture.region":
            return "Captura uma área da tela (PNG em ~/Pictures/ALWM)."
        case "capture.display":
            return "Captura a tela cheia do monitor sob o cursor."
        case "capture.record.toggle":
            return "Inicia ou para gravação de vídeo (mic + áudio do sistema) em ~/Movies/ALWM."
        case "float.toggle":
            return "Tira a janela do tiling (float) ou devolve ao tile."
        case "float.on":
            return "Força a janela focada a flutuar (fora do layout)."
        case "float.off":
            return "Devolve a janela focada ao tiling do workspace ativo."
        case "column.maximize", "maximize.column":
            return "Expande a janela focada para preencher toda a coluna (espaço vazio acima/abaixo). ⌥⇧F."
        case "settings.open":
            return "Abre a janela de configurações do ALWM."
        case "relayout":
            return "Recalcula e reaplica o layout das janelas ativas."
        case "debug.dump":
            return "Copia o estado interno para a área de transferência (developerMode)."
        default:
            if action.hasPrefix("workspace.") {
                return "Troca para esse workspace e mostra só as janelas dele."
            }
            if action.hasPrefix("move.to.workspace.") {
                return "Envia a janela focada para esse workspace (ela fica só lá)."
            }
            return "Ação: \(action)"
        }
    }

    /// Pretty chord from a binding, e.g. `⌥⇧1` or `⌥←`.
    public static func chord(key: String, modifiers: [String]) -> String {
        chordTokens(key: key, modifiers: modifiers).joined()
    }

    /// Individual keycap labels in display order (modifiers then key).
    public static func chordTokens(key: String, modifiers: [String]) -> [String] {
        var parts: [String] = []
        let order = ["control", "option", "shift", "command"]
        let set = Set(modifiers.map { $0.lowercased() })
        for name in order where set.contains(name) {
            switch name {
            case "control": parts.append("⌃")
            case "option", "alt": parts.append("⌥")
            case "shift": parts.append("⇧")
            case "command", "cmd": parts.append("⌘")
            default: break
            }
        }
        parts.append(keySymbol(key))
        return parts
    }

    public static func chord(for action: String, in bindings: [HotkeyBinding]) -> String? {
        guard let b = bindings.first(where: { $0.action == action }) else { return nil }
        return chord(key: b.key, modifiers: b.modifiers)
    }

    public static func chordTokens(for action: String, in bindings: [HotkeyBinding]) -> [String]? {
        guard let b = bindings.first(where: { $0.action == action }) else { return nil }
        return chordTokens(key: b.key, modifiers: b.modifiers)
    }

    public static func keySymbol(_ key: String) -> String {
        switch key.lowercased() {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "space": return "Space"
        case "tab": return "⇥"
        case "return", "enter": return "⏎"
        case "escape", "esc": return "Esc"
        case ",": return ","
        case ".": return "."
        case "`", "grave", "backtick": return "`"
        case "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12":
            return key.uppercased()
        default: return key.uppercased()
        }
    }
}
