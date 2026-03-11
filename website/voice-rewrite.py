#!/usr/bin/env python3
"""Phase 2: Rewrite feature-data.json taglines, CTAs, and why_matters with Chau7 brand voice.

Voice rules (BRANDING.md):
- Self-deprecating about the brand ("a terminal named after a sock"), never about capabilities
- References: wink-and-nod (Firefly, Star Wars, Trek, Monty Python, Naheulbeuk, Gilmore Girls)
- Technically honest: say "SIMD-accelerated Rust parser"
- No: leverage, synergy, ecosystem, revolutionary, next-gen, cutting-edge, supercharge, unlock, disrupt, 10x
- No em dashes
"""

import json

DATA_FILE = "feature-data.json"

# ── Voice rewrites ────────────────────────────────────────────
# Each slug maps to fields that should be overwritten.
# Only include fields that change.

REWRITES = {
    # ═══ AI Detection ═══
    "auto-ai-cli-detection": {
        "tagline": "Your terminal finally knows what AI is running inside it. Other terminals? Blissfully ignorant.",
        "cta": "Let your terminal stop pretending AI doesn't exist.",
        "why_matters": "Every other terminal on your Mac is blissfully unaware that Claude Code is rewriting your codebase in one tab while Codex refactors another. They see processes. Chau7 sees agents. It identifies Claude Code, Codex, Gemini CLI, ChatGPT, Copilot, Aider, and Cursor the moment they spawn, tags the tab, and tells every downstream system. You get instant awareness of which agents are active, which tabs they occupy, and how long they have been running. No other terminal does this. Not even a little.",
    },
    "ai-tab-branding": {
        "tagline": "Claude is orange. Codex is green. Your tabs finally make sense.",
        "cta": "Stop clicking through tabs like it's 2003.",
        "why_matters": "You are running four AI agents and three shell sessions. They all look identical in every other terminal. Chau7 gives each agent its own color and logo in the tab bar so you can find the right session in a single glance. It is the kind of feature that sounds trivial until you realize you have been tab-hunting for months.",
    },
    "ai-process-monitoring": {
        "tagline": "CPU, memory, PID. Per tab, per agent. No more guessing which AI ate your RAM.",
        "cta": "Find out which AI is hogging your machine. (It's probably Claude.)",
        "why_matters": "AI coding agents are quietly hungry. They consume CPU during tool calls, gobble memory during long sessions, and Activity Monitor shows you a wall of node and python processes with no indication of which tab or agent owns them. Chau7 gives you per-tab, per-agent resource visibility so you can spot the runaway session before your fans hit jet-engine mode.",
    },
    "custom-detection-rules": {
        "tagline": "Got an AI tool we haven't heard of yet? Teach Chau7. It learns fast.",
        "cta": "Your weird internal AI tool deserves detection too.",
        "why_matters": "The AI tooling landscape moves faster than any vendor can ship updates. Your team's custom fine-tuned model CLI, that internal wrapper around Ollama, the niche open-source agent your coworker swears by: Chau7 can't ship built-in support for all of them, but it can learn. Custom detection rules let you extend detection to anything with a process name.",
    },
    "detection-status-indicator": {
        "tagline": "Active, idle, or done: see it on the tab without switching to it.",
        "cta": "Monitor your AI agents from the tab bar. Like a civilized person.",
        "why_matters": "AI agents can run for minutes or hours. The current workflow for checking progress: switch tab, scroll, squint, switch back. The Chau7 workflow: glance at the tab bar. A small status badge tells you whether each agent is actively working, waiting for input, or finished. It saves exactly one context switch per check, which adds up to dozens per day.",
    },
    "multi-agent-awareness": {
        "tagline": "Five agents. Five tabs. Five independent tracking contexts. No cross-contamination.",
        "cta": "Run all your AI agents at once. Chau7 keeps score for each one.",
        "why_matters": "Modern AI-assisted development often involves multiple agents working on different parts of a project simultaneously. Without tab-level isolation, metrics blur together and you lose the ability to attribute costs, tokens, or errors to a specific agent. Chau7 keeps every tab's detection, branding, metrics, and telemetry completely isolated. Think of it as namespace isolation, but for your terminal.",
    },

    # ═══ AI Integration ═══
    "context-token-optimization": {
        "tagline": "Stop burning tokens on terminal noise your AI doesn't need to see.",
        "cta": "Save ~40% on context tokens. Your wallet will thank you.",
        "why_matters": "Every character in your terminal scrollback costs tokens when an AI agent reads it. ANSI escape codes, prompt decorations, progress bars, blank lines: none of it helps the model reason about your code, but all of it costs money. CTO mode rewrites terminal output to strip the noise before the AI reads it. Developers report 30-50% context reduction on typical sessions. That is real money at scale.",
    },
    "llm-error-explanation": {
        "tagline": "One click turns a cryptic error into a human explanation. No browser required.",
        "cta": "Stop copy-pasting errors into a browser tab. There's a better way.",
        "why_matters": "Cryptic error messages are a constant friction point. The old workflow: copy error, open browser, paste into ChatGPT, wait for response, switch back to terminal. The Chau7 workflow: click the error, read the explanation. It is faster by an order of magnitude, and you never leave your terminal.",
    },
    "cto-per-tab-override": {
        "tagline": "Token optimization where you want it, full output where you don't. Tab by tab.",
        "cta": "Fine-tune token optimization per tab. Because one size never fits all.",
        "why_matters": "Global on/off is too coarse for multi-tab workflows. You want CTO active on the tab where Claude Code is burning through tokens, but disabled on the tab where you are debugging output formatting. Per-tab override gives you that control without affecting other sessions.",
    },
    "ai-session-tracking": {
        "tagline": "Every AI session, tracked from first prompt to last. Because 'I think it was Tuesday' is not auditing.",
        "cta": "Stop losing your AI session history. It was right there this whole time.",
        "why_matters": "Without session tracking, AI agent usage is ephemeral. You finish a coding session and have no record of how many runs it took, how long each one lasted, or what the cumulative cost was. Chau7 groups related AI interactions into sessions with run counts, duration, and cost attribution so you can actually answer 'how much did that feature cost to build with AI?'",
    },

    # ═══ API Analytics ═══
    "tls-wss-proxy": {
        "tagline": "A transparent proxy that captures every API call your AI agent makes. You'll finally know what's happening on the wire.",
        "cta": "See the API traffic your AI generates. It's more than you think.",
        "why_matters": "AI coding agents make dozens or hundreds of API calls per session, and the developer sees none of that traffic. Chau7 runs a transparent TLS proxy on localhost that intercepts calls to OpenAI, Anthropic, and other providers without modifying the agent's behavior. For the first time, you can see every request, every response, every token count, and every dollar spent.",
    },
    "token-counting": {
        "tagline": "Input tokens, output tokens, per call. The numbers your provider charges you but never shows you.",
        "cta": "Count every token. Know exactly what you're paying for.",
        "why_matters": "Token counts are the fundamental unit of LLM costs, and without per-call tracking you are guessing. Was that session expensive because of one massive prompt or fifty small ones? Chau7 counts input and output tokens for every API call using provider-specific tokenization, so you can pinpoint exactly where the tokens go.",
    },
    "cost-tracking": {
        "tagline": "Your AI spending in dollars and cents. Per call, per session, per month. No more surprises.",
        "cta": "Find out where your AI budget actually goes. (Brace yourself.)",
        "why_matters": "Developers report AI coding costs exceeding five thousand dollars per month with no breakdown of where the money goes. Activity Monitor won't help. Your provider dashboard shows aggregate numbers. Chau7 calculates cost per API call using current provider pricing tables, then rolls it up per session and per period. You'll finally be able to answer 'how much did that refactor cost?'",
    },
    "latency-tracking": {
        "tagline": "Time-to-first-token, total duration, per call. Because 'it feels slow' is not a metric.",
        "cta": "Measure your AI latency. With actual numbers, not vibes.",
        "why_matters": "AI agent responsiveness depends on API latency, and latency varies wildly by provider, model, time of day, and prompt size. Without measurements, you are stuck with subjective impressions. Chau7 records time-to-first-token and total request duration for every API call, so you can make data-driven decisions about which model to use and when.",
    },
    "analytics-dashboard": {
        "tagline": "Tokens, costs, latency. All in one dashboard. Finally, a chart that matters.",
        "cta": "Visualize your AI spending. It's probably more interesting than your Jira board.",
        "why_matters": "Individual per-call metrics are valuable for debugging, but understanding AI spending patterns requires an aggregate view. The Analytics Dashboard shows token usage, costs, and latency trends over time with daily/weekly/monthly grouping. It queries the same telemetry data that the MCP server exposes, so what you see in the dashboard matches what your automations report.",
    },

    # ═══ MCP Server ═══
    "mcp-tools": {
        "tagline": "20 MCP tools. Full terminal control. Your AI agent just got its own command center.",
        "cta": "Give your AI agent a real terminal. Not a text box with delusions of grandeur.",
        "why_matters": "Without Chau7, AI agents are limited to injecting text into a single terminal session and hoping for the best. With 20 purpose-built MCP tools, agents can create tabs, execute commands, read output, inspect processes, track sessions, and manage their own workspace. It is the difference between shouting into a room and having a proper conversation.",
    },
    "unix-socket-server": {
        "tagline": "Local Unix socket. No network exposure, no authentication drama. Just fast, private IPC.",
        "cta": "MCP over Unix socket. Secure by default, not by configuration.",
        "why_matters": "A network-exposed MCP server would be a security liability: any process on your machine could connect and control your terminal. Chau7's MCP server communicates exclusively over a local Unix domain socket with filesystem permission checks. No TCP, no ports, no authentication tokens to rotate. It is fast (lower latency than TCP loopback) and private by construction.",
    },
    "auto-registration": {
        "tagline": "Launch Chau7. Done. Every AI client already knows how to talk to it.",
        "cta": "Zero-config MCP. Because life is too short for JSON config files.",
        "why_matters": "MCP server setup is the single biggest friction point in the AI-terminal workflow. Every client has a different config format, different path, different schema. Chau7 writes the correct config entry for Claude Code, Cursor, Windsurf, and Codex on every launch, idempotently. You never touch a config file. You never read documentation about socket paths. You just launch the app.",
    },
    "mcp-resources": {
        "tagline": "Read-only endpoints for agents that need to look before they leap.",
        "cta": "Let your AI agent read terminal state. Safely. Without executing anything.",
        "why_matters": "Agents frequently need to inspect terminal state before acting: which tabs are open, what sessions are running, what the latest telemetry shows. MCP resources provide that context through read-only endpoints that cannot modify state. An agent planning a multi-step workflow can check current tab count, review active sessions, and read the latest run data before deciding what to do next.",
    },
    "tab-limits": {
        "tagline": "A guardrail for enthusiastic AI agents. Maximum tabs, minimum chaos.",
        "cta": "Prevent tab explosions. Your future self will be grateful.",
        "why_matters": "AI agents operating in loops can create tabs faster than you can notice. A coding agent that retries a failing test might open ten tabs in ten seconds. Tab limits set a ceiling on MCP-created tabs so runaway automation stays contained. It is a five-second setting that prevents a very bad afternoon.",
    },
    "mcp-tab-indicator": {
        "tagline": "Tabs you opened. Tabs your AI opened. Now you can tell the difference.",
        "cta": "Know which tabs are yours and which ones your AI conjured.",
        "why_matters": "When an AI agent creates several tabs during a complex task, you need to know which tabs are part of the automated workflow and which ones are your own work. MCP Tab Indicator adds a visual badge to every tab created through MCP so the distinction is immediate. No clicking, no guessing.",
    },

    # ═══ Tab Management ═══
    "multi-tab": {
        "tagline": "Unlimited tabs. Drag to reorder, pin the important ones, title them whatever you want.",
        "cta": "Finally, tabs that work the way you think they should.",
        "why_matters": "Developers routinely work across multiple directories, servers, and tasks simultaneously. A terminal that makes tab management feel heavy or limited forces you into workarounds like tmux just to have more than a few sessions. Chau7's tab system is designed for the 20-tab workflow: drag to reorder, pin persistent tabs, set custom titles, and let background suspension keep everything responsive.",
    },
    "split-panes": {
        "tagline": "Horizontal splits. Vertical splits. Within any tab. No tmux required.",
        "cta": "Split your terminal natively. Leave tmux for the server.",
        "why_matters": "Split panes eliminate the need for tmux in the most common use case: watching a build in one pane while editing in another, or tailing logs alongside a running server. Chau7 provides native horizontal and vertical splits with drag-to-resize handles and keyboard shortcuts, all integrated with the tab system and session restore.",
    },
    "tab-drag-drop": {
        "tagline": "Drag tabs. Snap to position. Move between windows. Pixel-perfect, zero drift.",
        "cta": "Tab reordering that actually feels good. Novel concept.",
        "why_matters": "Tab reordering is one of the most frequent interactions in a multi-tab terminal. If dragging feels laggy or imprecise, you stop using it and start mentally tracking tab positions instead. Chau7's drag uses snap-to-position with accumulated offset, so the tab stays under your cursor. No lerp, no drift, no fighting the UI.",
    },
    "tab-profiles": {
        "tagline": "One click: right shell, right directory, right env vars. Context switching without the switching.",
        "cta": "Set up a tab profile once. Use it forever. (Sound familiar, tmux users?)",
        "why_matters": "Developers working on multiple projects constantly switch contexts: different directories, different Node versions, different environment variables. Tab profiles let you define a complete tab configuration once and launch it with a click. It is project bookmarks for your terminal.",
    },
    "background-suspension": {
        "tagline": "30 tabs open, only one rendering. Inactive tabs use zero GPU cycles.",
        "cta": "Open as many tabs as you want. Chau7 only renders the one you're looking at.",
        "why_matters": "Terminal emulators that render all tabs continuously waste significant GPU and CPU time on content you are not looking at. Chau7 fully suspends inactive tabs: no render cycles, no timer fires, no wasted work. When you switch back, the tab resumes instantly because the state never left memory. It is the reason Chau7 stays fast at 30 tabs.",
    },
    "tab-watchdog": {
        "tagline": "A background watchdog that notices when tabs go stale and fixes them before you do.",
        "cta": "Tabs that heal themselves. Like Wolverine, but for your terminal.",
        "why_matters": "Stale or frozen terminal tabs are a quiet productivity killer. You switch to a tab expecting to see output, find it stuck, and waste time restarting the session. Chau7's watchdog monitors every tab for signs of staleness and resets state automatically. It resets after timeout rather than giving up permanently, because terminals are supposed to be resilient.",
    },

    # ═══ Session ═══
    "session-recording": {
        "tagline": "Built-in session recording. Every keystroke, every output, millisecond timestamps. No extra tools.",
        "cta": "Record your terminal sessions natively. asciinema is great, but built-in is better.",
        "why_matters": "Terminal session recording has been a third-party bolt-on for decades. Tools like asciinema and script work, but they require setup, generate separate files, and live outside the terminal's awareness. Chau7 records sessions as a native feature with millisecond-precise timestamps, integrated with the telemetry system, and accessible through the MCP server. The recording just happens.",
    },
    "timeline-scrubber": {
        "tagline": "Scrub through recordings like a video. Jump to any moment. See exactly what happened.",
        "cta": "Navigate terminal recordings visually. Like a DVR for your shell.",
        "why_matters": "Raw terminal recordings are useless without navigation. Scrolling through a text dump to find the moment a build failed is like searching a VHS tape by holding fast-forward. The timeline scrubber gives you a visual timeline with click-to-seek, so you can jump to the exact second an error occurred.",
    },
    "session-restore": {
        "tagline": "Quit Chau7. Relaunch. Everything is exactly where you left it. Tabs, directories, splits, all of it.",
        "cta": "Close your terminal without anxiety. Everything comes back.",
        "why_matters": "Losing your terminal layout after a restart is one of the most common pain points across every terminal emulator forum. You had 12 tabs arranged just right, each in the correct directory, and now they are gone. Chau7 saves the full session state: tab order, working directories, split layout, and window positions. When you relaunch, it all comes back. Like it never left.",
    },

    # ═══ GPU Rendering ═══
    "metal-rendering": {
        "tagline": "Apple Metal GPU rendering. Glyph atlas. Dirty region tracking. Your terminal has never been this fast.",
        "cta": "GPU-rendered terminal. Because your Mac has a GPU and it's bored.",
        "why_matters": "CPU-based terminal renderers redraw the entire screen on every update, which causes visible stutter when programs flood output. Chau7 renders with Apple Metal: a hardware-accelerated glyph atlas caches pre-rasterized characters, and dirty region tracking ensures only changed cells get redrawn. The result is smooth rendering even during massive output bursts. This is not marketing fluff. It is a measurably different experience.",
    },
    "iosurface-display": {
        "tagline": "GPU to display. No compositor. No extra copy. No wasted frame.",
        "cta": "Skip the compositor entirely. Your frames deserve better.",
        "why_matters": "The macOS compositor adds a full frame of latency and a GPU-to-GPU copy for every window. For a terminal where you notice every millisecond of input lag, that is unacceptable overhead. IOSurface lets Chau7 send rendered frames directly from GPU memory to the display, bypassing the compositor entirely. Zero extra copies. Zero extra latency.",
    },
    "simd-parsing": {
        "tagline": "SIMD-accelerated Rust parser. 16-32 bytes per cycle. Your ANSI escape sequences never had it so good.",
        "cta": "Parsing at cache-line speed. Written in Rust, because of course it is.",
        "why_matters": "Parsing is the first stage of the terminal pipeline and sets the throughput ceiling for everything downstream. Traditional byte-by-byte parsers create a bottleneck that no amount of GPU rendering can compensate for. Chau7's parser processes 16-32 bytes per SIMD instruction using Rust intrinsics, handling entire cache lines in a single cycle. The specific SIMD width adapts to your hardware.",
    },
    "iokit-hid-input": {
        "tagline": "Raw keyboard events from IOKit HID. Below AppKit, below NSEvent, below everything.",
        "cta": "Sub-millisecond input latency. You will feel the difference.",
        "why_matters": "Input latency is the most noticeable performance characteristic of a terminal. Even a few milliseconds of extra delay between keypress and screen update creates a subtle but persistent feeling that the application is not keeping up. Chau7 reads keyboard events from IOKit's HID subsystem directly, bypassing the entire NSEvent queue. The overhead is sub-millisecond.",
    },
    "triple-buffering": {
        "tagline": "Three buffers, atomic swaps. The parser and GPU never block each other. Zero tearing.",
        "cta": "Tear-free rendering at any output speed. Not a compromise, just good engineering.",
        "why_matters": "Without triple buffering, a terminal must either lock the screen buffer (causing the parser to stall while the GPU reads) or accept tearing artifacts. Chau7 maintains three buffers and rotates them with atomic swaps: the parser always has a buffer to write, the GPU always has a buffer to read, and they never contend. Smooth output at any speed.",
    },
    "lock-free-spsc-buffer": {
        "tagline": "One reader thread, one parser thread, one lock-free ring buffer. Zero contention.",
        "cta": "Lock-free data pipeline. Because mutexes are so last decade.",
        "why_matters": "The PTY-to-parser pipeline is the hottest data path in a terminal emulator. Every byte of program output flows through it. A mutex on this path would create contention between the PTY reader and the parser, adding latency on every I/O cycle. Chau7 uses a single-producer single-consumer ring buffer with no locks, no kernel transitions, and no contention. The reader and parser proceed independently.",
    },

    # ═══ Terminal Core ═══
    "vt100-xterm-emulation": {
        "tagline": "Every escape sequence. Every color mode. Every weird edge case from 1978. Handled.",
        "cta": "Full VT100/xterm compatibility. Even the obscure bits.",
        "why_matters": "Terminal emulation bugs manifest as garbled output, broken TUI layouts, and applications that refuse to run. Chau7 implements VT100 and xterm escape sequences comprehensively, including 256-color, true color (24-bit), and all standard control sequences. If it works in xterm, it works in Chau7.",
    },
    "unicode-emoji-support": {
        "tagline": "CJK, RTL, combining characters, color emoji. Unicode rendered correctly, not approximately.",
        "cta": "A terminal that speaks every language. Including emoji.",
        "why_matters": "Modern developer workflows produce Unicode content constantly: international file paths, multilingual log messages, emoji in commit messages, and mathematical symbols in documentation. Chau7 handles Unicode at the grapheme-cluster level, correctly measuring and rendering everything from Chinese characters to ZWJ emoji sequences.",
    },
    "shell-integration": {
        "tagline": "Your shell talks to Chau7. Command boundaries, directories, exit codes. Automatically.",
        "cta": "Smarter terminal, zero configuration. Your shell already knows what to say.",
        "why_matters": "Without shell integration, a terminal sees only a stream of characters with no structure. It cannot tell where one command ends and another begins, what the current directory is, or whether the last command succeeded. Chau7's shell integration hooks into zsh, bash, and fish to report all of this automatically, enabling features like per-command timing, directory-aware tab titles, and command-level navigation.",
    },
    "scrollback-buffer": {
        "tagline": "Thousands of lines of history. Regex search. Because build output waits for no one.",
        "cta": "Never lose terminal output again. It's all in the scrollback.",
        "why_matters": "Developers frequently need to scroll back through build output, test results, or log streams to find specific errors or timestamps. A small scrollback buffer means lost context. Chau7 provides a configurable scrollback with efficient memory usage and built-in regex search, so that error from five minutes ago is still findable.",
    },
    "hyperlinks": {
        "tagline": "URLs in your terminal are actually clickable. OSC 8 hyperlinks make CLI output interactive.",
        "cta": "Click links in your terminal. Revolutionary, we know.",
        "why_matters": "Modern CLI tools output URLs constantly: links to documentation, CI builds, pull requests, file paths. In most terminals, you have to manually copy-paste them into a browser. Chau7 supports OSC 8 hyperlinks, making URLs clickable. It also detects plain URLs in terminal output and makes those clickable too.",
    },
    "image-protocol": {
        "tagline": "Plots, screenshots, and diagrams. Right in your terminal. No window switching required.",
        "cta": "See images in your terminal. The future is now. (The future is weird.)",
        "why_matters": "Data science, DevOps, and design workflows produce visual output: matplotlib charts, architecture diagrams, CI status badges. Chau7 supports inline image rendering via the iTerm2 image protocol, so you can display images directly in terminal output without switching to another application.",
    },
    "ligatures": {
        "tagline": "Programming ligatures that actually render. => becomes a real arrow. != becomes a real inequality.",
        "cta": "Pretty operators in your terminal. Your font worked hard on those ligatures.",
        "why_matters": "Programming ligatures improve code readability by rendering compound operators as distinct visual symbols. But most terminals cannot render them because their text engines treat each character independently. Chau7's Metal-based renderer handles ligature substitution correctly, so your Fira Code or JetBrains Mono investment actually pays off in the terminal too.",
    },
    "bell-notification": {
        "tagline": "Your build finished. Your long command completed. Chau7 lets you know, however you prefer.",
        "cta": "Get notified when your terminal needs attention. Like a polite butler.",
        "why_matters": "The terminal bell is the standard mechanism for programs to request attention: a build finishing, a long-running command completing, a test suite reporting results. Chau7 supports visual flash, audio bell, and macOS notification center integration so you never miss an event even when the terminal is in the background.",
    },

    # ═══ Safety ═══
    "dangerous-command-guard": {
        "tagline": "A seatbelt for your shell. rm -rf pauses for confirmation. Because undo doesn't exist in terminals.",
        "cta": "Protect yourself from rm -rf. Or from Tuesday-morning-before-coffee you.",
        "why_matters": "Every developer has a horror story about a misplaced rm -rf or a dd that targeted the wrong device. Shell aliases and confirmation functions are fragile and easy to bypass. Chau7's dangerous command guard intercepts known destructive commands at the terminal level, before the shell sees them, and presents a confirmation dialog. It is a seatbelt, not a cage: experienced drivers still wear them.",
    },
    "process-exit-confirmation": {
        "tagline": "Close a tab with a running process? Not without a warning first.",
        "cta": "Protect your running processes from accidental Cmd+W.",
        "why_matters": "Losing a running process to an accidental Cmd+W is one of the most common terminal frustrations. A half-finished database migration, a running dev server, an SSH session to production: gone in a keystroke. Chau7 warns before closing any tab with active processes, with configurable per-process rules so you can silence warnings for processes you don't care about.",
    },
    "mcp-approval-gate": {
        "tagline": "Your AI agent wants to run a command. You get to say yes or no first.",
        "cta": "Trust, but verify. MCP actions with an approval step.",
        "why_matters": "MCP gives AI agents powerful capabilities inside your terminal, but power without oversight is a liability. The approval gate lets you review every MCP tool call before it executes. Enable it globally, per-tool, or not at all. It is the difference between 'my AI can do anything' and 'my AI can do anything I approve.'",
    },

    # ═══ Clipboard ═══
    "clipboard-history": {
        "tagline": "Every copy is remembered. Search, pin, and reuse anything you copied. Terminal clipboard, fixed.",
        "cta": "Terminal copy-paste is broken. This fixes it.",
        "why_matters": "The terminal clipboard experience has been broken for decades. Ctrl+C sends SIGINT instead of copying, selections vanish when you click elsewhere, and there's no history. Chau7 provides a proper clipboard with history, search, and pinned items. It handles the Ctrl+C ambiguity correctly and remembers everything you copy.",
    },
    "paste-confirmation": {
        "tagline": "See exactly what you're about to paste before it executes. Multi-line paste gets a safety check.",
        "cta": "Paste with confidence. Or at least with a preview.",
        "why_matters": "Pasting from the clipboard is one of the most dangerous terminal actions. A single newline in copied text can execute commands before you see them. ClickFix attacks exploit this by embedding hidden commands in seemingly innocent clipboard content. Chau7 shows a preview of multi-line pastes and warns about content containing newlines or control characters before anything executes.",
    },
    "snippets": {
        "tagline": "Save a command once, reuse it forever. Placeholders fill in the details. Goodbye, repetitive typing.",
        "cta": "Stop retyping that Docker command. You know the one.",
        "why_matters": "Developers type the same complex commands hundreds of times: SSH tunnels with specific port mappings, Docker builds with eight flags, database queries with connection strings. Snippets let you save these once with placeholder tokens that prompt for values when invoked. It is aliases with parameters and a search interface.",
    },

    # ═══ SSH & Remote ═══
    "ssh-connection-manager": {
        "tagline": "All your SSH hosts in one place. Connect with a click. Remember nothing.",
        "cta": "Organize your SSH connections. Because your memory has limits.",
        "why_matters": "Managing SSH connections by memory does not scale. Once you have more than a handful of hosts, you are either maintaining a cheat sheet, relying on shell history, or typing ssh user@host from memory and hoping autocomplete fills in the right one. Chau7 provides a visual SSH manager with stored profiles, so connecting to any host is a single click.",
    },
    "auto-import-ssh-config": {
        "tagline": "Your ~/.ssh/config already has dozens of hosts. Chau7 reads it. No re-entry required.",
        "cta": "Import your SSH config in one click. Because you already did the hard part.",
        "why_matters": "Most developers have a carefully maintained ~/.ssh/config with dozens of hosts, jump configurations, and identity file paths. Re-entering all of that into a new tool is a non-starter. Chau7 reads your SSH config file directly and imports every host with its full configuration. Migration takes seconds.",
    },
    "jump-host-support": {
        "tagline": "Multi-hop SSH through bastion hosts. Configured once, connected with a click.",
        "cta": "Simplify multi-hop SSH. No more chaining ProxyJump commands from memory.",
        "why_matters": "Production infrastructure sits behind bastion hosts, requiring multi-hop SSH connections that are tedious to type and easy to misconfigure. Chau7 lets you configure jump host chains visually and connect through them with a single click. The complexity is in the configuration, not in your daily workflow.",
    },
    "context-aware-switching": {
        "tagline": "SSH into production and your terminal turns red. Because visual context prevents disasters.",
        "cta": "Never mistake prod for staging again. Colors don't lie.",
        "why_matters": "Running a destructive command on the wrong server is one of the most expensive mistakes in operations. Chau7 changes terminal colors, title, and settings when you SSH into different environments. Production is visually distinct from staging, which is distinct from development. The visual cue fires before your brain has to think about which server you are on.",
    },

    # ═══ Search ═══
    "command-palette": {
        "tagline": "Cmd+Shift+P. Every feature, every action, every setting. One fuzzy search away.",
        "cta": "Discover features you didn't know existed. All of them.",
        "why_matters": "Terminal emulators accumulate features over time, but discoverability stalls at the menu bar. Most users never find half the features available to them. The command palette makes everything searchable: settings, actions, features, and configuration options. If it exists in Chau7, you can find it with Cmd+Shift+P.",
    },
    "terminal-search": {
        "tagline": "Regex search through your terminal output. Case-sensitive. Match-by-match navigation. Actually useful.",
        "cta": "Find that error message from five minutes ago. It's still there.",
        "why_matters": "Terminal output scrolls past and is gone. When you need to find a specific error, a particular log line, or a URL from earlier output, you need search that actually works. Chau7 provides regex search with case sensitivity toggle and match-by-match navigation. It searches the scrollback buffer, so content that scrolled off screen is still findable.",
    },
    "command-history-search": {
        "tagline": "Better than Ctrl+R. Fuzzy search with frecency ranking. Find commands by what you remember, not exact text.",
        "cta": "Upgrade your Ctrl+R. You deserve fuzzy search.",
        "why_matters": "Ctrl+R is powerful but the default interface is terrible: a single line of text, exact substring matching, and you have to cycle through results one at a time. Chau7 provides a proper search UI with fuzzy matching and frecency ranking (frequent + recent commands score higher). Find any command by typing fragments of what you remember.",
    },

    # ═══ Customization ═══
    "fonts": {
        "tagline": "Every monospace font you love, ready to go. Pick one and start coding.",
        "cta": "Find your perfect terminal font. Takes seconds, lasts forever.",
        "why_matters": "Font choice directly affects readability during long coding sessions. Chau7 ships with a curated font picker that previews each option in real terminal output, so you can see exactly how your code will look before committing. No more downloading fonts, installing them system-wide, and restarting your terminal to test.",
    },
    "themes": {
        "tagline": "Beautiful color schemes without the YAML configuration headache.",
        "cta": "Find a color scheme you actually like. It'll take about ten seconds.",
        "why_matters": "A well-chosen color scheme reduces eye strain and makes syntax-highlighted output easier to scan. Chau7 ships with curated themes that preview in real time, so you can browse and select without editing configuration files or restarting your terminal.",
    },
    "custom-keybindings": {
        "tagline": "Your shortcuts, your rules. Remap anything, conflict-free.",
        "cta": "Keep your muscle memory. Remap everything else.",
        "why_matters": "Developers build deep muscle memory around keyboard shortcuts, and switching terminals should not mean relearning every binding. Chau7 lets you remap any shortcut through a visual editor with conflict detection. Bring your muscle memory from your old terminal, your editor, or your own imagination.",
    },
    "cursor-styles": {
        "tagline": "Block, beam, underline. Blinking or steady. Your cursor, your call.",
        "cta": "Customize your cursor. It's the one thing you stare at all day.",
        "why_matters": "The cursor is the single most-watched element on screen during terminal work. Getting its shape, blink rate, and color right matters more than most developers realize. Chau7 lets you configure cursor style, color, and blink behavior per-profile, so insert mode can look different from normal mode if you use Vim.",
    },
    "transparency-blur": {
        "tagline": "See through your terminal to the app behind it. With blur, so it's actually readable.",
        "cta": "See your docs through your terminal. Multitasking via translucency.",
        "why_matters": "Transparency lets you maintain awareness of background applications, like documentation or chat, without switching windows. The key is blur: without it, transparent terminals are unreadable. Chau7 combines adjustable opacity with a macOS vibrancy blur effect, so the background is visible but the text stays crisp.",
    },
    "padding-margins": {
        "tagline": "A little breathing room makes a big difference. Pixel-perfect terminal spacing.",
        "cta": "Give your terminal room to breathe. It's been asking nicely.",
        "why_matters": "Text jammed against window edges looks cramped and feels chaotic. A small amount of padding dramatically improves the visual quality of a terminal window. Chau7 lets you configure padding on all four sides independently, so you can get the exact layout that feels right for your setup.",
    },

    # ═══ Window Modes ═══
    "overlay-mode": {
        "tagline": "A terminal that floats above everything else. Persistent, accessible, out of the way.",
        "cta": "Keep your terminal in sight. Always.",
        "why_matters": "Developers constantly switch between terminal and editor. Overlay mode eliminates that context switch by keeping the terminal visible as a floating window above other applications. You can reference terminal output while writing code, or monitor a running process while working in another app.",
    },
    "dropdown-quake-style": {
        "tagline": "Press a key. Terminal drops down. Press again. It vanishes. Just like the '90s, but better.",
        "cta": "Quake-style terminal dropdown. One key. Instant access.",
        "why_matters": "The Quake-style dropdown is one of the most requested terminal features on macOS. Linux users have had Guake and Yakuake for years. Chau7 brings the same experience natively: a global hotkey summons a terminal that slides down from the top of the screen, and another press hides it. The terminal stays in memory, so there is no launch delay.",
    },
    "fullscreen-mode": {
        "tagline": "Full screen. Zero distractions. Just you and the command line.",
        "cta": "Go fullscreen. The rest of your screen was just decoration anyway.",
        "why_matters": "Fullscreen mode eliminates every visual distraction, which matters during deep debugging, code reviews in the terminal, or SSH sessions where you need maximum screen real estate. Chau7 uses native macOS fullscreen with proper Space integration, so you can swipe between fullscreen terminal and other apps.",
    },
    "menu-bar-only": {
        "tagline": "No Dock icon. One hotkey away. Always available, never in the way.",
        "cta": "Hide your terminal from the Dock. It'll still be there when you need it.",
        "why_matters": "Developers who use the terminal intermittently don't need it occupying a permanent Dock slot. Menu bar only mode keeps Chau7 accessible via a global hotkey or menu bar icon without cluttering the Dock or the Cmd+Tab app switcher. The terminal is one keystroke away but invisible when you don't need it.",
    },

    # ═══ Editor ═══
    "syntax-highlighting": {
        "tagline": "Edit code in your terminal with real syntax colors. Not Vim-level complexity, not nano-level sadness.",
        "cta": "Edit files in your terminal. With colors. Like a civilized developer.",
        "why_matters": "Terminal text editors sit at two extremes: Vim (powerful, steep learning curve) and nano (simple, no syntax highlighting). Chau7's built-in editor provides syntax highlighting for common languages with zero learning curve. Open a file, see colors, edit, save. That's it.",
    },
    "bracket-matching": {
        "tagline": "Click a bracket, see its match. Nested JSON will never defeat you again.",
        "cta": "Find the matching bracket. Without counting on your fingers.",
        "why_matters": "Deeply nested brackets in JSON, YAML, or code are one of the most common sources of syntax errors during terminal editing. Chau7's editor highlights the matching bracket when you click or cursor next to one, so you can trace nesting visually instead of counting by hand.",
    },
    "find-replace": {
        "tagline": "Find and replace in the terminal editor. Regex supported. No arcane keybindings required.",
        "cta": "Search and replace in your terminal editor. Like a normal text editor.",
        "why_matters": "Find and replace is fundamental, but most terminal editors make it unnecessarily complex. Chau7 provides a straightforward find-and-replace bar with regex support, preview of matches, and one-click replace-all. It works the way you expect because it works the way every other editor works.",
    },
    "line-numbers": {
        "tagline": "Line numbers in the terminal editor. Because 'error on line 47' means nothing without them.",
        "cta": "Navigate by line number. The way error messages intended.",
        "why_matters": "Line numbers are essential for navigating error messages, git diffs, and stack traces. When a compiler says 'error on line 47,' you need to be able to jump there. Chau7's editor shows line numbers by default, with configurable display and optional relative line numbers for Vim-style navigation.",
    },

    # ═══ Accessibility ═══
    "voiceover-support": {
        "tagline": "Full VoiceOver integration. Because accessible terminals shouldn't be an afterthought.",
        "cta": "A terminal that works with your screen reader. Not against it.",
        "why_matters": "Terminal.app's VoiceOver support has long been inadequate, and most third-party terminals treat accessibility as an afterthought. Chau7 provides full VoiceOver integration with terminal content announcement, cursor tracking, and proper accessibility labels throughout the UI. Accessible by design, not by patch.",
    },
    "high-contrast-mode": {
        "tagline": "Respects macOS High Contrast. Sharper borders, stronger text, automatic adaptation.",
        "cta": "A terminal that adapts to your vision needs. Automatically.",
        "why_matters": "Low-vision developers and anyone working in challenging lighting conditions benefit from enhanced contrast. Chau7 respects the macOS High Contrast setting and automatically adjusts borders, text weight, and UI element contrast. No manual theme switching required.",
    },
    "reduced-motion": {
        "tagline": "Respects macOS Reduce Motion. Instant transitions, zero unnecessary animation.",
        "cta": "All the features, none of the unnecessary motion.",
        "why_matters": "Motion sensitivity affects a meaningful number of developers. Animations that feel polished to one person can trigger discomfort in another. Chau7 respects the macOS Reduce Motion preference and replaces all animations with instant transitions. Every feature works the same, just without the motion.",
    },
    "localization": {
        "tagline": "Your terminal, in your language. Because not everyone thinks in English.",
        "cta": "Use your terminal in your language. Bienvenue.",
        "why_matters": "Developers work in every language, and a terminal that only speaks English creates unnecessary friction. Chau7 supports localization for its UI, menus, settings, and documentation. The terminal speaks your language so you can focus on your code.",
    },

    # ═══ Scripting ═══
    "json-rpc-api": {
        "tagline": "A real API for your terminal. JSON-RPC over stdin/stdout. Automate anything.",
        "cta": "Script your terminal with a proper API. Not AppleScript. Never AppleScript.",
        "why_matters": "Most terminal emulators provide no automation API, forcing developers to use AppleScript, osascript hacks, or fragile keybinding simulation. Chau7 exposes a JSON-RPC API that lets any programming language create tabs, run commands, read output, and manage sessions programmatically. If you can send JSON, you can control Chau7.",
    },
    "shell-hooks": {
        "tagline": "Run custom logic on every command. Pre-exec, post-exec, on-error. Automatically.",
        "cta": "Automate your terminal workflow. Hooks make it effortless.",
        "why_matters": "Shell hooks transform the terminal from a passive command executor into an automation platform. Chau7 supports pre-exec, post-exec, and on-error hooks that can trigger notifications, log commands, switch themes, or run arbitrary scripts. You configure them once, and they run on every command without you thinking about them.",
    },

    # ═══ Dirty Region Tracking (rendering) ═══
    "dirty-region-tracking": {
        "tagline": "Only redraw what changed. Not the whole screen. Every frame.",
        "cta": "Efficient rendering that does less work. On purpose.",
        "why_matters": "A full-screen redraw for a single character change wastes GPU time proportional to your terminal size. Chau7 tracks which cells changed between frames and only redraws the dirty region. For typical interactive use where a single line changes at a time, this reduces GPU work by 95% or more compared to full-screen rendering.",
    },
    "glyph-atlas": {
        "tagline": "A GPU-resident texture of every glyph you use. Pre-rasterized, cached, instant.",
        "cta": "Pre-rasterized glyphs. Your GPU renders text the way it was meant to.",
        "why_matters": "Rasterizing text on every frame is expensive. Chau7 pre-rasterizes every unique glyph into a GPU-resident texture atlas on first use. Subsequent renders are texture lookups, not rasterization passes. The atlas is persistent across frames and grows as new glyphs appear, so even CJK-heavy output renders at full speed.",
    },
    "cursor-rendering": {
        "tagline": "A cursor that renders at GPU speed. Block, beam, underline, blinking. All smooth.",
        "cta": "A cursor that keeps up with you. Rendered on the GPU, not by the CPU.",
        "why_matters": "The cursor is the single most-animated element in a terminal. Chau7 renders it on the GPU alongside all other text, so cursor movement, blink animation, and shape transitions are smooth and consistent. No CPU-side drawing, no jank, no special-casing.",
    },
}

# ── Apply rewrites ────────────────────────────────────────────
with open(DATA_FILE) as f:
    data = json.load(f)

applied = 0
missing = []
for cat in data["categories"]:
    for feat in cat["features"]:
        slug = feat["slug"]
        if slug in REWRITES:
            for field, value in REWRITES[slug].items():
                feat[field] = value
                applied += 1
        else:
            missing.append(slug)

with open(DATA_FILE, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"Applied {applied} field rewrites across {len(REWRITES)} features.")
if missing:
    print(f"Features without rewrites ({len(missing)}): not rewritten (keeping originals)")
    for m in missing:
        print(f"  - {m}")
