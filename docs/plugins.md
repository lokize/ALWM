# Plugins

ALWM ships plugins inside the app (`Contents/PlugIns/*.alwmplugin`). There is no separate store yet — new plugins land through pull requests. Bundled plugins and the plugin API are **GPL-3.0**, same as the host app.

**Stats-style system chips roadmap:** [plugins-stats-roadmap.md](plugins-stats-roadmap.md) (CPU, RAM, network, battery, …).

## Add one

1. Fork [ALWM](https://github.com/lokize/ALWM---Tiling-window-manager-for-macOS) and copy `plugins/sample-clock/` (or use `steam-price-watcher` as a fuller example).
2. Set a unique `id` in `plugin.json` (`dev.you.something`).
3. Implement `AlwmPlugin`, export `alwm_plugin_create` via `AlwmPluginExport.makeVTable`.
4. Register the dynamic library in `Package.swift` and `scripts/package.sh`.
5. `./scripts/package.sh` → enable it under **Settings → Plugins**.
6. Open a PR to `main`.

## Layout

```
plugins/my-plugin/
  plugin.json
  README.md              # English (repo docs)
  l10n/                  # required — one .md per app language
    en.md
    pt-BR.md
    …                      # zh-Hans, hi, es, fr, ar, bn, ru, ur
  previews/card.png
  Sources/…
  Resources/          # optional
```

Generate or refresh catalog markdown:

```bash
swift scripts/generate-plugin-catalog-l10n.swift
bash scripts/verify-plugin-l10n.sh
```

`plugin.json` example:

```json
{
  "id": "dev.you.my-plugin",
  "name": "My Plugin",
  "author": "You",
  "version": "1.0.0",
  "apiVersion": 1,
  "summary": "Short catalog blurb.",
  "category": "utilities",
  "preview": "previews/card.png",
  "screenshots": ["previews/01.png"],
  "defaultPlacement": "afterWorkspaces"
}
```

Placement: `beforeWorkspaces` | `afterWorkspaces`. Users can change placement and monitor in Settings.

Category (`category`): `system` | `media` | `integrations` | `utilities` — used in Settings → Plugins search and filters.

## Entry point

```swift
import AppKit
import AlwmPluginAPI
import AlwmPluginABI

public final class MyPlugin: AlwmPlugin {
    public let pluginID = "dev.you.my-plugin"
    private weak var context: AlwmPluginContext?

    public init() {}
    public func load(context: AlwmPluginContext) { self.context = context }
    public func unload() { context = nil }

    public func barItem(placement: AlwmBarPlacement) -> NSView? { /* chip view or nil */ }
    public func barSignature() -> String { "my-plugin" }
}

@_cdecl("alwm_plugin_create")
public func alwm_plugin_create() -> UnsafeMutablePointer<AlwmPluginVTable>? {
    AlwmPluginExport.makeVTable(plugin: MyPlugin())
}
```

`apiVersion` must not exceed `alwmPluginAPIVersion` in `Sources/AlwmPluginAPI`. Call `context.requestBarRefresh()` when the chip should redraw (from the main thread if you’re off-actor).

## Localization (required)

Plugins **must** follow the language set in **Settings → Language** (same codes as the app: `en`, `zh-Hans`, `hi`, `es`, `fr`, `ar`, `bn`, `pt-BR`, `ru`, `ur`). Do not hardcode UI copy or use `Locale.current`.

1. Depend on `AlwmL10n` in `Package.swift`.
2. Use `PluginL10n.t("plugin.my.key")` / `PluginL10n.tf(...)` for every user-visible string.
3. Add keys for **all** app languages in `scripts/generate-plugin-strings.swift`, then run:

```bash
swift scripts/generate-plugin-strings.swift
```

4. For SwiftUI panels, wrap with `.pluginLocalized()` so they refresh when the language changes.
5. Include `PluginL10n.currentCode` in `barSignature()` so the workspace bar rebuilds chips after a language switch.
6. Add **`l10n/{locale}.md`** for every app language (see `scripts/generate-plugin-catalog-l10n.swift`) plus **`plugin.*.catalog.summary`** keys in `scripts/generate-plugin-strings.swift` for the Settings catalog blurb.
7. Run `bash scripts/verify-plugin-l10n.sh` before opening a PR.

`PluginLocaleBridge` is stored in **UserDefaults** (`dev.alwm.languageCode`) so host and plugin dylibs share the same language (SPM links `AlwmL10n` statically into each binary). Prefer `PluginL10n.t` / `context.localeIdentifier` so plugins stay in sync.

## Package wiring

- `Package.swift`: dynamic library product + target under `plugins/my-plugin` (exclude `plugin.json`, `README.md`, `previews`, `Resources`); depend on `AlwmL10n` if the plugin has UI strings.
- `scripts/package.sh`: another `package_plugin …` line next to SampleClock / SteamPriceWatcher / GitHub.

## Before you PR

Unique id, README, preview image, builds clean, chip works with enable/placement/monitor settings, no secrets. Plugins run in-process with ALWM — keep that in mind when reviewing.

[Compare & open a PR](https://github.com/lokize/ALWM---Tiling-window-manager-for-macOS/compare)
