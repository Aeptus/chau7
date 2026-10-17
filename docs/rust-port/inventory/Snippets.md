# Snippets

Swift: `apps/chau7-macos/Sources/Chau7/Snippets/` (2 files, 2622 lines), plus the picker overlay in `Overlay/Chau7OverlayView.swift` (`SnippetManagerOverlayView`, `SnippetRowView`, `SnippetEditorView`, `SnippetVariableDialog`), insertion in `Terminal/Session/TerminalSessionModel.swift` and `RustBackend/RustTerminalView.swift`, settings in `Settings/Views/ProductivitySettingsView.swift`
Swift tests: `SnippetParsingTests` (Chau7Core logic only; nothing covers `SnippetManager` or the UI)
Wave: 1
Depends on: Repository (git root of the focused tab), Overlay, Settings

Reusable text snippets the user inserts into the focused terminal from a searchable picker. Snippets come from three sources (User, Profile, and the current git repo), can carry tokens (`${cwd}`, `${env:VAR}`), Tab-navigable placeholders and prompted input variables, and are managed from the picker or a dedicated manager window.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SNP-001 | Open/close the snippet picker overlay from a shortcut, the menu or the command palette; Esc closes it and focus returns to the terminal | `Overlay/OverlayTabsModel.swift` (`toggleSnippetManager`), `Overlay/Chau7OverlayView.swift` | | `chau7_next/src/workspace/`, `chau7_next/src/actions/` | done | |
| SNP-002 | Search filters snippets by title, body, tags and folder (case-insensitive substring) | `Snippets/SnippetManager.swift` (`filteredEntries`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-003 | Picker rows show title, source badge (USER/PROFILE/REPO), two-line monospaced body preview, tags, pin icon and an OVERRIDDEN marker | `Overlay/Chau7OverlayView.swift` (`SnippetRowView`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-004 | Click a row (or its insert button) to insert the snippet into the focused terminal and close the picker | `Overlay/Chau7OverlayView.swift`, `Overlay/OverlayTabsModel.swift` (`insertSnippet`) | | `chau7_next/src/workspace/` (`run_picker_item`) | done | |
| SNP-005 | Quick-select letters: with an empty query, pressing a letter inserts the snippet shown with that letter badge; a snippet's own key (a-z) wins, the rest get free letters in order; two snippets claiming one key show an orange badge and "KEY CONFLICT" and neither gets it | `Overlay/Chau7OverlayView.swift` (`buildKeyMap`, `SnippetSearchField`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-006 | Pin or unpin a snippet from its row; pinned snippets sort to the top | `Snippets/SnippetManager.swift` (`togglePin`), `Overlay/Chau7OverlayView.swift` |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-007 | Sort order: pinned first, then source priority (Repo, Profile, User), then title A to Z | `Snippets/SnippetManager.swift` (`mergeEntries`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-008 | User snippets (shown as "User", stored as `global`): one JSON file per snippet in `~/Library/Application Support/Chau7/snippets/global/<id>.json` | `Snippets/SnippetManager.swift` (`globalURL`, `loadSnippetsFromDirectory`, `saveSnippet`) |  | chau7_next_core/src/snippet_store.rs,chau7_next/src/snippets/mod.rs | done |  |
| SNP-009 | Profile snippets source (`snippets/default/`, one file per snippet) | `Snippets/SnippetManager.swift` (`profileURL`) |  | chau7_next_core/src/snippet_store.rs,chau7_next/src/snippets/mod.rs | done |  |
| SNP-010 | Repo snippets: files under `<git root>/<repo snippet path>` (default `.chau7/snippets/`, one JSON per snippet) appear only while the focused tab is in that repo, and switch when the tab's directory or selected tab changes (Rust reads the repo's files only; creating, editing, pinning or deleting a repo snippet writes to its per-repo overlay in its data root, which wins over the repo's files) | `Snippets/SnippetManager.swift` (`updateContextPath`, `repoURL`) |  | crates/chau7_next_core/src/snippet_store.rs | done |  |
| SNP-011 | Same id in several sources: the higher-priority source wins for insertion, the others stay listed with an OVERRIDDEN marker | `Snippets/SnippetManager.swift` (`mergeEntries`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-012 | Snippet edits made on disk show up without restarting (directory watchers, 100 ms debounce; repo snippets of recent repos preloaded) | `Snippets/SnippetManager.swift` (`setupMonitors`, `setupActiveRepoMonitor`) | | `chau7_next/src/workspace/` (reloads files every time the picker filters) | done | |
| SNP-013 | Legacy migration: single-file `global.json`, `default.json` and repo `.chau7/snippets.json` are split into one file per snippet, then the legacy file is deleted (Rust splits its own old `snippets.json`; Swift's `global.json` and `default.json` are imported read only into its store at first launch; a repo's old file is read, never deleted, since Swift migrates it) | `Snippets/SnippetManager.swift` (`migrateIfNeeded`, `migrateSourceIfNeeded`) |  | chau7_next_core/src/snippet_store.rs,chau7_next/src/snippets/mod.rs,chau7_next_core/src/data_root.rs | done |  |
| SNP-014 | Command palette "Migrate Snippets to Clean JSON": rewrites every snippet file pretty-printed, sorted keys, ISO 8601 dates, empty fields omitted (Rust rewrites only its own folders and repo overlays, never a repo's files) | `Snippets/SnippetManager.swift` (`migrateToCleanJSON`), `Commands/CommandPalette.swift` |  | chau7_next_core/src/snippet_store.rs,chau7_next/src/snippets/mod.rs | done |  |
| SNP-015 | Command palette "Reload Snippets": rereads all sources from disk | `Snippets/SnippetManager.swift` (`forceReloadAll`) |  | chau7_next_core/src/snippet_store.rs,chau7_next/src/snippets/mod.rs | done |  |
| SNP-016 | Tokens replaced on insert: `${cwd}` (tab directory), `${home}`, `${date}` (yyyy-MM-dd), `${time}` (HH:mm:ss), `${clip}` (clipboard text) | `Snippets/SnippetManager.swift` (`replaceTokens`) | `SnippetParsingTests` | chau7_next_core/src/snippet_store.rs,chau7_next/src/snippets/mod.rs | done | NSPasteboard |
| SNP-017 | `${env:VAR}` replaced by the app's environment variable (empty if unset) | `Snippets/SnippetManager.swift` (`replaceEnvTokens`) | `SnippetParsingTests` | `chau7_next_core/src/snippet_store.rs` (`prepare_insertion`), `chau7_next_core/src/snippet_parsing.rs` | done | |
| SNP-018 | Tab-stop placeholders `${1:default}` ... `${0}`: text is inserted with defaults, the cursor jumps to placeholder 1, Tab / Shift+Tab move between placeholders, past the last one the cursor goes to `${0}` (or the end); any other key ends navigation; skipped when the text has non-ASCII characters | `Snippets/SnippetManager.swift` (`expandPlaceholders`), `RustBackend/RustTerminalView.swift` (`insertSnippet`, `handleSnippetKeyDown`) | `SnippetParsingTests` | `chau7_next_core/src/snippet_store.rs` (`prepare_insertion`, `Navigation`), `chau7_next/src/terminal/input.rs` (`insert_snippet`, `snippet_key`) | done | |
| SNP-019 | Input variables: before insert, a "Fill in variables" dialog asks for `${input:name}`, `${input:name:default}` (text field), `${input:name:a\|b\|c}` (dropdown, first option preselected) and `${multiselect:name:a\|b\|c}` (checkboxes, chosen values joined by spaces); Enter moves to the next field, Cancel returns to the list | `Snippets/SnippetManager.swift` (`parseInputVariables`, `replaceInputVariables`), `Overlay/Chau7OverlayView.swift` (`SnippetVariableDialog`, `attemptInsert`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs | done |  |
| SNP-020 | Inserted text is wrapped in bracketed paste when the shell turned that mode on | `RustBackend/RustTerminalView.swift` (`insertSnippet`) |  | `chau7_next/src/terminal/input.rs` (`insert_snippet`: bracketed paste) | done |  |
| SNP-021 | Setting: Insert mode "Expand (type)" or "Paste" (paste skips placeholders) | `Settings/Views/ProductivitySettingsView.swift`, `Settings/FeatureSettings.swift` (`snippetInsertMode`) |  | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SNP-022 | Setting: Placeholder navigation on/off (off inserts defaults without Tab stops) | `Settings/Views/ProductivitySettingsView.swift` (`snippetPlaceholdersEnabled`) |  | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SNP-023 | Setting: Enable snippets (off hides all entries and blocks the picker) | `Settings/FeatureSettings.swift` (`isSnippetsEnabled`) |  | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SNP-024 | Settings: Repository snippets on/off and the repo snippet path (relative to the git root, default `.chau7/snippets`) | `Settings/Views/ProductivitySettingsView.swift` (`isRepoSnippetsEnabled`, `repoSnippetPath`) |  | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SNP-025 | Setting: Allow protected folders (repo detection in Downloads, Desktop, Documents), with Grant Access and Open System Settings buttons | `Settings/Views/ProductivitySettingsView.swift` (`allowProtectedFolderAccess`) |  | chau7_next/src/settings_window/mine/productivity.rs | done | TCC (Files and Folders), NSWorkspace |
| SNP-026 | Create or edit a snippet inline in the picker: title, optional id (auto `slug-xxxxxx`), key (a-z), body, tags (comma separated), folder, shells, location (User/Profile/Repo) | `Overlay/Chau7OverlayView.swift` (`SnippetEditorView`), `Snippets/SnippetManager.swift` (`createSnippet`, `updateSnippet`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs | done |  |
| SNP-027 | Delete a snippet from the picker after a confirmation alert | `Overlay/Chau7OverlayView.swift`, `Snippets/SnippetManager.swift` (`deleteSnippet`) |  | chau7_next/src/workspace/pickers/snippets_ui.rs | done |  |
| SNP-028 | Snippets manager window ("Manage Snippets..."): source filter buttons All / User / Repo with counts, search, list with OVERRIDDEN badges, empty states | `Snippets/SnippetsSettingsView.swift` (`SnippetsSettingsView`, `SnippetsSettingsWindowController`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done |  |
| SNP-029 | Manager detail panel: title, source, key badge, body, tags, folder, shells, token and input-variable help, source file path, Insert button (inserts into the active terminal) | `Snippets/SnippetsSettingsView.swift` (`SnippetDetailView`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done |  |
| SNP-030 | Manager editor panel: same fields as SNP-026 plus a repository picker (current repo, recent repos, Choose... folder that must be a git repo); Save disabled until title, body (and repo for Repo) are set | `Snippets/SnippetsSettingsView.swift` (`SnippetEditorPanel`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done | NSOpenPanel |
| SNP-031 | Copy a snippet to User, to the current repo, or to a chosen repo (new id when the file already exists) | `Snippets/SnippetsSettingsView.swift`, `Snippets/SnippetManager.swift` (`duplicateSnippet`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done | NSOpenPanel |
| SNP-032 | Editing a snippet's location or id moves its file (old file deleted, new written; created date kept) | `Snippets/SnippetManager.swift` (`updateSnippet`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done |  |
| SNP-033 | Import snippets from pasted JSON or a file into User or Profile | `Snippets/SnippetsSettingsView.swift` (`ImportExportSheet.performImport`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done | NSOpenPanel |
| SNP-034 | Export one source's snippets as `{version, snippets}` JSON: copy to clipboard or save to `<source>-snippets.json` | `Snippets/SnippetsSettingsView.swift` (`ImportExportSheet.generateExport`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done | NSSavePanel, NSPasteboard |
| SNP-035 | Manager footer: Enable / Repo Snippets / Placeholders switches, snippet count and active repo name | `Snippets/SnippetsSettingsView.swift` (`footerSection`) |  | chau7_next/src/snippets/manager.rs,chau7_next/src/snippets/form.rs | done |  |
| SNP-036 | Picker footer shows the active repo root ("Repo: path") and the hint "Press a letter to quick-insert" | `Overlay/Chau7OverlayView.swift` |  | chau7_next/src/workspace/pickers/snippets_ui.rs,chau7_next_core/src/snippet_store.rs | done |  |
| SNP-037 | Insert a snippet by id from automation (MCP tool, notification action), focusing the target tab first | `Overlay/OverlayTabsModel.swift` (`insertSnippet(id:on:autoExecute:)`), `App/AppDelegate.swift` (`insertSnippetByID`) |  | chau7_next/src/workspace/notifications.rs (insert_snippet_in_tab), chau7_next/src/notifications/routing.rs, chau7_next/src/snippets/manager.rs (insert_selected) | done |  |

## Notes

- **File format.** Swift stores one snippet per file (`<dir>/<id>.json`,
  keys `id, title, body, tags?, folder?, shells?, key?, isPinned?,
  createdAt?, updatedAt?`, dates ISO 8601, legacy dates as a Double since
  2001 still read); Rust uses the same format. Swift deletes a repo's old
  `.chau7/snippets.json` after migrating it (SNP-013); Rust reads both the
  repo folder and the old file, and never writes either (DUAL-SHIP phase 1):
  repo edits go to `DataRoot::repo_overlays_dir()/<repo key>/snippets/`,
  deletions are recorded there in `.deleted.json`.
- Swift user snippets live under
  `~/Library/Application Support/Chau7/snippets/global/` (and `default/`,
  plus the pre-split `global.json` / `default.json`); Rust copies them once
  at first launch (`DataRoot::import_from_swift_app`).
- The "Profile" source is a fixed folder (`snippets/default/`); it does not
  follow the active settings profile (see Profiles.md).
- `shells` is metadata only: Swift never filters snippets by shell.
- Rust search (SNP-002) matches the title and the first body line only, not
  tags or folder; rows show only the first body line.
- The Swift `autoExecute` flag of SNP-037 is accepted but ignored.
- Shortcuts: Swift default is Cmd+Opt+S (`KeyboardShortcut(action: "snippets")`);
  the palette row and the manager header still say Cmd+; ; Rust uses
  Cmd+Shift+S (Ctrl+Shift+S off macOS).
- Settings keys (UserDefaults): `feature.snippetPlaceholders` (default true),
  insert mode default `expand`, repo path default `.chau7/snippets`, snippets
  and repo snippets default on.
