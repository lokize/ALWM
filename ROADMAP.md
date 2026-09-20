# Roadmap — ideias de plugins e recursos

Sugestões alinhadas com o ALWM (workspace bar + tiling + stats + tools).  
Não repetem o que já existe: CPU, RAM, Disk, Network, Battery, GPU, Sensors, Fans, Bluetooth, Uptime, GitHub, Now Playing, Sample Clock, Steam/Nintendo price watchers.

**Legenda:** ✅ concluído · ⏳ em andamento · (sem marca = pendente)

## Concluído

| Item | Quando | Notas |
|------|--------|-------|
| Plugin health / ABI pós-update (Prioridade 1 · Core #10) | **2026-09-18 15:18** | `package.sh` exige/sintetiza `libAlwmPluginABI.dylib`; plugins voltam a carregar após update/release. UI “reparar” ainda pendente. |
| Este ROADMAP | **2026-09-19 11:16** | Documento criado com ideias e prioridade ROI. |
| Sessões nomeadas (Core #3 · Prioridade 7) | **2026-09-19 11:33** | `sessionApps` + `sessionQuitOthers` em workspaces.toml; ao trocar de WS abre apps da sessão e (opcional) fecha os demais. Finder/ALWM/Dock/Quake protegidos. |
| Pomodoro + impedir sono (Plugin · Prioridade 6) | **2026-09-19 11:41** | Chip de foco na barra; keep-awake via IOPM durante focus (mesma ideia do Impedir sono); notificações de fase. |
| Calendar chip (Plugin · Prioridade 2) | **2026-09-19 12:40** | Chip do dia + agenda/hoje/próximos, notificações e adição rápida (EventKit). |
| Calendar & Weather (melhoria) | **2026-09-19 13:40** | Previsão 7 dias (Open-Meteo), localização editável; chip com ícone do tempo + temperatura. |
| Clipboard history (Plugin · Prioridade 3) | **2026-09-19 12:40** | Histórico na barra com busca, pin e filtros texto/imagem/vídeo. |
| Clipboard History v0.2 | **2026-09-20 10:55** | ⌘⇧V, colar no app ativo, teclado ↑↓/Enter/Esc, links/arquivos, persistência, ignora senhas, menu no chip. |

## Plugins (chips na barra)

| # | Plugin | Descrição | Status |
|---|--------|-----------|--------|
| 1 | **Próximo evento (Calendar)** | Próximo compromisso + countdown; clique abre o evento. Encaixa no chip de status focado. | ✅ **2026-09-19 12:40** · tempo **13:40** |
| 2 | **Clipboard history** | Últimos N itens, pin, busca rápida; atalho + chip com contagem. | ✅ **2026-09-19 12:40** |
| 3 | **Pomodoro / Focus timer** | Sessão, pausa, estatística do dia; combina com “Impedir sono”. | ✅ **2026-09-19 11:41** |
| 4 | **World clock / timezones** | Além do Sample Clock: 2–3 fusos (útil pra DevOps/remoto). | |
| 5 | **VPN / rede ativa** | Status WireGuard/Tailscale/VPN do sistema + IP/hostname curto. | |
| 6 | **Docker / containers** | Contagem running/stopped; menu pra stop/restart. | |
| 7 | **PR/CI unificado** | Além do GitHub: GitLab/Bitbucket ou só “CI vermelho” agregado. | |
| 8 | **Linear / Jira / Notion lite** | Contagem de issues atribuídas a você. | |
| 9 | **Weather** | Temperatura + condição no chip. | ✅ **2026-09-19 13:40** — integrado ao Calendar & Weather |
| 10 | **Audio device / mic mute** | Input/output atual + mute (útil com Discord/calls). | |
| 11 | **Brightness / volume** | Chip compacto com popover. | |
| 12 | **Battery detalhada** | Ciclo + saúde + tempo restante (se ainda não coberto pelo stats-battery). | ✅ parcial — stats-battery já cobre base |
| 13 | **SSH hosts / tmux** | Lista hosts do `~/.ssh/config`; abre no Quake/Terminal. | |
| 14 | **Lyrics mini** | Extensão natural do Now Playing (Spotify/Apple Music). | |
| 15 | **Security lock** | Chip bloqueado/desbloqueado + atalho pra lock screen. | |

## Recursos do app (core)

| # | Recurso | Descrição | Status |
|---|---------|-----------|--------|
| 1 | **Layouts salvos por workspace** | “WS2 = editor \| terminal \| browser” e restore com um clique. | |
| 2 | **App → workspace sticky rules** | Discord sempre WS1, Terminal WS2 (persistência pós-sono). | ⏳ base sticky já existe; UX/regras ainda a expandir |
| 3 | **Sessões nomeadas** | “CERES SISTEMAS \| DEVOPS” como perfil: apps + layout + plugins ativos. Abrir apps da sessão e fechar os demais ao trocar. | ✅ **2026-09-19 11:33** — apps + quit; plugins por WS ainda fase 2 |
| 4 | **Scratchpad / hide-to-scratch** | Janela some e volta com hotkey (yabai/i3). | |
| 5 | **PiP / float zone** | Canto fixo pra call/vídeo sem quebrar o tile. | |
| 6 | **Window history / recent focus** | Alt-Tab estilo ALWM entre workspaces atuais. | |
| 7 | **Gestos trackpad** | 3/4 dedos pra trocar WS / mover janela. | ⏳ GestureScrollMonitor já existe |
| 8 | **Multi-monitor smarter** | Foco no monitor sob o cursor; bar por display. | |
| 9 | **Plugin slots por workspace** | WS1: Discord/GitHub; WS2: CPU/Docker. | |
| 10 | **Plugin health / repair** | Após update: “N plugins falharam” + botão reparar (ABI etc.). | ✅ **2026-09-18 15:18** — ABI no package; UI repair ainda pendente |
| 11 | **Notes ↔ workspace** | Nota pinada por WS. | |
| 12 | **Command Palette → plugins** | “toggle CPU chip”, “start pomodoro 25”. | |
| 13 | **Themes / accent sync** | Cor da borda de foco = chip ativo / avatar. | |
| 14 | **Export/import config** | TOML + lista de plugins pra outro Mac. | |
| 15 | **Focus mode** | Esconde chips de stats; só calendário + timer + focused status. | |

## Prioridade (ROI)

| Prioridade | O quê | Por quê | Status |
|------------|-------|---------|--------|
| 1 | Plugin health / repair após update | Resolve dor real (plugins sumindo pós-update) | ✅ **2026-09-18 15:18** |
| 2 | Calendar chip | Uso diário, zero fricção | ✅ **2026-09-19 12:40** |
| 3 | Clipboard history | Ferramenta que a barra pede | ✅ **2026-09-19 12:40** |
| 4 | Layouts por workspace | Diferencial vs menu bar genérico | |
| 5 | Docker ou VPN chip | Casa com perfil DevOps | |
| 6 | Pomodoro + impedir sono | Combina controles que já existem | ✅ **2026-09-19 11:41** |
| 7 | Sessões nomeadas | Escala o label do workspace pra workflow completo | ✅ **2026-09-19 11:33** |

## Não priorizar agora

- Mais um `stats-*` genérico (CPU/RAM já cobrem bem)
- Outro price watcher
- Clone de Raycast cheio de extensões

O diferencial do ALWM é **window manager + barra de workspaces**, não ser mais um launcher.
