#!/usr/bin/env python3
"""Phase 1: Replace em dashes in feature-data.json per BRANDING.md rules.

Rules:
- Elaboration (X — Y explanation): use colon → "X: Y"
- Pause/aside: use ellipsis or comma
- Two separate thoughts: split into sentences
- Never introduce new em dashes
"""

import json, re, sys

DATA_FILE = "feature-data.json"

# ── Specific replacements found by manual review ──────────────
# Each tuple: (old_substring, new_substring)
# Organized by pattern type for clarity

REPLACEMENTS = [
    # === ELABORATION → COLON ===
    # "X — Y" where Y explains/elaborates X

    # detection-status-indicator
    ("Active, idle, or done — see it on the tab.", "Active, idle, or done: see it on the tab."),

    # mcp-tools meta_desc
    ("giving AI agents full terminal control — tab creation", "giving AI agents full terminal control: tab creation"),

    # unix-socket-server short_desc
    ("Unix socket — no network exposure", "Unix socket: no network exposure"),

    # unix-socket-server why_matters
    ("A network-exposed MCP server would be a security liability — any process", "A network-exposed MCP server would be a security liability. Any process"),

    # auto-registration how_it_works
    ("The registration is idempotent — running it multiple times", "The registration is idempotent: running it multiple times"),

    # mcp-resources why_matters
    ("Agents frequently need to inspect terminal state as part of planning — checking", "Agents frequently need to inspect terminal state as part of planning: checking"),

    # mcp-resources how_it_works
    ("Resources are useful for agents that need to understand context before acting. An agent planning a multi-step workflow — say", "Resources are useful for agents that need to understand context before acting. An agent planning a multi-step workflow, say"),

    # enable-disable-toggle short_desc
    ("Turn the MCP server on or off — when disabled", "Turn the MCP server on or off. When disabled"),

    # enable-disable-toggle how_it_works (if present)
    ("When MCP is disabled, Chau7 does not create the Unix socket at all — there is no listening endpoint", "When MCP is disabled, Chau7 does not create the Unix socket at all. There is no listening endpoint"),

    # mcp-approval-gate faq
    ("the approval gate is about MCP tool calls — actions initiated by an external AI agent", "the approval gate is about MCP tool calls: actions initiated by an external AI agent"),

    # context-token-optimization
    ("Context Token Optimization — reducing", "Context Token Optimization: reducing"),
    ("CTO mode — Chau7 rewrites", "CTO mode: Chau7 rewrites"),
    ("CTO is a terminal-level optimization — it modifies", "CTO is a terminal-level optimization. It modifies"),

    # cost-tracking
    ("pricing tables — input tokens", "pricing tables: input tokens"),

    # latency-tracking
    ("Latency tracking captures two key metrics — time-to-first-token", "Latency tracking captures two key metrics: time-to-first-token"),

    # tls-wss-proxy
    ("Chau7 runs a transparent TLS proxy on localhost — when an AI", "Chau7 runs a transparent TLS proxy on localhost. When an AI"),
    ("The proxy handles both HTTPS and WebSocket Secure (WSS) connections — covering REST", "The proxy handles both HTTPS and WebSocket Secure (WSS) connections, covering REST"),
    ("transparent to the calling tool — the proxy", "transparent to the calling tool. The proxy"),

    # analytics-dashboard
    ("grouping — daily", "grouping: daily"),
    ("analytics system — it queries", "analytics system. It queries"),
    ("into a retention-limited store — queryable", "into a retention-limited store, queryable"),

    # metal-rendering
    ("native macOS GPU API — Metal", "native macOS GPU API: Metal"),
    ("glyph atlas — a texture", "glyph atlas, a texture"),
    ("atlas cache — subsequent", "atlas cache. Subsequent"),

    # iosurface-display
    ("direct to the display — bypassing", "direct to the display, bypassing"),
    ("buffer directly — the", "buffer directly. The"),

    # simd-parsing
    ("16-32 bytes at a time — not", "16-32 bytes at a time, not"),
    ("intrinsics — the specific", "intrinsics. The specific"),
    ("runs in Rust — memory-safe", "runs in Rust, memory-safe"),

    # iokit-hid-input
    ("IOKit HID subsystem — below", "IOKit HID subsystem, below"),
    ("entire queue — delivering", "entire queue, delivering"),
    ("measurable — typically", "measurable, typically"),

    # triple-buffering
    ("three screen-sized buffers — front", "three screen-sized buffers: front"),
    ("front, back, and pending — and rotates", "front, back, and pending, and rotates"),

    # lock-free-spsc-buffer
    ("SPSC — single-producer", "SPSC (single-producer"),
    ("single-consumer — ring buffer", "single-consumer) ring buffer"),
    ("no kernel transitions — the reader", "no kernel transitions. The reader"),

    # background-suspension
    ("background tabs are fully suspended — no render cycles", "background tabs are fully suspended: no render cycles"),
    ("timer coalescing — macOS", "timer coalescing. macOS"),

    # dirty-region-tracking
    ("only the cells that changed — not", "only the cells that changed, not"),
    ("a frame — Chau7 computes", "a frame, Chau7 computes"),

    # glyph-atlas
    ("a GPU-resident texture atlas — a single", "a GPU-resident texture atlas, a single"),
    ("pre-rasterized glyphs — each", "pre-rasterized glyphs. Each"),
    ("atlas is persistent — once", "atlas is persistent. Once"),

    # cursor-rendering
    ("cursor rendering — the cursor", "cursor rendering. The cursor"),

    # vt100-xterm-emulation
    ("VT100 and xterm escape sequences — including", "VT100 and xterm escape sequences, including"),

    # unicode-emoji-support
    ("Unicode — including CJK", "Unicode, including CJK"),
    ("the grapheme-cluster level — correctly", "the grapheme-cluster level, correctly"),

    # shell-integration
    ("deep integration with popular shells — zsh", "deep integration with popular shells: zsh"),

    # scrollback-buffer
    ("a configurable scrollback buffer — the number", "a configurable scrollback buffer. The number"),

    # hyperlinks
    ("OSC 8 hyperlinks — clickable", "OSC 8 hyperlinks: clickable"),

    # multi-tab
    ("unlimited terminal tabs — each", "unlimited terminal tabs. Each"),
    ("tab-specific title — useful", "tab-specific title, useful"),

    # split-panes
    ("horizontal and vertical splits — within", "horizontal and vertical splits within"),

    # tab-drag-drop
    ("between tab positions — including", "between tab positions, including"),
    ("positions — snapping", "positions, snapping"),
    ("snap-to-position behavior — no", "snap-to-position behavior. No"),

    # tab-pinning
    ("locked to the left — they", "locked to the left. They"),

    # window-title-sync
    ("terminal window title — reflecting", "terminal window title, reflecting"),

    # themes-color-schemes
    ("ships with curated color schemes — and lets", "ships with curated color schemes and lets"),

    # font-config
    ("a dedicated font configuration panel — select", "a dedicated font configuration panel. Select"),

    # key-binding-customization
    ("every keyboard shortcut is customizable — override", "every keyboard shortcut is customizable. Override"),

    # background-opacity
    ("window background opacity — from", "window background opacity, from"),

    # cursor-customization
    ("cursor appearance — shape", "cursor appearance: shape"),

    # iterm2-profile-import
    ("imports your existing iTerm2 profiles — including", "imports your existing iTerm2 profiles, including"),

    # ssh-connection-manager
    ("visual SSH connection manager — store", "visual SSH connection manager. Store"),

    # ssh-key-management
    ("SSH keys — tracking", "SSH keys, tracking"),

    # ssh-agent-forwarding
    ("SSH agent forwarding — your", "SSH agent forwarding. Your"),

    # ssh-port-forwarding
    ("local and remote port forwards — configured", "local and remote port forwards, configured"),

    # mosh-support
    ("Mosh — a UDP-based", "Mosh (a UDP-based"),

    # built-in-editor
    ("a built-in text editor — edit", "a built-in text editor. Edit"),
    ("editor — without", "editor, without"),

    # syntax-highlighting
    ("built-in syntax highlighting — code", "built-in syntax highlighting. Code"),

    # mini-editor-mode
    ("a lightweight editor mode — edit", "a lightweight editor mode. Edit"),
    ("without a full editor — inline", "without a full editor, inline"),

    # dangerous-command-guard
    ("intercepts dangerous commands — rm -rf", "intercepts dangerous commands: rm -rf"),
    ("commands — with a confirmation", "commands, with a confirmation"),
    ("The guard pattern list — including", "The guard pattern list, including"),

    # paste-confirmation
    ("before pasting multi-line content — preventing", "before pasting multi-line content, preventing"),

    # mcp-approval-gate
    ("optional approval gate — MCP", "optional approval gate. MCP"),

    # process-exit-confirmation
    ("warns before closing a tab — if", "warns before closing a tab if"),

    # voiceover-support
    ("full VoiceOver support — terminal", "full VoiceOver support. Terminal"),

    # reduced-motion
    ("macOS Reduce Motion preference — all", "macOS Reduce Motion preference. All"),

    # high-contrast-mode
    ("macOS High Contrast setting — enhancing", "macOS High Contrast setting, enhancing"),

    # clipboard-write/read
    ("terminal clipboard integration — copy", "terminal clipboard integration. Copy"),
    ("terminal clipboard integration — paste", "terminal clipboard integration. Paste"),

    # osc52-clipboard
    ("OSC 52 clipboard — remote", "OSC 52 clipboard. Remote"),

    # session-restore
    ("session restore — reopen", "session restore. Reopen"),

    # session-recording
    ("records terminal sessions — every", "records terminal sessions. Every"),

    # terminal-search
    ("search within terminal output — with", "search within terminal output with"),

    # url-detection
    ("detects URLs in terminal output — clickable", "detects URLs in terminal output. Clickable"),

    # command-palette
    ("Cmd+Shift+P — fuzzy-searchable", "Cmd+Shift+P: fuzzy-searchable"),

    # json-rpc-api
    ("JSON-RPC API — programmatic", "JSON-RPC API for programmatic"),

    # applescript-support
    ("AppleScript support — automate", "AppleScript support. Automate"),

    # quick-terminal
    ("system-wide hotkey — summon", "system-wide hotkey. Summon"),
    ("hotkey — a terminal", "hotkey. A terminal"),

    # native-macos-fullscreen
    ("native macOS fullscreen — your", "native macOS fullscreen. Your"),

    # multi-window
    ("multiple independent windows — each", "multiple independent windows. Each"),

    # === CTA patterns: "X — try/download/etc" → "X. Try/Download/etc" ===
    ("— try Chau7", ". Try Chau7"),
    ("— download Chau7", ". Download Chau7"),
    ("— Download Chau7", ". Download Chau7"),
    ("— explore Chau7", ". Explore Chau7"),
    ("— Explore Chau7", ". Explore Chau7"),
    ("— set tab limits", ". Set tab limits"),
    ("— try tab limits", ". Try tab limits"),

    # === FAQ patterns ===
    ("Yes — the tools execute", "Yes, the tools execute"),
    ("Yes — MCP tool calls", "Yes. MCP tool calls"),
    ("No — the approval gate", "No. The approval gate"),
    ("No — CTO operates", "No. CTO operates"),
    ("Yes — Context Token Optimization", "Yes. Context Token Optimization"),
    ("Yes — the proxy handles", "Yes, the proxy handles"),
    ("Yes — the guard pattern", "Yes, the guard pattern"),
    ("No — once disabled", "No. Once disabled"),
    ("No — the MCP server", "No. The MCP server"),
    ("Yes — Chau7 reads", "Yes. Chau7 reads"),

    # Any remaining "— " patterns in CTAs
    ("Give your AI agent a real terminal — try", "Give your AI agent a real terminal. Try"),
    ("Secure by design — try", "Secure by design. Try"),
    ("Zero-config MCP setup — download", "Zero-config MCP setup. Download"),
    ("Safe, read-only terminal access — explore", "Safe, read-only terminal access. Explore"),
    ("Stay in control of your terminal — set", "Stay in control of your terminal. Set"),
    ("Keep track of your AI agent's tabs — try", "Keep track of your AI agent's tabs. Try"),
]

def apply_replacements(text):
    """Apply all known replacements to a string."""
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    return text

def fix_remaining_emdashes(text):
    """Catch any remaining em dashes with a smart fallback."""
    if '—' not in text:
        return text, 0

    count = text.count('—')
    # For remaining cases, use colon as safest default for "X — Y"
    text = re.sub(r'\s*—\s*', ': ', text)
    return text, count

def process_json(data):
    """Walk the entire JSON structure and fix em dashes."""
    total_fixed = 0

    for cat in data["categories"]:
        for feat in cat["features"]:
            for field in ["tagline", "short_desc", "meta_desc", "why_matters", "cta"]:
                if field in feat:
                    old = feat[field]
                    new = apply_replacements(old)
                    if '—' in new:
                        new, remaining = fix_remaining_emdashes(new)
                        if remaining:
                            print(f"  FALLBACK {feat['slug']}.{field}: {remaining} remaining", file=sys.stderr)
                    if old != new:
                        feat[field] = new
                        total_fixed += old.count('—')

            if "how_it_works" in feat:
                for i, p in enumerate(feat["how_it_works"]):
                    old = p
                    new = apply_replacements(old)
                    if '—' in new:
                        new, remaining = fix_remaining_emdashes(new)
                        if remaining:
                            print(f"  FALLBACK {feat['slug']}.how_it_works[{i}]: {remaining} remaining", file=sys.stderr)
                    if old != new:
                        feat["how_it_works"][i] = new
                        total_fixed += old.count('—')

            if "faqs" in feat:
                for j, (q, a) in enumerate(feat["faqs"]):
                    old_q, old_a = q, a
                    new_q = apply_replacements(old_q)
                    new_a = apply_replacements(old_a)
                    if '—' in new_q:
                        new_q, _ = fix_remaining_emdashes(new_q)
                    if '—' in new_a:
                        new_a, remaining = fix_remaining_emdashes(new_a)
                        if remaining:
                            print(f"  FALLBACK {feat['slug']}.faq[{j}].a: {remaining} remaining", file=sys.stderr)
                    if old_q != new_q or old_a != new_a:
                        feat["faqs"][j] = [new_q, new_a]
                        total_fixed += old_q.count('—') + old_a.count('—')

    return total_fixed

# ── Main ──────────────────────────────────────────────
with open(DATA_FILE) as f:
    data = json.load(f)

fixed = process_json(data)

with open(DATA_FILE, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

# Verify
with open(DATA_FILE) as f:
    content = f.read()
remaining = content.count('—')
print(f"Fixed {fixed} em dashes. Remaining in file: {remaining}")
if remaining > 0:
    # Find remaining
    import re as re2
    for i, line in enumerate(content.split('\n'), 1):
        if '—' in line:
            print(f"  Line {i}: {line.strip()[:100]}")
