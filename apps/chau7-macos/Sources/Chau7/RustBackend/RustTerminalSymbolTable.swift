import Darwin
import Foundation

// MARK: - Rust Terminal Symbol Table

/// The dlopen/dlsym plumbing for `libchau7_terminal.dylib`, extracted from
/// `RustTerminalFFI` so the AppKit-facing wrapper only *consumes* bound
/// function pointers.
///
/// Owns three things:
///   1. The `@convention(c)` function types matching `chau7_terminal.h`.
///   2. The bound function pointers themselves (optional only where the
///      symbol is genuinely optional — older dylibs may lack it and the
///      caller has a graceful fallback).
///   3. The loader: dlopen → ABI-version probe → struct-layout probes →
///      symbol binding, refusing to bind on any contract mismatch.
///      Pre-probe dylibs (no version symbol) still load without verification.
struct RustTerminalSymbolTable {

    // MARK: - Function Types (matching chau7_terminal.h)

    typealias CreateFn = @convention(c) (UInt16, UInt16, UnsafePointer<CChar>?) -> OpaquePointer?
    typealias CreateWithEnvFn = @convention(c) (UInt16, UInt16, UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?, Int) -> OpaquePointer?
    typealias CreateWithLaunchFn = @convention(c) (
        UInt16,
        UInt16,
        UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<CChar>?>?,
        UnsafePointer<UnsafePointer<CChar>?>?,
        Int,
        UnsafePointer<UnsafePointer<CChar>?>?,
        Int,
        UnsafePointer<CChar>?
    ) -> OpaquePointer?
    typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    typealias SendBytesFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    typealias SendTextFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias ResizeFn = @convention(c) (OpaquePointer?, UInt16, UInt16) -> Void
    /// Re-deliver SIGWINCH to the PTY foreground pgrp (defeats TUI startup width-latch race)
    typealias NudgeWinsizeFn = @convention(c) (OpaquePointer?) -> Void
    // Use UnsafeMutableRawPointer since Swift structs aren't directly C-representable
    typealias GetGridFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    typealias FreeGridFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias ScrollPositionFn = @convention(c) (OpaquePointer?) -> Double
    typealias ScrollToFn = @convention(c) (OpaquePointer?, Double) -> Void
    typealias ScrollLinesFn = @convention(c) (OpaquePointer?, Int32) -> Void
    typealias SelectionTextFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias SelectionClearFn = @convention(c) (OpaquePointer?) -> Void
    typealias SelectionStartFn = @convention(c) (OpaquePointer?, Int32, Int32, UInt8) -> Void
    typealias SelectionUpdateFn = @convention(c) (OpaquePointer?, Int32, Int32) -> Void
    typealias SelectionAllFn = @convention(c) (OpaquePointer?) -> Void
    typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias CursorPositionFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<UInt16>?) -> Void
    typealias PollFn = @convention(c) (OpaquePointer?, UInt32) -> Bool
    typealias PollEventsFn = @convention(c) (OpaquePointer?, UInt32) -> UInt32
    typealias SetColorsFn = @convention(c) (OpaquePointer?, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UnsafePointer<UInt8>?) -> Void
    typealias ClearScrollbackFn = @convention(c) (OpaquePointer?) -> Void
    // FFI types for raw output retrieval from the Rust terminal
    // Returns *mut u8 (mutable pointer) for proper memory ownership transfer
    typealias GetLastOutputFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<UInt8>?
    typealias FreeOutputFn = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
    typealias InjectOutputFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    /// Scrollback size configuration
    typealias SetScrollbackSizeFn = @convention(c) (OpaquePointer?, UInt32) -> Void
    /// Replay historical buffer into a cleared terminal (for tier promotion)
    typealias ReplayBufferFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    /// Smart scroll support: get display offset (0 = at bottom)
    typealias DisplayOffsetFn = @convention(c) (OpaquePointer?) -> UInt32
    /// Bracketed paste mode query (for proper paste handling in vim, zsh, etc.)
    typealias IsBracketedPasteModeFn = @convention(c) (OpaquePointer?) -> Bool
    /// Alternate screen mode query (full-screen TUIs)
    typealias IsAlternateScreenActiveFn = @convention(c) (OpaquePointer?) -> Bool
    /// Bell event checking (for audio/visual bell feedback)
    typealias CheckBellFn = @convention(c) (OpaquePointer?) -> Bool
    // Mouse mode query (for context menu gating and mouse reporting)
    typealias GetMouseModeFn = @convention(c) (OpaquePointer?) -> UInt32
    typealias IsMouseReportingActiveFn = @convention(c) (OpaquePointer?) -> Bool
    /// Application cursor mode (DECCKM) query - for arrow key sequences
    typealias IsApplicationCursorModeFn = @convention(c) (OpaquePointer?) -> Bool
    // Debug and performance functions
    typealias GetShellPidFn = @convention(c) (OpaquePointer?) -> UInt64
    typealias GetDebugStateFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    typealias FreeDebugStateFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias GetFullBufferTextFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias GetFullBufferAnsiTextFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias GetTailBufferAnsiTextFn = @convention(c) (OpaquePointer?, UInt, UInt) -> UnsafeMutablePointer<CChar>?
    typealias ResetMetricsFn = @convention(c) (OpaquePointer?) -> Void
    // Terminal event functions (title, exit, PTY closed)
    typealias GetPendingTitleFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias GetPendingCwdFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias GetPendingExitCodeFn = @convention(c) (OpaquePointer?) -> Int32
    typealias IsPtyClosedFn = @convention(c) (OpaquePointer?) -> Bool
    /// Echo detection via termios (Phase 2: reliable password prompt detection)
    typealias IsEchoDisabledFn = @convention(c) (OpaquePointer?) -> Bool

    /// Direct line text retrieval (avoids full grid snapshot per row)
    typealias GetLineTextFn = @convention(c) (OpaquePointer?, Int32) -> UnsafeMutablePointer<CChar>?
    typealias GetLogicalLineTextFn = @convention(c) (OpaquePointer?, Int32, UInt32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt32>?) -> UnsafeMutablePointer<CChar>?

    /// Hyperlink (OSC 8) FFI types (Phase 5)
    typealias GetLinkUrlFn = @convention(c) (OpaquePointer?, UInt16) -> UnsafeMutablePointer<CChar>?

    // Clipboard (OSC 52) FFI types (Phase 5)
    typealias GetPendingClipboardFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias HasClipboardRequestFn = @convention(c) (OpaquePointer?) -> Bool
    typealias RespondClipboardFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void

    // Shell integration (OSC 133) FFI types — opaque pointers like images API
    typealias GetPendingShellIntegrationEventsFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    typealias FreeShellIntegrationEventsFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    // Graphics protocol FFI types (Phase 4)
    typealias GetPendingImagesFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    typealias FreeImagesFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias SetImageProtocolsFn = @convention(c) (OpaquePointer?, Bool, Bool, Bool) -> Void
    typealias HasPendingImagesFn = @convention(c) (OpaquePointer?) -> Bool

    // MARK: - Bound Symbols

    let create: CreateFn
    let createWithEnv: CreateWithEnvFn? // Optional - older libraries may not have this
    let createWithLaunch: CreateWithLaunchFn? // Optional - adds shell argv + cwd
    let destroy: DestroyFn
    let sendBytes: SendBytesFn
    let sendText: SendTextFn
    let resize: ResizeFn
    let nudgeWinsize: NudgeWinsizeFn? // Optional - older libraries may not have this
    let getGrid: GetGridFn
    let freeGrid: FreeGridFn
    let scrollPosition: ScrollPositionFn
    let scrollTo: ScrollToFn
    let scrollLines: ScrollLinesFn
    let selectionText: SelectionTextFn
    let selectionClear: SelectionClearFn
    let selectionStart: SelectionStartFn? // Optional - older libraries may not have this
    let selectionUpdate: SelectionUpdateFn? // Optional - older libraries may not have this
    let selectionAll: SelectionAllFn? // Optional - older libraries may not have this
    let freeString: FreeStringFn
    let cursorPosition: CursorPositionFn
    let poll: PollFn
    let pollEvents: PollEventsFn?
    let setColors: SetColorsFn? // Optional - older libraries may not have this
    let clearScrollback: ClearScrollbackFn? // Optional - older libraries may not have this
    // Raw output retrieval functions (for shell integration and output detection)
    let getLastOutput: GetLastOutputFn? // Optional - older libraries may not have this
    let freeOutput: FreeOutputFn? // Optional - older libraries may not have this
    let injectOutput: InjectOutputFn? // Optional - inject UI-only output
    /// Scrollback size configuration
    let setScrollbackSize: SetScrollbackSizeFn? // Optional - older libraries may not have this
    /// Replay historical buffer (tier promotion)
    let replayBuffer: ReplayBufferFn? // Optional - older libraries may not have this
    /// Smart scroll support
    let displayOffset: DisplayOffsetFn? // Optional - older libraries may not have this
    /// Bracketed paste mode query
    let isBracketedPasteMode: IsBracketedPasteModeFn? // Optional - older libraries may not have this
    /// Alternate screen mode query
    let isAlternateScreenActive: IsAlternateScreenActiveFn? // Optional - older libraries may not have this
    /// Bell event checking
    let checkBell: CheckBellFn? // Optional - older libraries may not have this
    // Mouse mode query (for context menu gating)
    let getMouseMode: GetMouseModeFn? // Optional - older libraries may not have this
    let isMouseReportingActive: IsMouseReportingActiveFn? // Optional - older libraries may not have this
    /// Application cursor mode (DECCKM) query - for arrow key sequences
    let isApplicationCursorMode: IsApplicationCursorModeFn? // Optional - older libraries may not have this
    // Debug and performance functions
    let getShellPid: GetShellPidFn? // Optional - for dev server monitoring
    let getDebugState: GetDebugStateFn? // Optional - for debugging
    let freeDebugState: FreeDebugStateFn? // Optional - for debugging
    let getFullBufferText: GetFullBufferTextFn? // Optional - for debugging
    let getFullBufferAnsiText: GetFullBufferAnsiTextFn? // Optional - for styled restoration
    let getTailBufferAnsiText: GetTailBufferAnsiTextFn? // Optional - for bounded styled restoration
    let resetMetrics: ResetMetricsFn? // Optional - for performance analysis
    // Terminal event functions (title, exit, PTY closed)
    let getPendingTitle: GetPendingTitleFn? // Optional - for terminal title updates
    let getPendingCwd: GetPendingCwdFn? // Optional - OSC 7 cwd from Rust ANSI parser
    let getPendingExitCode: GetPendingExitCodeFn? // Optional - for process exit detection
    let isPtyClosed: IsPtyClosedFn? // Optional - for PTY close detection
    /// Echo detection via termios (Phase 2)
    let isEchoDisabled: IsEchoDisabledFn? // Optional - for reliable password detection
    /// Direct line text retrieval (avoids full grid snapshot per row)
    let getLineTextDirect: GetLineTextFn? // Optional - direct line text without grid snapshot
    let getLogicalLineTextDirect: GetLogicalLineTextFn? // Optional - logical wrapped line text for hit-testing
    /// Hyperlink support (OSC 8 — Phase 5)
    let getLinkUrl: GetLinkUrlFn? // Optional - for OSC 8 hyperlink URL retrieval
    // Clipboard support (OSC 52 — Phase 5)
    let getPendingClipboard: GetPendingClipboardFn? // Optional - for OSC 52 clipboard store
    let hasClipboardRequest: HasClipboardRequestFn? // Optional - for OSC 52 clipboard load
    let respondClipboard: RespondClipboardFn? // Optional - for OSC 52 clipboard load response
    // Shell integration (OSC 133)
    let getPendingShellIntegrationEvents: GetPendingShellIntegrationEventsFn?
    let freeShellIntegrationEvents: FreeShellIntegrationEventsFn?
    // Graphics protocol support (Phase 4)
    let getPendingImages: GetPendingImagesFn? // Optional - for image protocol support
    let freeImages: FreeImagesFn? // Optional - for image protocol support
    let setImageProtocols: SetImageProtocolsFn? // Optional - for image protocol support
    let hasPendingImages: HasPendingImagesFn? // Optional - for image protocol support

    // MARK: - Loading

    /// ABI version this build of the Swift mirrors was written against.
    /// Must match `CHAU7_TERMINAL_ABI_VERSION` in rust/chau7_terminal/src/ffi.rs.
    static let expectedABIVersion: UInt32 = 1

    /// A successfully loaded dylib: the bound symbol table plus the dlopen
    /// handle (kept alive for the process lifetime — closing it would
    /// invalidate every bound pointer).
    struct LoadedLibrary {
        let handle: UnsafeMutableRawPointer
        let symbols: RustTerminalSymbolTable
    }

    /// Returns the candidate dylib paths in priority order (env override →
    /// bundle resource → resource root → private frameworks → dev paths).
    static func libraryCandidates() -> [String] {
        var paths: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["CHAU7_RUST_LIB_PATH"], !envPath.isEmpty {
            paths.append(envPath)
        }
        // Try chau7_terminal first (the terminal emulator lib)
        if let resourcePath = Bundle.main.path(forResource: "libchau7_terminal", ofType: "dylib") {
            paths.append(resourcePath)
        }
        if let resourceRoot = Bundle.main.resourcePath {
            paths.append("\(resourceRoot)/libchau7_terminal.dylib")
        }
        if let frameworksRoot = Bundle.main.privateFrameworksPath {
            paths.append("\(frameworksRoot)/libchau7_terminal.dylib")
        }
        // Development paths
        #if DEBUG
        let devPaths = [
            "rust/target/release/libchau7_terminal.dylib",
            "rust/target/debug/libchau7_terminal.dylib",
            "../rust/target/release/libchau7_terminal.dylib",
            "../rust/target/debug/libchau7_terminal.dylib"
        ]
        paths.append(contentsOf: devPaths)
        #endif
        return paths
    }

    /// Single entry point: dlopen the dylib at `path`, verify the ABI
    /// contract, and bind every symbol. Returns nil — leaving no handle
    /// open — when dlopen fails, the ABI/layout probes mismatch, or a
    /// required symbol is missing.
    static func load(path: String) -> LoadedLibrary? {
        guard let handle = dlopen(path, RTLD_NOW) else {
            // Get detailed error from dlerror
            if let errorPtr = dlerror() {
                let errorStr = String(cString: errorPtr)
                Log.trace("RustTerminalFFI: dlopen failed for \(path): \(errorStr)")
            } else {
                Log.trace("RustTerminalFFI: dlopen failed for \(path) (no error details)")
            }
            return nil
        }
        Log.trace("RustTerminalFFI: dlopen succeeded for: \(path)")
        guard verifyABIContract(handle: handle, path: path) else {
            dlclose(handle)
            return nil
        }
        guard let symbols = bind(handle: handle) else {
            Log.warn("RustTerminalFFI: Library found at \(path) but missing required symbols")
            dlclose(handle)
            return nil
        }
        return LoadedLibrary(handle: handle, symbols: symbols)
    }

    /// Pure decision core for the ABI version probe.
    /// `nil` means the probe symbol is absent (pre-probe build): load without verification.
    static func isABIVersionCompatible(_ probedVersion: UInt32?, expected: UInt32 = expectedABIVersion) -> Bool {
        guard let probedVersion else { return true }
        return probedVersion == expected
    }

    /// Pure decision core for one struct-layout probe.
    /// `nil` means the probe symbol is absent: skip (older dylib without that probe).
    static func isLayoutCompatible(probedSize: Int?, swiftStride: Int) -> Bool {
        guard let probedSize else { return true }
        return probedSize == swiftStride
    }

    /// Verifies the dylib's ABI version and `#[repr(C)]` struct layouts against
    /// the hand-mirrored Swift types before binding any symbols. Struct drift
    /// between the two languages is silent memory corruption on every frame —
    /// refusing to bind (and surfacing the terminal-creation error card) is
    /// strictly better. Pre-probe dylibs (no version symbol) load as before.
    static func verifyABIContract(handle: UnsafeMutableRawPointer, path: String) -> Bool {
        typealias U32Fn = @convention(c) () -> UInt32
        typealias SizeFn = @convention(c) () -> Int

        guard let versionSym = dlsym(handle, "chau7_terminal_abi_version") else {
            Log.info("RustTerminalFFI: dylib has no ABI version probe (pre-probe build); loading without verification")
            return true
        }
        let version = unsafeBitCast(versionSym, to: U32Fn.self)()
        guard isABIVersionCompatible(version) else {
            Log.error("RustTerminalFFI: ABI version mismatch at \(path): dylib=\(version), expected=\(expectedABIVersion) — refusing to bind")
            return false
        }

        // Compare against Swift's stride, not size: C's sizeof includes tail
        // padding (what array indexing and pointer math use), which is stride
        // in Swift terms — e.g. CellData is size 18 / stride 20 vs C's 20.
        let layoutProbes: [(symbol: String, expected: Int, type: String)] = [
            ("chau7_terminal_sizeof_grid_snapshot", MemoryLayout<RustGridSnapshot>.stride, "GridSnapshot"),
            ("chau7_terminal_sizeof_cell_data", MemoryLayout<RustCellData>.stride, "CellData"),
            ("chau7_terminal_sizeof_debug_state", MemoryLayout<RustDebugState>.stride, "DebugState"),
            ("chau7_terminal_sizeof_image_data", MemoryLayout<RustTerminalFFI.FFIImageData>.stride, "FFIImageData"),
            ("chau7_terminal_sizeof_shell_event", MemoryLayout<RustShellEvent>.stride, "FFIShellEvent")
        ]
        for probe in layoutProbes {
            guard let sym = dlsym(handle, probe.symbol) else {
                Log.warn("RustTerminalFFI: layout probe \(probe.symbol) missing; skipping")
                continue
            }
            let rustSize = unsafeBitCast(sym, to: SizeFn.self)()
            guard isLayoutCompatible(probedSize: rustSize, swiftStride: probe.expected) else {
                Log.error("RustTerminalFFI: layout mismatch for \(probe.type) at \(path): rust=\(rustSize) bytes, swift=\(probe.expected) bytes — refusing to bind")
                return false
            }
        }
        Log.info("RustTerminalFFI: ABI contract verified (version \(version), \(layoutProbes.count) layout probes)")
        return true
    }

    /// Resolve one symbol with ✓/✗ logging (same strings as the original
    /// per-symbol `loadSymbol` helper).
    private static func symbol(_ name: String, in handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        let sym = dlsym(handle, name)
        if sym != nil {
            Log.trace("RustTerminalFFI: ✓ Loaded symbol '\(name)'")
        } else {
            if let errorPtr = dlerror() {
                let errorStr = String(cString: errorPtr)
                Log.warn("RustTerminalFFI: ✗ Failed to load symbol '\(name)': \(errorStr)")
            } else {
                Log.warn("RustTerminalFFI: ✗ Failed to load symbol '\(name)' (no error details)")
            }
        }
        return sym
    }

    /// Resolve an optional symbol, casting it to its function type. When the
    /// symbol is missing, logs `missingNote` (the feature-disabled fallback
    /// note) and returns nil — the graceful degradation callers rely on.
    private static func optionalSymbol<Fn>(
        _ name: String,
        as _: Fn.Type,
        in handle: UnsafeMutableRawPointer,
        missingNote: String? = nil
    ) -> Fn? {
        guard let sym = symbol(name, in: handle) else {
            if let missingNote {
                Log.info("RustTerminalFFI: \(missingNote)")
            }
            return nil
        }
        return unsafeBitCast(sym, to: Fn.self)
    }

    /// Binds every symbol from an already-verified dylib handle.
    /// Returns nil when any of the 15 required symbols is missing.
    static func bind(handle: UnsafeMutableRawPointer) -> RustTerminalSymbolTable? {
        Log.trace("RustTerminalFFI: Loading symbols from library handle")

        guard let createSym = symbol("chau7_terminal_create", in: handle),
              let destroySym = symbol("chau7_terminal_destroy", in: handle),
              let sendBytesSym = symbol("chau7_terminal_send_bytes", in: handle),
              let sendTextSym = symbol("chau7_terminal_send_text", in: handle),
              let resizeSym = symbol("chau7_terminal_resize", in: handle),
              let getGridSym = symbol("chau7_terminal_get_grid", in: handle),
              let freeGridSym = symbol("chau7_terminal_free_grid", in: handle),
              let scrollPositionSym = symbol("chau7_terminal_scroll_position", in: handle),
              let scrollToSym = symbol("chau7_terminal_scroll_to", in: handle),
              let scrollLinesSym = symbol("chau7_terminal_scroll_lines", in: handle),
              let selectionTextSym = symbol("chau7_terminal_selection_text", in: handle),
              let selectionClearSym = symbol("chau7_terminal_selection_clear", in: handle),
              let freeStringSym = symbol("chau7_terminal_free_string", in: handle),
              let cursorPositionSym = symbol("chau7_terminal_cursor_position", in: handle),
              let pollSym = symbol("chau7_terminal_poll", in: handle)
        else {
            Log.error("RustTerminalFFI: One or more required symbols missing")
            return nil
        }

        // Optional symbols - may not be present in older library versions.
        // Loaded in the same order as before the extraction so the ✓/✗ trace
        // stream stays byte-identical for a given dylib.
        let pollEvents = optionalSymbol(
            "chau7_terminal_poll_events", as: PollEventsFn.self, in: handle,
            missingNote: "poll_events symbol not found (optional, falling back to grid-only poll)"
        )
        let createWithEnv = optionalSymbol(
            "chau7_terminal_create_with_env", as: CreateWithEnvFn.self, in: handle,
            missingNote: "createWithEnv symbol not found (optional)"
        )
        let createWithLaunch = optionalSymbol(
            "chau7_terminal_create_with_launch", as: CreateWithLaunchFn.self, in: handle,
            missingNote: "createWithLaunch symbol not found (optional, shell argv/cwd unavailable)"
        )
        let setColors = optionalSymbol(
            "chau7_terminal_set_colors", as: SetColorsFn.self, in: handle,
            missingNote: "setColors symbol not found (optional)"
        )
        let clearScrollback = optionalSymbol(
            "chau7_terminal_clear_scrollback", as: ClearScrollbackFn.self, in: handle,
            missingNote: "clearScrollback symbol not found (optional)"
        )
        let nudgeWinsize = optionalSymbol(
            "chau7_terminal_nudge_winsize", as: NudgeWinsizeFn.self, in: handle,
            missingNote: "nudgeWinsize symbol not found (optional, startup SIGWINCH nudge unavailable)"
        )
        // Selection management symbols (start, update, select-all via Rust FFI)
        let selectionStart = optionalSymbol(
            "chau7_terminal_selection_start", as: SelectionStartFn.self, in: handle,
            missingNote: "selectionStart symbol not found (optional)"
        )
        let selectionUpdate = optionalSymbol(
            "chau7_terminal_selection_update", as: SelectionUpdateFn.self, in: handle,
            missingNote: "selectionUpdate symbol not found (optional)"
        )
        let selectionAll = optionalSymbol(
            "chau7_terminal_selection_all", as: SelectionAllFn.self, in: handle,
            missingNote: "selectionAll symbol not found (optional)"
        )
        // Raw output retrieval symbols (getLastOutput / freeOutput)
        let getLastOutput = optionalSymbol(
            "chau7_terminal_get_last_output", as: GetLastOutputFn.self, in: handle,
            missingNote: "getLastOutput symbol not found (optional)"
        )
        let freeOutput = optionalSymbol(
            "chau7_terminal_free_output", as: FreeOutputFn.self, in: handle,
            missingNote: "freeOutput symbol not found (optional)"
        )
        let injectOutput = optionalSymbol(
            "chau7_terminal_inject_output", as: InjectOutputFn.self, in: handle,
            missingNote: "inject_output symbol not found (optional)"
        )
        // Scrollback size configuration symbol
        let setScrollbackSize = optionalSymbol(
            "chau7_terminal_set_scrollback_size", as: SetScrollbackSizeFn.self, in: handle,
            missingNote: "setScrollbackSize symbol not found (optional)"
        )
        // Tier promotion: replay a historical buffer into the terminal
        let replayBuffer = optionalSymbol(
            "chau7_terminal_replay_buffer", as: ReplayBufferFn.self, in: handle,
            missingNote: "replayBuffer symbol not found (optional)"
        )
        // Smart scroll support: display offset symbol
        let displayOffset = optionalSymbol(
            "chau7_terminal_display_offset", as: DisplayOffsetFn.self, in: handle,
            missingNote: "displayOffset symbol not found (optional)"
        )
        // Bracketed paste mode query (for proper paste handling in vim, zsh, etc.)
        let isBracketedPasteMode = optionalSymbol(
            "chau7_terminal_is_bracketed_paste_mode", as: IsBracketedPasteModeFn.self, in: handle,
            missingNote: "isBracketedPasteMode symbol not found (optional)"
        )
        // Alternate screen mode query (for full-screen TUIs)
        let isAlternateScreenActive = optionalSymbol(
            "chau7_terminal_is_alternate_screen_active", as: IsAlternateScreenActiveFn.self, in: handle,
            missingNote: "isAlternateScreenActive symbol not found (optional)"
        )
        // Bell event checking (for audio/visual bell feedback)
        let checkBell = optionalSymbol(
            "chau7_terminal_check_bell", as: CheckBellFn.self, in: handle,
            missingNote: "checkBell symbol not found (optional)"
        )
        // Mouse mode query (for mouse reporting to TUI apps)
        let getMouseMode = optionalSymbol(
            "chau7_terminal_get_mouse_mode", as: GetMouseModeFn.self, in: handle,
            missingNote: "getMouseMode symbol not found (optional)"
        )
        // Mouse reporting active check (convenience function)
        let isMouseReportingActive = optionalSymbol(
            "chau7_terminal_is_mouse_reporting_active", as: IsMouseReportingActiveFn.self, in: handle,
            missingNote: "is_mouse_reporting_active symbol not found (optional)"
        )
        // Application cursor mode (DECCKM) query - for proper arrow key sequences in vim/tmux
        let isApplicationCursorMode = optionalSymbol(
            "chau7_terminal_is_application_cursor_mode", as: IsApplicationCursorModeFn.self, in: handle,
            missingNote: "is_application_cursor_mode symbol not found (optional)"
        )
        // Debug and performance functions
        let getShellPid = optionalSymbol(
            "chau7_terminal_get_shell_pid", as: GetShellPidFn.self, in: handle,
            missingNote: "get_shell_pid symbol not found (optional)"
        )
        let getDebugState = optionalSymbol(
            "chau7_terminal_get_debug_state", as: GetDebugStateFn.self, in: handle,
            missingNote: "get_debug_state symbol not found (optional)"
        )
        let freeDebugState = optionalSymbol(
            "chau7_terminal_free_debug_state", as: FreeDebugStateFn.self, in: handle,
            missingNote: "free_debug_state symbol not found (optional)"
        )
        let getFullBufferText = optionalSymbol(
            "chau7_terminal_get_full_buffer_text", as: GetFullBufferTextFn.self, in: handle,
            missingNote: "get_full_buffer_text symbol not found (optional)"
        )
        let getFullBufferAnsiText = optionalSymbol(
            "chau7_terminal_get_full_buffer_ansi_text", as: GetFullBufferAnsiTextFn.self, in: handle,
            missingNote: "get_full_buffer_ansi_text symbol not found (optional)"
        )
        let getTailBufferAnsiText = optionalSymbol(
            "chau7_terminal_get_tail_buffer_ansi_text", as: GetTailBufferAnsiTextFn.self, in: handle,
            missingNote: "get_tail_buffer_ansi_text symbol not found (optional)"
        )
        let resetMetrics = optionalSymbol(
            "chau7_terminal_reset_metrics", as: ResetMetricsFn.self, in: handle,
            missingNote: "reset_metrics symbol not found (optional)"
        )
        // Terminal event functions (title, exit, PTY closed)
        let getPendingTitle = optionalSymbol(
            "chau7_terminal_get_pending_title", as: GetPendingTitleFn.self, in: handle,
            missingNote: "get_pending_title symbol not found (optional)"
        )
        let getPendingCwd = optionalSymbol(
            "chau7_terminal_get_pending_cwd", as: GetPendingCwdFn.self, in: handle,
            missingNote: "get_pending_cwd symbol not found (optional)"
        )
        let getPendingExitCode = optionalSymbol(
            "chau7_terminal_get_pending_exit_code", as: GetPendingExitCodeFn.self, in: handle,
            missingNote: "get_pending_exit_code symbol not found (optional)"
        )
        let isPtyClosed = optionalSymbol(
            "chau7_terminal_is_pty_closed", as: IsPtyClosedFn.self, in: handle,
            missingNote: "is_pty_closed symbol not found (optional)"
        )
        // Echo detection via termios (Phase 2: reliable password prompt detection)
        let isEchoDisabled = optionalSymbol(
            "chau7_terminal_is_echo_disabled", as: IsEchoDisabledFn.self, in: handle,
            missingNote: "is_echo_disabled symbol not found (optional, falling back to heuristic)"
        )
        // Direct line text retrieval (avoids full grid snapshot per row)
        let getLineTextDirect = optionalSymbol(
            "chau7_terminal_get_line_text", as: GetLineTextFn.self, in: handle,
            missingNote: "get_line_text symbol not found (optional, falling back to grid snapshot)"
        )
        let getLogicalLineTextDirect = optionalSymbol(
            "chau7_terminal_get_logical_line_text", as: GetLogicalLineTextFn.self, in: handle,
            missingNote: "get_logical_line_text symbol not found (optional, falling back to physical row hit-testing)"
        )
        // Hyperlink support (OSC 8 — Phase 5)
        let getLinkUrl = optionalSymbol(
            "chau7_terminal_get_link_url", as: GetLinkUrlFn.self, in: handle,
            missingNote: "get_link_url symbol not found (optional)"
        )
        // Clipboard support (OSC 52 — Phase 5) — one note for the trio, keyed off the first symbol
        let getPendingClipboard = optionalSymbol(
            "chau7_terminal_get_pending_clipboard", as: GetPendingClipboardFn.self, in: handle,
            missingNote: "clipboard (OSC 52) symbols not found (optional)"
        )
        let hasClipboardRequest = optionalSymbol(
            "chau7_terminal_has_clipboard_request", as: HasClipboardRequestFn.self, in: handle
        )
        let respondClipboard = optionalSymbol(
            "chau7_terminal_respond_clipboard", as: RespondClipboardFn.self, in: handle
        )
        // Shell integration (OSC 133) — one note for the pair, keyed off the first symbol
        let getPendingShellIntegrationEvents = optionalSymbol(
            "chau7_terminal_get_pending_shell_events", as: GetPendingShellIntegrationEventsFn.self, in: handle,
            missingNote: "shell integration (OSC 133) symbols not found (optional)"
        )
        let freeShellIntegrationEvents = optionalSymbol(
            "chau7_terminal_free_shell_events", as: FreeShellIntegrationEventsFn.self, in: handle
        )
        // Graphics protocol support (Phase 4) — one note for the quartet, keyed off the first symbol
        let getPendingImages = optionalSymbol(
            "chau7_terminal_get_pending_images", as: GetPendingImagesFn.self, in: handle,
            missingNote: "graphics protocol symbols not found (optional)"
        )
        let freeImages = optionalSymbol(
            "chau7_terminal_free_images", as: FreeImagesFn.self, in: handle
        )
        let setImageProtocols = optionalSymbol(
            "chau7_terminal_set_image_protocols", as: SetImageProtocolsFn.self, in: handle
        )
        let hasPendingImages = optionalSymbol(
            "chau7_terminal_has_pending_images", as: HasPendingImagesFn.self, in: handle
        )

        Log.info("RustTerminalFFI: All 15 required symbols loaded successfully")

        return RustTerminalSymbolTable(
            create: unsafeBitCast(createSym, to: CreateFn.self),
            createWithEnv: createWithEnv,
            createWithLaunch: createWithLaunch,
            destroy: unsafeBitCast(destroySym, to: DestroyFn.self),
            sendBytes: unsafeBitCast(sendBytesSym, to: SendBytesFn.self),
            sendText: unsafeBitCast(sendTextSym, to: SendTextFn.self),
            resize: unsafeBitCast(resizeSym, to: ResizeFn.self),
            nudgeWinsize: nudgeWinsize,
            getGrid: unsafeBitCast(getGridSym, to: GetGridFn.self),
            freeGrid: unsafeBitCast(freeGridSym, to: FreeGridFn.self),
            scrollPosition: unsafeBitCast(scrollPositionSym, to: ScrollPositionFn.self),
            scrollTo: unsafeBitCast(scrollToSym, to: ScrollToFn.self),
            scrollLines: unsafeBitCast(scrollLinesSym, to: ScrollLinesFn.self),
            selectionText: unsafeBitCast(selectionTextSym, to: SelectionTextFn.self),
            selectionClear: unsafeBitCast(selectionClearSym, to: SelectionClearFn.self),
            selectionStart: selectionStart,
            selectionUpdate: selectionUpdate,
            selectionAll: selectionAll,
            freeString: unsafeBitCast(freeStringSym, to: FreeStringFn.self),
            cursorPosition: unsafeBitCast(cursorPositionSym, to: CursorPositionFn.self),
            poll: unsafeBitCast(pollSym, to: PollFn.self),
            pollEvents: pollEvents,
            setColors: setColors,
            clearScrollback: clearScrollback,
            getLastOutput: getLastOutput,
            freeOutput: freeOutput,
            injectOutput: injectOutput,
            setScrollbackSize: setScrollbackSize,
            replayBuffer: replayBuffer,
            displayOffset: displayOffset,
            isBracketedPasteMode: isBracketedPasteMode,
            isAlternateScreenActive: isAlternateScreenActive,
            checkBell: checkBell,
            getMouseMode: getMouseMode,
            isMouseReportingActive: isMouseReportingActive,
            isApplicationCursorMode: isApplicationCursorMode,
            getShellPid: getShellPid,
            getDebugState: getDebugState,
            freeDebugState: freeDebugState,
            getFullBufferText: getFullBufferText,
            getFullBufferAnsiText: getFullBufferAnsiText,
            getTailBufferAnsiText: getTailBufferAnsiText,
            resetMetrics: resetMetrics,
            getPendingTitle: getPendingTitle,
            getPendingCwd: getPendingCwd,
            getPendingExitCode: getPendingExitCode,
            isPtyClosed: isPtyClosed,
            isEchoDisabled: isEchoDisabled,
            getLineTextDirect: getLineTextDirect,
            getLogicalLineTextDirect: getLogicalLineTextDirect,
            getLinkUrl: getLinkUrl,
            getPendingClipboard: getPendingClipboard,
            hasClipboardRequest: hasClipboardRequest,
            respondClipboard: respondClipboard,
            getPendingShellIntegrationEvents: getPendingShellIntegrationEvents,
            freeShellIntegrationEvents: freeShellIntegrationEvents,
            getPendingImages: getPendingImages,
            freeImages: freeImages,
            setImageProtocols: setImageProtocols,
            hasPendingImages: hasPendingImages
        )
    }
}
