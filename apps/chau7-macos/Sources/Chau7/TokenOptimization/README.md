# TokenOptimization

Command Token Optimization (CTO) -- intercepts CLI output to reduce token usage when AI coding tools read terminal content. Wrapper scripts shadow real binaries via PATH prepend; an optimizer binary rewrites verbose output into compact summaries.

## Files

| File | Purpose |
|------|---------|
| `CTOManager.swift` | Manages wrapper scripts, optimizer binary, PATH injection, and token-savings stats |
| `CTOFlagManager.swift` | Per-session flag files that activate/deactivate optimization; also extends `TokenOptimizationMode` with display names |
| `CTORuntimeMonitor.swift` | Runtime diagnostics: decision counts, deferred flushes, session tracking, debug summary |
| `CTONotifications.swift` | Notification names for mode changes and flag recalculations |

## Key Types

- `CTOManager` -- singleton that generates wrapper scripts in `~/.chau7/cto_bin/`, installs the `chau7-optim` optimizer, and prepends the wrapper directory to PATH
- `CTOFlagManager` -- enum with static methods for flag file CRUD in `~/.chau7/cto_active/`; `recalculate()` decides whether a session should be active based on global mode, per-tab override, and AI detection state
- `CTORuntimeMonitor` -- singleton tracking decision history, deferred activations, and per-session state for the debug console

## Architecture

1. Shell launch: `CTOManager` prepends `~/.chau7/cto_bin/` to PATH
2. Flag creation deferred until first prompt (avoids interfering with shell init)
3. `TerminalSessionModel.recalculateCTOFlag()` calls `CTOFlagManager.recalculate()` on `activeAppName` changes
4. Wrapper scripts check flag file existence; when active, route through `chau7-optim`

## Dependencies

- **Uses:** Chau7Core (TokenOptimizationMode, TabTokenOptOverride, RuntimeIsolation, Log)
- **Used by:** Terminal/Session (flag lifecycle), Settings (mode picker), Overlay (bolt icon)
