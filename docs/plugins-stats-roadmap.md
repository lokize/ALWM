# Stats → ALWM plugins roadmap

Goal: replace [Stats](https://github.com/exelban/stats) menu-bar widgets with **ALWM workspace-bar chips** so system metrics live next to workspaces (the “dock” strip), not in the macOS menu bar.

**Non-negotiable:** every Stats-style plugin must open a **popover menu that looks and feels like Stats** — dense vertical panel, section headers, gauges/charts, detail rows, top processes — not a minimal GitHub-style sheet. Reference screenshots live under the conversation / Stats app itself.

Existing plugins (keep as-is): **Clock**, **GitHub**, **Steam Price Watcher**.

Each item below is a separate `.alwmplugin`. Implement in order; check off as shipped.

---

## Chip (workspace bar)

Compact label + value, same density as Stats menu bar:

| Pattern | Example |
|---|---|
| `CPU 16%` | percent |
| `RAM 75%` | percent |
| `↓0 ↑0 KB/s` | network rates |
| `50°` / mini temp grid | temperature |
| battery icon + `%` | power |

Click → **Stats-like popover** (below). Placement default: `afterWorkspaces`. Users can reorder chips in **Settings → Plugins**.

---

## Panel UX — mandatory (match Stats)

All stats plugins share the same popover language. Build once (shared SwiftUI building blocks), reuse everywhere.

### Shell

- Dark, narrow, tall popover (≈ Stats width; scroll when needed).
- **Header row:** chart icon (left) · title centered (`CPU`, `GPU`, `Rede`, …) · optional ⌘ / settings affordance (right).
- Thin separators with **ALL-CAPS** section labels in the middle (e.g. `— DETALHES —`, `— HISTÓRICO DE USO —`).
- Labels muted gray; values bright white, right-aligned.
- Color legend squares (red / blue / cyan / orange) consistent across gauges, rows, and charts.
- Prefer system fonts (SF); dense but readable padding like Stats.

### Shared building blocks (extract into `AlwmStatsKit` early)

| Block | Used by |
|---|---|
| Circular ring gauges (1–3) | CPU, GPU, Memory, Disk, Battery |
| Line / area usage history chart | CPU, GPU, Memory, Network |
| Stacked / multi-color mini bars | CPU (E/P cores), Memory |
| Key–value detail rows (+ color square) | All |
| Status pill (`UP` / green) | Network |
| Process list (app icon · name · metric) | CPU, Memory, Network, Disk |
| Sensor list (name · value °C) | Sensors |
| Device rows (name · battery %) | Bluetooth |

### Per-plugin panel content (target = Stats parity)

| Plugin | Panel must include |
|---|---|
| **CPU** | 3 ring gauges (temp / total % / load) · usage history + core bars · Details (system / user / idle / E-cores / P-cores / uptime) · Load average 1/5/15 · Frequency (all / E / P) · Top processes |
| **GPU** | Ring gauges (util / render / tiler or equiv.) · usage history · Details (model, cores, util %, ANE, FPS if available) |
| **Memory** | Rings + history · wired / compressed / free / app · pressure · top processes |
| **Network** | Big ↓ / ↑ rates · dual-line history · connectivity history grid · interface totals + status pills · latency/jitter · interface + addresses (local / public) · top processes by traffic |
| **Disk** | Usage ring · free/total · volumes · top readers/writers if feasible |
| **Battery** | Charge ring · % · time remaining · cycles / health · power source |
| **Sensors** | Grouped lists under `TEMPERATURA` (etc.): Airport, NAND, Battery, CPU cores, GPU, PMU… name left · `46.3°C` right |
| **Fans** | Per-fan RPM rows (auto-hide if none) |
| **Bluetooth** | Card rows: device name · battery `%` |

Ship **structure + live data first**; polish charts to pixel-parity with Stats iteratively — but do **not** ship a “chip only” or “3-line panel” plugin and call it done.

---

## Phase 1 — Core (replace daily Stats use)

| # | Plugin ID | Name | Chip | Panel (Stats-like) | Status | Notes |
|---|---|---|---|---|---|---|
| 1 | `dev.alwm.stats-cpu` | **CPU** | `CPU 16%` | Gauges + history + details + load + freq + top processes | ✅ | `host_processor_info` / `mach`; defines shared panel kit |
| 2 | `dev.alwm.stats-memory` | **Memory** | `RAM 75%` | Rings + breakdown + pressure + top processes | ✅ | `vm_statistics64` |
| 3 | `dev.alwm.stats-network` | **Network** | `↓ 0  ↑ 0 KB/s` | Rates + dual history + interface + IPs + top processes | ✅ | `getifaddrs` / IOKit |
| 4 | `dev.alwm.stats-battery` | **Battery** | icon + `%` + plug | Charge + health + cycles + time | ✅ | `IOPMPowerSource` — hide on desktop Mac |
| 5 | `dev.alwm.stats-disk` | **Disk** | `SSD 66%` | Ring + volumes + free/total | ✅ | `FileManager` / `statfs` |

---

## Phase 2 — Sensors & GPU (Stats “pro” strip)

| # | Plugin ID | Name | Chip | Panel (Stats-like) | Status | Notes |
|---|---|---|---|---|---|---|
| 6 | `dev.alwm.stats-gpu` | **GPU** | `GPU 19%` | Rings + history + model/cores/util/ANE/FPS | ✅ | IOKit / Metal; Apple Silicon vs discrete |
| 7 | `dev.alwm.stats-sensors` | **Sensors** | `50°` or mini grid | Long sensor list by group (°C/°F) | ✅ | SMC / IOReport — fragile across models |
| 8 | `dev.alwm.stats-fans` | **Fans** | RPM / `%` | Per-fan rows | ✅ | Auto-hide on fanless MacBooks |

---

## Phase 3 — Nice-to-have

| # | Plugin ID | Name | Chip | Panel (Stats-like) | Status | Notes |
|---|---|---|---|---|---|---|
| 9 | `dev.alwm.stats-bluetooth` | **Bluetooth** | BT / device % | Device cards with battery % | ✅ | Match Stats Bluetooth list |
| 10 | `dev.alwm.now-playing` | **Now Playing** | ▶ title / artist | Transport + artwork | ✅ | Not Stats-core; still dense popover |
| 11 | `dev.alwm.stats-uptime` | **Uptime** | `3d 4h` | Boot time detail | ✅ | Low priority |

---

## Build queue (one by one)

Work **strictly in this order**. Only advance after the current item ships (chip + Stats-like panel + l10n + package wiring). Mark `⬜` → `✅` in the phase tables when done.

| Step | Status | Plugin | Focus |
|:---:|:---:|---|---|
| **1** | ✅ | **CPU** + `AlwmStatsKit` | Chip `CPU n%` · full Stats popover · shared rings/sections/history/process rows |
| **2** | ✅ | **Memory** | Reuse kit · RAM chip · breakdown + pressure + top processes |
| **3** | ✅ | **Network** | ↓↑ chip · dual history · interface · IPs · top traffic |
| **4** | ✅ | **Battery** | Icon + % · health/cycles (auto-hide on desktop) |
| **5** | ✅ | **Disk** | SSD % · volumes |
| **6** | ✅ | **GPU** | Util rings · model/cores/ANE |
| **7** | ✅ | **Sensors** | Long °C list by group |
| **8** | ✅ | **Fans** | RPM rows (skip if fanless) |
| **9** | ✅ | **Bluetooth** | Device battery cards |
| **10** | ✅ | **Now Playing** | Optional media chip |
| **11** | ✅ | **Uptime** | Optional tiny chip |

Rule: **finish step N before starting N+1.** No parallel plugin scaffolds unless extracting shared kit pieces needed by the current step.

---

## Shared engineering rules

1. **One concern per plugin** — enable/disable like Stats modules.
2. **UI parity with Stats popovers** — see “Panel UX” above; no thin substitute panels.
3. **Poll on a timer** (1–2 s for CPU/RAM/net; slower for disk/battery) — never block the main thread on IOKit.
4. **`barSignature()`** includes values + `PluginL10n.currentCode`.
5. **l10n** for all ALWM languages (`en`, `pt-BR`, …) — section titles and labels localized.
6. **GPL-3.0**, unique `plugin.json` id, preview card, wired in `Package.swift` + `scripts/package.sh`.
7. Shared **`AlwmStatsKit`** (gauges, charts, section chrome, formatters) starting with CPU.
8. **Auto-hide** when irrelevant (no battery; no fans; GPU N/A).

---

## Mapping from Stats screenshots

| Stats UI | ALWM plugin |
|---|---|
| CPU chip + full CPU menu | `stats-cpu` |
| GPU chip + full GPU menu | `stats-gpu` |
| RAM | `stats-memory` |
| SSD | `stats-disk` |
| Temp grid + Sensores list | `stats-sensors` |
| Rede (↓↑ + full network menu) | `stats-network` |
| Battery | `stats-battery` |
| Bluetooth device batteries | `stats-bluetooth` |

---

## Out of scope (for now)

- Installing into the **macOS menu bar** (chips live on the ALWM workspace bar only)
- Cloning Stats’ separate full-window process monitor app
- Host API for “widget groups” — separate plugins first

---

## Next step

**Queue complete.** All 11 Stats-roadmap plugins ship. Iterate polish (charts, ANE/FPS, fans on supported Macs, BLE battery via CoreBluetooth) as needed.
