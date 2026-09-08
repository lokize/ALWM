# Plugins

ALWM releases ship a **slim app** without bundled plugins in `Contents/PlugIns`. Users download the plugins they want from **Settings → Plugins**; bundles live in `~/.config/alwm/PlugIns/` and survive app updates. Preferences (`enabled`, `order`, `placement`, `display`, `installed`) are stored in `~/.config/alwm/plugins.toml`.

On launch, ALWM restores any plugin marked `installed = true` into `~/.config/alwm/PlugIns` (from app `Resources/plugins/*.zip`, GitHub Release assets, or a temporary copy in `Contents/PlugIns` on debug builds) and keeps enablement + order unchanged. Host Frameworks (`libAlwmPluginAPI`, `libAlwmL10n`, `libAlwmStatsKit`, …) are preloaded before `dlopen` so user-installed bundles can resolve `@rpath` dependencies outside the `.app`.

Local **debug** builds (`./scripts/package.sh`) still embed plugins in `Contents/PlugIns` for faster iteration; enabling a plugin also copies it into the user PlugIns directory so the next update does not clear it. **Release** builds leave `Contents/PlugIns` empty and publish each plugin as a zip plus `plugins-index.json` on the same GitHub Release as the DMG (zips are also embedded under `Contents/Resources/plugins/` for offline restore).

The plugin API is **GPL-3.0**, same as the host app.

**Stats-style system chips roadmap:** [plugins-stats-roadmap.md](plugins-stats-roadmap.md) (CPU, RAM, network, battery, …).

## User flow

1. Install / update ALWM (DMG has no plugins by default).
2. Open **Settings → Plugins** → **Download** the ones you want (optionally enable).
3. Reorder with the up/down controls under **Bar order**.
4. After an app update, ALWM re-downloads any plugin marked `installed = true` in `plugins.toml` and restores enablement + order.

## Add one (developers)

1. Fork [ALWM](https://github.com/lokize/ALWM---Tiling-window-manager-for-macOS) and copy `plugins/sample-clock/` (or use `steam-price-watcher` as a fuller example).
2. Set a unique `id` in `plugin.json` (`dev.you.something`).
3. Implement `AlwmPlugin`, export `alwm_plugin_create` via `AlwmPluginExport.makeVTable`.
4. Register the dynamic library in `Package.swift` and `scripts/package.sh`.
5. `./scripts/package.sh` (debug embeds the plugin) → enable under **Settings → Plugins**.
6. Open a PR to `main`. Release packaging produces `dist/plugins/<Name>.alwmplugin.zip` and updates `dist/plugins-index.json`.

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

Category (`category`): `system` | `media` | `games` | `integrations` | `developer` | `utilities` — used in Settings → Plugins search and filters.

## Packaging & publish

```bash
# Debug — plugins embedded in the .app
./scripts/package.sh

# Release slim app + dist/plugins/*.zip + plugins-index.json
ALWM_CONFIG=release ALWM_DIST_ONLY=1 ./scripts/package.sh

# Force embedding plugins in a release build (optional)
ALWM_CONFIG=release ALWM_BUNDLE_PLUGINS=1 ./scripts/package.sh

# Publish DMG + plugin zips + index to GitHub Releases
bash scripts/publish-github-release.sh
```

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

## Persistence

| Path | Role |
|------|------|
| `~/.config/alwm/plugins.toml` | `installed`, `version`, `enabled`, `placement`, `display`, `order` |
| `~/.config/alwm/PlugIns/*.alwmplugin` | Downloaded bundles |
| `~/.config/alwm/plugins/<id>.json` | Per-plugin data (tokens, watchlists, …) |
