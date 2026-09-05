<p align="center">
  <img src="screenshots/alwm.png" alt="ALWM" width="280" />
</p>

<h1 align="center">ALWM</h1>

<p align="center">
  <strong>Tiling window manager for macOS</strong><br />
  Niri-style scrolling columns or Dwindle BSP — pick per workspace.
</p>

<p align="center">
  <a href="https://github.com/sponsors/lokize"><img src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github&style=for-the-badge" alt="Sponsor" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=for-the-badge" alt="GPL-3.0" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=for-the-badge" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/Swift-6-orange?style=for-the-badge" alt="Swift 6" />
</p>

<p align="center">
  Built from scratch, inspired by <a href="https://github.com/YaLTeR/niri">Niri</a>. Licensed under <strong>GPL-3.0</strong>.
</p>

---

## Screenshots

<p align="center">
  <img src="screenshots/1.jpg" alt="ALWM Settings" width="860" />
</p>
<p align="center"><em>Settings — general, layout, workspace bar, plugins, and more.</em></p>

<p align="center">
  <img src="screenshots/3.jpg" alt="ALWM status menu and tools" width="420" />
</p>
<p align="center"><em>Status menu — quick toggles, recent notes, and tools.</em></p>

<p align="center">
  <img src="screenshots/2.jpg" alt="ALWM modular ecosystem" width="720" />
</p>
<p align="center"><em>Modular ecosystem — workspaces, window controls, tools, and plugins.</em></p>

---

## What you get

### Layout & windows
- **Niri** — scrolling columns with stacked tiles (per workspace)
- **Dwindle** — binary-space-partition splits (per workspace)
- **Multi-monitor** — pin workspaces to a display (`monitorIndex`)
- **Float / tile** — pull a window out of the layout or put it back
- **Column maximize** — expand the focused tile to fill its column
- **Focus border** — highlight the active tiled window
- **App rules** — float, ignore, or pin apps via `apprules.d/*.toml`
- **Sticky homes** — windows remember their workspace across relaunches

### Chrome & overlays
- **Workspace bar** — chips, app icons, focused title, plugin slots (overlay menu bar or below)
- **Overview** — workspace thumbnails (bind `overview.toggle` yourself; also via palette)
- **Status menu** — Focus Follows Mouse, borders, workspace bar, sleep lock, tools, update badge
- **Command palette** — fuzzy search for every action + chord

### Tools
- **Quake terminal** — drop-down float (Ghostty if installed, else Terminal.app); stays scratchpad (not tiled)
- **Notepad** — block editor with categories, tabs, `/` commands + toolbar (headings, lists, code, callouts…)
- **Screen capture** — region / display PNG → `~/Pictures/ALWM`
- **Screen recording** — mic + system audio → `~/Movies/ALWM`
- **Color palette** — eyedropper + copy hex (status menu / tools)
- **In-app updates** — checks GitHub Releases; Update from About or the status menu

### Input & config
- **Hotkeys** — fully editable (Settings or `hotkeys.toml`)
- **Trackpad gestures** — 3-finger column/stack scroll, 4-finger workspace switch
- **Focus follows mouse** — optional; warp cursor on focus / empty workspace
- **Settings UI** — General, About, Diagnostics, Layout, Monitors, Workspaces, App Rules, Workspace Bar, Borders, Gestures, Hotkeys, Quake, Capture, Notepad, Plugins
- **10 languages** — follows macOS by default
- **Live TOML** — `~/.config/alwm/` reloads without a full restart for most settings
- **IPC** — `alwmctl` for scripting
- **Plugins** — Sample Clock, Steam price watcher, GitHub; [write your own](docs/plugins.md)
- **Open at login** — Login Item (Settings → General)
- **About** — version, What's New, GitHub contributors, Stripe donors

---

## Requirements

- macOS 15+
- Swift 6 / Xcode 16+ (to build from source)
- **Accessibility** (tiling)
- **Input Monitoring** (hotkeys & trackpad gestures)
- **Screen Recording** (Overview thumbnails, capture, recording)

---

## Download (macOS)

Pre-built **DMG** for each release on [GitHub Releases](https://github.com/lokize/ALWM---Tiling-window-manager-for-macOS/releases):

1. Download `ALWM-x.y.z.dmg`
2. Open it and drag **ALWM** into **Applications**
3. First launch: right-click the app → **Open** (CI builds are ad-hoc signed)
4. Grant **Accessibility** and **Input Monitoring**

Pushes to `main` trigger an automatic release build (version from `VERSION` in the repo). **Each push with code changes must bump `VERSION`** — otherwise CI refreshes the existing release tag instead of creating a new one.

Sync to GitHub (auto bump if missing):

```bash
bash scripts/install-git-hooks.sh   # once: pre-commit + pre-push
bash scripts/sync-push.sh           # bump + push main
```

To publish manually from your machine (after `gh auth login`):

```bash
bash scripts/publish-github-release.sh
```

Building locally with `package.sh` + `create-dmg.sh` only creates `dist/ALWM-{VERSION}.dmg` — it does **not** upload to GitHub.

---

## Build

```bash
./scripts/package.sh
```

Installs to `~/Applications/ALWM.app` and `~/.local/bin/alwmctl`, then relaunches.

```bash
ALWM_CONFIG=release ./scripts/package.sh          # optimized
ALWM_CONFIG=release ALWM_FAST_RELEASE=1 ./scripts/package.sh
ALWM_RELAUNCH=0 ./scripts/package.sh              # package only
```

Signing uses a stable local cert (`ALWM Local Signing` in `~/.config/alwm/signing/`) so TCC grants survive rebuilds. Ad-hoc signing (`codesign -s -`) changes the CDHash every time and macOS treats it as a new app — avoid it.

Optional: `export ALWM_SIGN_IDENTITY="Apple Development: Your Name"`.

---

## First run

1. Open `~/Applications/ALWM.app`
2. Grant **Accessibility** and **Input Monitoring**
3. Tiling starts on managed windows
4. ALWM registers as a **Login Item** by default (Settings → General to change)

```bash
alwmctl focus left
alwmctl quake
alwmctl palette
alwmctl float toggle
alwmctl switch-workspace 2
alwmctl status
```

---

## Hotkeys (defaults)

Chords below match a fresh `~/.config/alwm/hotkeys.toml` (and `AlwmConfig.defaultHotkeys`). Everything is editable in **Settings → Hotkeys** or that file.

### Focus & move

| Chord | Action |
|---|---|
| ⌥ ← / → / ↑ / ↓ | Focus tiled window |
| ⌥ H / L / K / J | Focus (vim keys) |
| ⌥⇧ ← / → / ↑ / ↓ | Move / peel window in the layout |

### Resize & scroll (Niri)

| Chord | Action |
|---|---|
| ⌥ - / ⌥ = | Resize column width (shrink / grow) |
| ⌥⇧ - / ⌥⇧ = | Resize stack height (up / down neighbor) |
| ⌥ U / I | Scroll the column strip left / right |

### Workspaces

| Chord | Action |
|---|---|
| ⌥ 1–9 | Switch to workspace 1–9 |
| ⌥ 0 | Switch to workspace 10 |
| ⌥ F1–F10 | Switch to workspace 11–20 |
| ⌥⇧ 1–9 / 0 / F1–F10 | Send focused window to that workspace |

Only workspaces that exist in `workspaces.toml` are useful; extras can be bound for later.

### Float, maximize & chrome

| Chord | Action |
|---|---|
| ⌥ F | Toggle float |
| ⌥⇧ F | Maximize focused tile in its column |
| ⌥ , | Open Settings |
| ⌥ P | Command palette |

### Quake & notepad

| Chord | Action |
|---|---|
| ⌥ T | Toggle Quake terminal |
| ⌥ N | Toggle notepad |
| ⌥⇧ N | New note (opens notepad) |

### Capture

| Chord | Action |
|---|---|
| ⌃⌘⇧ 4 | Capture region |
| ⌃⌘⇧ 3 | Capture display |
| ⌃⌘⇧ 5 | Start / stop recording |

### Unbound by default (palette or bind in Settings)

| Action | Notes |
|---|---|
| `overview.toggle` | Workspace overview |
| `relayout` | Re-apply layout (also in status menu) |
| `workspace.prev` / `workspace.next` | Also bound to **4-finger** trackpad by default |
| `float.on` / `float.off` | Force float / tile |
| `debug.dump` | Copy runtime dump (developer mode) |

### Trackpad gestures (defaults)

| Gesture | Action |
|---|---|
| 3 fingers horizontal | Scroll columns (`scroll.columns`) |
| 3 fingers vertical | Scroll stack in focused column (`scroll.stack`) |
| 4 fingers left / right | Previous / next workspace |

Edit in **Settings → Gestures** or `~/.config/alwm/gestures.toml`. For 3/4-finger swipes, grant **Input Monitoring** and turn off Mission Control’s competing trackpad swipes.

---

## Config

```
~/.config/alwm/
├── settings.toml
├── gestures.toml
├── hotkeys.toml
├── workspaces.toml
├── plugins.toml
├── runtime-state.json
├── notes/
└── apprules.d/
```

```toml
[[workspaces]]
id = "1"
name = "Code"
layout = "niri"
monitorIndex = 0

[[workspaces]]
id = "2"
name = "Chat"
layout = "dwindle"
monitorIndex = 1
```

Quake prefers Ghostty (`com.mitchellh.ghostty`); override with `quakeBundleID` in settings. To leave Ghostty’s own quick terminal alone, see `apprules.d/ghostty-quick-terminal.toml.sample`.

---

## Plugins

Bundled plugins live under `plugins/` (same **GPL-3.0** as the app) and show up in **Settings → Plugins**:

| Plugin | Role |
|---|---|
| **Sample Clock** | Time chip on the workspace bar |
| **Steam Price Watcher** | Track Steam prices on the bar |
| **GitHub** | Notifications / activity chip |

Enable, pick bar placement, and optionally lock a chip to one monitor. Docs for authors (API, packaging, PR): **[docs/plugins.md](docs/plugins.md)**.

---

## Versioning

`MAJOR.MINOR.PATCH`. Patch rolls `0.2.9` → `0.3.0`; minor rolls `0.9.9` → `1.0.0`.

```bash
bash scripts/bump-version.sh "User-facing change" "Another change"
bash scripts/install-git-hooks.sh   # optional pre-commit bump
```

What's New bullets are English; commit messages in this repo are usually PT-BR.

---

## Support

ALWM is free and open source. If it helps your workflow, you can sponsor development on GitHub:

**[♥ Sponsor on GitHub](https://github.com/sponsors/lokize)**

That funds ongoing work on tiling, plugins, and macOS quirks. PRs and issues are welcome too — see [docs/plugins.md](docs/plugins.md) if you want to ship a plugin.

---

## License

[GNU General Public License v3.0](LICENSE) (GPL-3.0).

Copyright © 2026 ALWM contributors.
