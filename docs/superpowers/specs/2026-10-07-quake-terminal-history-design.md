# Quake Terminal History Design

## Goal

Add a history browser to the Quake terminal that imports saved command history from all local zsh, bash, and fish sessions, supports search and organization, and retains mouse focus until the history window is explicitly closed.

## Approved scope

- Add a History button beside the existing Quake expand control.
- Import existing and newly saved entries from the standard history files for zsh, bash, and fish.
- Preserve repeated commands as separate history occurrences.
- Search and filter by shell, date when available, favorite state, and category.
- Favorite entries and organize them into user-created categories.
- Keep imported commands and organization metadata in a local ALWM data file.
- Keep the history window open when clicks occur outside it; close it only through its close button or Escape.
- Pause ALWM hotkeys while the history window is open; leave macOS system shortcuts such as Command-Tab available.
- Localize new visible strings for all supported app languages.

## Existing context

ALWM adopts a window from Ghostty or Terminal.app as the Quake terminal. The terminal itself is an external app window. ALWM currently displays a small accessory panel from `QuakeTerminalController` with expand and dismiss controls. `OverlayClickCapture` already uses a global mouse event tap to consume clicks outside visible overlays, and Input Monitoring is an existing required permission.

The app does not currently embed a shell or expose a command stream. It writes Ghostty appearance settings, but does not inject shell hooks or modify shell startup files. History therefore comes from shell-persisted files rather than terminal scrollback or keystroke capture.

## Sources and import behavior

The first implementation reads these standard per-user history files when present:

| Shell | Default history file |
| --- | --- |
| zsh | `~/.zsh_history` |
| bash | `~/.bash_history` |
| fish | `~/.local/share/fish/fish_history` |

The importer scans when the history window first opens and checks each source file's size and modification time once per second while the window is open. A changed source is re-read and merged. If a shell only writes its history at process exit, its new commands appear after the file is flushed. ALWM does not modify `.zshrc`, `.bashrc`, fish configuration, or terminal settings to force more frequent writes.

The importer supports the common formats emitted by these shell history files:

- zsh extended history records, including optional epoch and duration fields, and plain command lines where available;
- bash timestamp marker lines and plain command lines;
- fish `cmd` records with optional `when` timestamps.

Parsing errors in an individual line do not discard other valid records. Missing or unreadable files do not delete entries already imported. Standard paths only are included initially; custom history locations and other shells are outside this scope.

## Data model and persistence

Create a focused terminal-history module with three responsibilities:

1. **Models:** history entries, source shell, user categories, and persisted document version.
2. **Importer:** discover standard files, parse supported formats, and produce source records.
3. **Store:** merge imports idempotently, persist the local document, and expose filtering and organization operations to the UI.

Each history entry contains a stable identity, command text, source shell, source file identity, optional shell timestamp, favorite state, and optional category identity. Derive its identity from the shell, canonical source path, exact command, optional source timestamp, and occurrence ordinal among records with the same signature. This preserves repeated identical commands as distinct occurrences and makes a repeated scan idempotent. Importing new entries must preserve existing favorite and category assignments. Imported entries are retained if a source file later disappears or becomes unreadable.

Categories have stable IDs and user-editable names. An entry can belong to one category at a time. Removing a category clears that category assignment from its entries without deleting history. Favorite state is independent of category assignment.

Store the imported entries and organization metadata in `~/.config/alwm/terminal-history.json`, using atomic writes. The file is local to the user account; commands are not sent to a service or executed by ALWM. The history UI presents commands as selectable text and does not add a run-command action.

## History window and focus behavior

Add a dedicated ALWM history window controller and SwiftUI view. The Quake accessory panel gains a History button next to expand. Activating it opens and focuses the history window, which provides:

- a text search field;
- shell, date, favorite, and category filters. Date filtering uses optional start and end dates, inclusive by local calendar day. Entries without timestamps remain visible only when both date bounds are unset;
- a total result count;
- favorite toggles and category assignment for each entry;
- category creation, renaming, and removal;
- a close button and Escape handling.

While the history window is visible, WindowManager treats it as a modal overlay that captures focus. `OverlayClickCapture` receives the history window's frame as the sole interactive frame and consumes clicks outside that frame without dismissing the window. ALWM hotkeys are paused while the history window is open. Closing the history window restores the normal Quake and Notepad click-capture frames and focus behavior. System shortcuts such as Command-Tab remain available.

Date filters operate on entries with a shell-provided timestamp. Entries without timestamps are not assigned an invented date; they remain visible when no date filter is selected.

## Failure handling

- An absent shell history file is shown as unavailable and is retried on the next refresh.
- An unreadable source produces a non-blocking status in the history window; previously imported entries remain intact.
- Malformed lines are skipped individually and do not stop parsing the rest of a source.
- If a file changes during a read, retry the import once; keep the last good imported state if the retry fails.
- Store write failures leave the last in-memory view usable and show a persistence status in the window.

## Localization

Add new button, window, filter, category, favorite, empty-state, and source-status strings to every supported app locale in `L10nTables`. Keep shell names and command text as data, not translated UI labels.

## Test strategy

Add focused tests for:

- parsing zsh, bash, and fish fixtures, including timestamps, multiline/escaped content where the format supports it, and malformed lines;
- retaining duplicate commands while making repeated imports idempotent;
- merging file updates without losing favorite/category metadata;
- favorite and category persistence, category removal, search, and combined filters;
- missing and unreadable sources preserving prior history;
- click-capture policy blocking clicks outside the history frame and restoring Quake behavior on close;
- the Quake History button opening the history controller;
- presence of the new UI strings in all supported locales.

Run the focused history tests and the full `swift test` suite, then run the project build/package validation before reporting completion.

## Out of scope

- Editing or adding shell startup hooks to capture commands before the shell saves them.
- Reading arbitrary custom `HISTFILE` paths or supporting shells other than zsh, bash, and fish.
- Executing or automatically inserting a history command into the terminal.
- Deleting individual imported history entries.
- Blocking system shortcuts or keyboard interaction with other apps.
