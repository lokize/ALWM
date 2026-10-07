# Quake Terminal History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a searchable, locally persisted Quake terminal history browser for zsh, bash, and fish, with favorites, categories, filters, and modal focus behavior.

**Architecture:** Keep parsing, identity, persistence, and filtering in a small `TerminalHistory` module. A SwiftUI view is hosted in a key-capable floating `NSPanel`; the Quake controls open it, and WindowManager routes its frame through the existing global click capture. A one-second metadata poll refreshes imported files while the browser is open, avoiding file-descriptor lifecycle problems when shells replace history files.

**Tech Stack:** Swift 6, SwiftUI, AppKit, CryptoKit, DispatchSourceTimer, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-07-quake-terminal-history-design.md`

## Global Constraints

- Keep the existing macOS 15 minimum and add no package dependencies.
- Read only `~/.zsh_history`, `~/.bash_history`, and `~/.local/share/fish/fish_history`.
- Never edit shell startup files, run commands, or insert commands into the terminal.
- Persist history and organization metadata in `~/.config/alwm/terminal-history.json` using atomic replacement.
- Preserve repeated commands as separate entries and retain imported entries when a source file is missing or unreadable.
- Add every visible string to all app locales in `Packages/AlwmShared/Sources/AlwmL10n/L10nTables.swift`.
- While history is open, consume all outside mouse clicks, suppress ALWM hotkeys, and close only through its close control or Escape; leave macOS shortcuts such as Command-Tab to the system.
- Do not stage `.agents/` or `skills-lock.json`.

## Review Focus

- A missing or unreadable history file must preserve existing entries and show a source status; pin this in `TerminalHistoryStoreTests.missingSourceDoesNotDeleteImportedEntries` and `TerminalHistoryStoreTests.unreadableSourceKeepsLastGoodState`.
- A source that changes during a read must be retried once; if it remains unstable, the last good imported state must stay intact. Pin this in `TerminalHistoryStoreTests.changedSourceRetriesOnce` and `TerminalHistoryStoreTests.unstableReadKeepsLastGoodState`.
- Repeated identical commands must survive parsing and re-import without collapsing or multiplying; pin this in `TerminalHistoryImporterTests.repeatedCommandsHaveDistinctStableIDs` and `TerminalHistoryStoreTests.repeatedRefreshIsIdempotent`.
- Malformed or escaped shell records must not corrupt neighboring records; pin this in the zsh, bash, and fish parser tests in `TerminalHistoryImporterTests`.
- Outside clicks and unrelated ALWM hotkeys must not dismiss or escape the modal browser; pin this in `TerminalHistoryOverlayTests.historyFrameIsTheOnlyInteractiveFrame` and `OverlayToggleHotkeyTests.modalCaptureSuppressesAppHotkeys`.
- A persistence error must leave the in-memory browser usable and report the failure; pin this in `TerminalHistoryStoreTests.writeFailureKeepsInMemoryChanges`.

---

## File Map

- Create `Sources/Alwm/TerminalHistory/TerminalHistoryModels.swift` for source, entry, category, document, source status, and filter values.
- Create `Sources/Alwm/TerminalHistory/TerminalHistoryImporter.swift` for standard source discovery, shell parsing, and deterministic entry identities.
- Create `Sources/Alwm/TerminalHistory/TerminalHistoryStore.swift` for atomic persistence, merge semantics, categories, favorites, and filtering.
- Create `Sources/Alwm/TerminalHistory/TerminalHistoryFileWatcher.swift` for polling source metadata while the browser is open.
- Create `Sources/Alwm/UI/TerminalHistoryView.swift` for search, filters, entries, category editing, statuses, and Escape handling.
- Create `Sources/Alwm/UI/TerminalHistoryWindowController.swift` for the key-capable history panel, presentation, and AX-coordinate frame.
- Modify `Sources/Alwm/UI/QuakeTerminal.swift` and `Sources/Alwm/Notes/QuakePanelGeometry.swift` to add the History control beside Expand.
- Modify `Sources/Alwm/Controller/WindowManager/WindowManager.swift` and `Sources/Alwm/Controller/WindowManager/WindowManager+Overlays.swift` to own, present, focus-capture, and close history.
- Modify `Sources/Alwm/Input/HotkeyManager.swift` to add modal keyboard capture that suppresses ALWM hotkeys while leaving system shortcuts untouched.
- Modify `Packages/AlwmShared/Sources/AlwmL10n/L10nTables.swift` for English, Chinese (Simplified), Hindi, Spanish, French, Arabic, Bengali, Portuguese (Brazil), Russian, and Urdu.
- Create `Tests/AlwmTests/TerminalHistoryImporterTests.swift`, `TerminalHistoryStoreTests.swift`, `TerminalHistoryOverlayTests.swift`, and `TerminalHistoryLocalizationTests.swift`; extend `Tests/AlwmTests/OverlayToggleHotkeyTests.swift` and `QuakeDismissButtonTests.swift` for modal capture and the Quake button.

## Interfaces

- `TerminalHistoryShell: String, Codable, CaseIterable` has `zsh`, `bash`, and `fish` cases.
- `TerminalHistorySource` contains `shell` and `url`; its stable identifier is the shell name plus the standardized source path.
- `TerminalHistoryEntry` contains `id`, `command`, `shell`, `sourcePath`, optional `occurredAt`, `isFavorite`, and optional `categoryID`.
- `TerminalHistoryCategory` contains a stable `UUID` and editable `name`.
- `TerminalHistoryFilter` contains `query`, optional `shell`, `startDate`, `endDate`, `favoritesOnly`, and optional `categoryID`. Date bounds are inclusive by local calendar day; entries without shell timestamps remain visible only when both bounds are unset.
- `TerminalHistoryImporter.standardSources(homeDirectory:)` returns the three standard sources. `TerminalHistoryImporter.parse(data:source:)` returns ordered, uniquely identified records, hashing shell, standardized path, exact command, timestamp, and duplicate occurrence ordinal with CryptoKit SHA-256.
- `TerminalHistorySourceReader` is an injectable `(URL) throws -> Data` closure used by `@MainActor TerminalHistoryStore(fileURL:sources:readSource:)` to make stable-read retry behavior deterministic in tests. The store exposes read-only `entries`, `categories`, and `sourceStatuses`, plus `refresh()`, `filteredEntries(matching:)`, `toggleFavorite(entryID:)`, `assignCategory(_:to:)`, `createCategory(name:)`, `renameCategory(id:name:)`, `removeCategory(id:)`, `startWatching()`, and `stopWatching()`.
- `TerminalHistoryStore.defaultFileURL(homeDirectory:)` resolves to `<home>/.config/alwm/terminal-history.json`. Its initializer is `init(fileURL: URL? = nil, sources: [TerminalHistorySource]? = nil, readSource: TerminalHistorySourceReader = { try Data(contentsOf: $0) })`; `nil` resolves to the default path and the three standard sources under the current home directory.
- `TerminalHistoryStore.filteredEntries(matching:)` uses localized case-insensitive substring matching. Results sort by shell timestamp descending; undated entries follow dated entries, with stable ties by shell then ID.
- `TerminalHistoryFileWatcher(sources:pollInterval:onChange:)` fingerprints source size and modification date and calls `onChange` when a source appears, disappears, or changes. Production uses a one-second interval; tests inject a shorter interval.
- `@MainActor TerminalHistoryWindowController(store:)` exposes `isVisible`, `visibleAXFrame`, `show()`, `close()`, and `onVisibilityChanged`; it starts refresh/watching on show and stops watching on close.
- `QuakeTerminalController.onOpenHistory` opens the controller. While history is visible, WindowManager reports only the history frame as interactive and calls `HotkeyManager.setModalKeyboardCapture(true)`; modal state suppresses every ALWM action and survives hotkey reconfiguration until close.

## Tasks

### Task 1: Shell history models and parser

**Files:**
- Create: `Sources/Alwm/TerminalHistory/TerminalHistoryModels.swift`
- Create: `Sources/Alwm/TerminalHistory/TerminalHistoryImporter.swift`
- Test: `Tests/AlwmTests/TerminalHistoryImporterTests.swift`

**Interfaces:**
- Produces the shell, source, entry, category, and source-status types above.
- Produces `TerminalHistoryImporter.standardSources(homeDirectory:)` and `parse(data:source:)` for later tasks.

- [ ] **Step 1: Write failing parser tests** named `zshExtendedHistoryKeepsTimestampAndEscapedCommand`, `bashTimestampBelongsToFollowingCommand`, `fishCmdAndWhenRecordsKeepTimestamp`, `malformedRecordsAreSkippedIndividually`, and `repeatedCommandsHaveDistinctStableIDs`.
- [ ] **Step 2: Run `swift test --filter TerminalHistoryImporterTests`** and confirm the new tests fail because the parser types are absent.
- [ ] **Step 3: Implement the models and parser.** Parse zsh extended and plain records, bash timestamp markers and plain lines, and fish `cmd`/`when` records. Skip malformed records individually. Preserve file order and derive IDs using SHA-256 from the interface definition.
- [ ] **Step 4: Run `swift test --filter TerminalHistoryImporterTests`** and confirm every parser test passes.

### Task 2: Local history store, merge, and filters

**Files:**
- Create: `Sources/Alwm/TerminalHistory/TerminalHistoryStore.swift`
- Test: `Tests/AlwmTests/TerminalHistoryStoreTests.swift`

**Interfaces:**
- Consumes the source and entry types from Task 1.
- Produces `TerminalHistoryFilter` and the store API listed above.

- [ ] **Step 1: Write failing store tests** named `repeatedRefreshIsIdempotent`, `favoriteAndCategorySurviveRefresh`, `missingSourceDoesNotDeleteImportedEntries`, `unreadableSourceKeepsLastGoodState`, `changedSourceRetriesOnce`, `unstableReadKeepsLastGoodState`, `searchAndCombinedFiltersReturnExpectedEntries`, `removingCategoryClearsAssignmentsWithoutDeletingHistory`, and `writeFailureKeepsInMemoryChanges`. The combined-filter test also asserts localized case-insensitive search and timestamp ordering.
- [ ] **Step 2: Run `swift test --filter TerminalHistoryStoreTests`** and confirm the tests fail because the store is absent.
- [ ] **Step 3: Implement `TerminalHistoryStore`.** Load schema-versioned JSON from the injected URL, compare source fingerprints before and after each read, retry once if a source changes, merge stable imports by entry ID without replacing favorite/category values, retain entries whose sources disappear, apply shell/date/favorite/category/search filters, and write changes with `Data.write(options: .atomic)`. Keep the in-memory document usable if persistence fails or a second read remains unstable, and expose per-source status.
- [ ] **Step 4: Run `swift test --filter TerminalHistoryStoreTests`** and confirm persistence and filter tests pass.

### Task 3: Source refresh watcher and history window

**Files:**
- Create: `Sources/Alwm/TerminalHistory/TerminalHistoryFileWatcher.swift`
- Create: `Sources/Alwm/UI/TerminalHistoryView.swift`
- Create: `Sources/Alwm/UI/TerminalHistoryWindowController.swift`
- Test: `Tests/AlwmTests/TerminalHistoryOverlayTests.swift`

**Interfaces:**
- Consumes `TerminalHistoryStore` from Task 2.
- Produces a closeable key window with a `visibleAXFrame` in the same top-left coordinate system used by `OverlayClickCapture`.

- [ ] **Step 1: Write failing tests** named `sourceChangesRefreshWhileHistoryIsOpen`, `historyPanelBecomesKeyAndCloseHidesIt`, `escapeClosesHistory`, and `dateBoundsExcludeEntriesWithoutShellTimestamps`.
- [ ] **Step 2: Run the new tests** with `swift test --filter TerminalHistoryOverlayTests` and confirm they fail because the watcher and window are absent.
- [ ] **Step 3: Implement the watcher and window.** Poll source file size and modification date once per second while visible; refresh only when a source fingerprint changes. Re-scan on show, present a floating key-capable `NSPanel`, show unavailable/read/write status, provide shell selection plus inclusive local-day start/end date pickers, render command text as selectable content, and support favorites and category create/rename/remove/assignment. Escape and the close control call `close()`; closing stops the watcher.
- [ ] **Step 4: Run `swift test --filter TerminalHistoryOverlayTests`** and confirm the watcher and controller tests pass.

### Task 4: Quake History button and modal input capture

**Files:**
- Modify: `Sources/Alwm/UI/QuakeTerminal.swift`
- Modify: `Sources/Alwm/Notes/QuakePanelGeometry.swift`
- Modify: `Sources/Alwm/Controller/WindowManager/WindowManager.swift`
- Modify: `Sources/Alwm/Controller/WindowManager/WindowManager+Overlays.swift`
- Modify: `Sources/Alwm/Input/HotkeyManager.swift`
- Test: `Tests/AlwmTests/QuakeDismissButtonTests.swift`
- Test: `Tests/AlwmTests/OverlayToggleHotkeyTests.swift`
- Test: `Tests/AlwmTests/TerminalHistoryOverlayTests.swift`

**Interfaces:**
- Consumes `TerminalHistoryWindowController` from Task 3.
- Adds `QuakeTerminalController.onOpenHistory`, `HotkeyManager.setModalKeyboardCapture(_:)`, and an overlay-frame policy that returns only the history frame while the modal is visible.

- [ ] **Step 1: Write failing tests** named `quakeChromeShowsHistoryBesideExpand`, `historyFrameIsTheOnlyInteractiveFrame`, `outsideClicksStayConsumedWithoutClosingHistory`, `modalCaptureSuppressesAppHotkeysAndRestoresThemOnClose`, `modalCaptureSurvivesHotkeyReconfiguration`, and `modalCaptureLeavesCommandTabUnbound`.
- [ ] **Step 2: Run the focused tests** with `swift test --filter 'QuakeDismissButtonTests|OverlayToggleHotkeyTests|TerminalHistoryOverlayTests'` and confirm the button and modal assertions fail.
- [ ] **Step 3: Wire the History button and modal state.** Increase the control width for three buttons, open the history controller from Quake, include history in `overlaysCaptureFocus`, return only its frame from `overlayClickCaptureFrames()` while open, keep `dismissOnClickOutside` false for history, and suppress configurable ALWM actions while modal capture is active. The system retains Command-Tab because ALWM does not register it.
- [ ] **Step 4: Run the focused tests** with the same command and confirm button, click-capture, and hotkey assertions pass.

### Task 5: Localize the history interface

**Files:**
- Modify: `Packages/AlwmShared/Sources/AlwmL10n/L10nTables.swift`
- Test: `Tests/AlwmTests/TerminalHistoryLocalizationTests.swift`

**Interfaces:**
- Adds the `terminal.history.*` keys consumed by the view from Task 3: `button`, `title`, `close`, `search`, `shell`, `shell.all`, `date.from`, `date.to`, `date.clear`, `favorites`, `category`, `category.all`, `category.uncategorized`, `category.add`, `category.rename`, `category.remove`, `category.name.placeholder`, `results.count`, `empty`, `source.unavailable`, `source.unreadable`, `persistence.failed`, `favorite.add`, and `favorite.remove`.

- [ ] **Step 1: Write a failing locale coverage test** named `everyAppLocaleHasEveryTerminalHistoryString`; it collects English keys with the `terminal.history.` prefix and asserts that Chinese (Simplified), Hindi, Spanish, French, Arabic, Bengali, Portuguese (Brazil), Russian, and Urdu each define every key.
- [ ] **Step 2: Run `swift test --filter TerminalHistoryLocalizationTests`** and confirm it reports missing translations.
- [ ] **Step 3: Add translations** for every `terminal.history.*` key listed in the Interfaces block in all nine non-English app locale tables. Preserve the `%d` placeholder in `terminal.history.results.count` in every locale.
- [ ] **Step 4: Run `swift test --filter TerminalHistoryLocalizationTests`** and confirm every locale has every visible string.

### Task 6: Full verification, package, version bump, commit, and synchronization

**Files:**
- Verify all files changed in Tasks 1–5 plus the already implemented Notepad dismissal fix in `Sources/Alwm/Notes/NotepadController.swift`, `Sources/Alwm/Controller/WindowManager/WindowManager+Overlays.swift`, and `Tests/AlwmTests/OverlayToggleHotkeyTests.swift`.

- [ ] **Step 1: Run the full suite** with `swift test` and resolve every failure.
- [ ] **Step 2: Check whitespace and localization coverage** with `git diff --check` and `swift test --filter 'TerminalHistoryLocalizationTests|NotepadLocalizationTests'`.
- [ ] **Step 3: Run the version bump** with `bash scripts/bump-version.sh "Add searchable Quake terminal history" "Keep Notepad focus captured through its closing animation"`.
- [ ] **Step 4: Build/package** with `bash scripts/package.sh` and confirm it completes successfully for the bumped version.
- [ ] **Step 5: Verify release readiness** with `bash scripts/verify-release-ready.sh`.
- [ ] **Step 6: Commit the complete implementation once** so the repository pre-commit hook creates only one version bump; keep `.agents/` and `skills-lock.json` untracked and unstaged.
- [ ] **Step 7: Verify version and synchronize.** Run `bash scripts/verify-version-bump.sh origin/main HEAD`, then `bash scripts/sync-push.sh`; confirm `git rev-list --left-right --count HEAD...origin/main` returns `0 0` and `git diff --quiet && git diff --cached --quiet` succeeds.

## Self-Review

- **Spec coverage:** parser formats, duplicates, stable IDs, local JSON, atomic writes, idempotent merge, retained entries, statuses, filters, favorites, categories, source refresh, Quake button, modal outside-click capture, Escape/close, every locale, and release checks each have a task and focused tests.
- **Step scan:** every task follows failing test → red confirmation → implementation → green confirmation; release operations are grouped after all behavior checks. The plan uses one versioned implementation commit because the repository pre-commit hook bumps version metadata for code commits.
- **Type consistency:** model/importer types feed the store; the store feeds the watcher and window; the window frame and visibility feed WindowManager; the Quake callback opens that controller; localization keys use one prefix in both view and test.
- **Review focus:** missing/unreadable sources, duplicate imports, malformed shell records, modal click/hotkey leakage, and persistence errors are covered in the owning test tasks.
- **Proportion:** the plan separates parser, store, watcher/window, overlay integration, localization, and release into six independently checkable tasks without prescribing implementation bodies beyond format and interface decisions made by the approved spec.
