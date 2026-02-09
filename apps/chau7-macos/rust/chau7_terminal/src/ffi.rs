//! C FFI functions for the terminal emulator.
//!
//! All `#[no_mangle] pub unsafe extern "C"` functions live here.
//! cbindgen scans these to generate the C header.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::Ordering;

use log::{debug, error, info, trace, warn};

use crate::graphics;
use crate::pool::get_cell_buffer_pool;
use crate::terminal::Chau7Terminal;
use crate::types::*;

// ============================================================================
// Initialization
// ============================================================================

/// Initialize logging (call once at startup)
fn init_logging() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        if let Err(e) = env_logger::try_init() {
            eprintln!("chau7_terminal: Failed to initialize logger: {}", e);
        } else {
            info!("chau7_terminal: Logging initialized (set RUST_LOG=trace for verbose output)");
        }
    });
}

// ============================================================================
// Terminal lifecycle
// ============================================================================

/// Create a new terminal with the specified dimensions and shell
///
/// # Safety
/// - `shell` must be a valid null-terminated C string, or null for default shell
/// - Returns null on failure
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_create(
    cols: u16,
    rows: u16,
    shell: *const c_char,
) -> *mut Chau7Terminal { unsafe {
    init_logging();

    info!("chau7_terminal_create(cols={}, rows={}, shell={:?})", cols, rows, shell);

    let shell_str = if shell.is_null() {
        debug!("chau7_terminal_create: shell is null, will use default");
        ""
    } else {
        match CStr::from_ptr(shell).to_str() {
            Ok(s) => {
                debug!("chau7_terminal_create: shell string = {:?}", s);
                s
            }
            Err(e) => {
                error!("chau7_terminal_create: Invalid shell string (not UTF-8): {}", e);
                return std::ptr::null_mut();
            }
        }
    };

    match Chau7Terminal::new(cols, rows, shell_str) {
        Ok(terminal) => {
            let ptr = Box::into_raw(Box::new(terminal));
            info!("chau7_terminal_create: Success, returning {:p}", ptr);
            ptr
        }
        Err(e) => {
            error!("chau7_terminal_create: Failed: {}", e);
            std::ptr::null_mut()
        }
    }
}}

/// Create a new terminal with environment variables
///
/// # Safety
/// - `shell` must be a valid null-terminated C string, or null for default shell
/// - `env_keys` and `env_values` must be arrays of valid null-terminated C strings
/// - `env_count` must be the length of both arrays
/// - Returns null on failure
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_create_with_env(
    cols: u16,
    rows: u16,
    shell: *const c_char,
    env_keys: *const *const c_char,
    env_values: *const *const c_char,
    env_count: usize,
) -> *mut Chau7Terminal { unsafe {
    init_logging();

    info!("chau7_terminal_create_with_env(cols={}, rows={}, env_count={})", cols, rows, env_count);

    let shell_str = if shell.is_null() {
        ""
    } else {
        match CStr::from_ptr(shell).to_str() {
            Ok(s) => s,
            Err(e) => {
                error!("chau7_terminal_create_with_env: Invalid shell string: {}", e);
                return std::ptr::null_mut();
            }
        }
    };

    // Parse environment variables
    let mut env_vars: Vec<(String, String)> = Vec::with_capacity(env_count);
    if env_count > 0 && !env_keys.is_null() && !env_values.is_null() {
        for i in 0..env_count {
            let key_ptr = *env_keys.add(i);
            let value_ptr = *env_values.add(i);

            if key_ptr.is_null() || value_ptr.is_null() {
                warn!("chau7_terminal_create_with_env: Null env pointer at index {}", i);
                continue;
            }

            let key = match CStr::from_ptr(key_ptr).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            };
            let value = match CStr::from_ptr(value_ptr).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            };

            debug!("chau7_terminal_create_with_env: env[{}] = {}={}", i, key, value);
            env_vars.push((key, value));
        }
    }

    let env_refs: Vec<(&str, &str)> = env_vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();

    match Chau7Terminal::new_with_env(cols, rows, shell_str, &env_refs) {
        Ok(terminal) => {
            let ptr = Box::into_raw(Box::new(terminal));
            info!("chau7_terminal_create_with_env: Success, returning {:p}", ptr);
            ptr
        }
        Err(e) => {
            error!("chau7_terminal_create_with_env: Failed: {}", e);
            std::ptr::null_mut()
        }
    }
}}

/// Destroy a terminal instance
///
/// # Safety
/// - `term` must be a valid pointer returned by `chau7_terminal_create`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_destroy(term: *mut Chau7Terminal) { unsafe {
    info!("chau7_terminal_destroy({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_destroy: Received null pointer, ignoring");
        return;
    }
    drop(Box::from_raw(term));
    debug!("chau7_terminal_destroy: Complete");
}}

// ============================================================================
// Input/Output
// ============================================================================

/// Send raw bytes to the PTY (user input)
///
/// # Safety
/// - `term` must be a valid pointer
/// - `data` must be a valid pointer to at least `len` bytes
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_send_bytes(
    term: *mut Chau7Terminal,
    data: *const u8,
    len: usize,
) { unsafe {
    trace!("chau7_terminal_send_bytes({:p}, {:p}, {})", term, data, len);
    if term.is_null() {
        warn!("chau7_terminal_send_bytes: term is null");
        return;
    }
    if data.is_null() {
        warn!("chau7_terminal_send_bytes: data is null");
        return;
    }
    if len == 0 {
        trace!("chau7_terminal_send_bytes: len is 0, nothing to send");
        return;
    }
    let terminal = &*term;
    let bytes = std::slice::from_raw_parts(data, len);
    terminal.send_bytes(bytes);
}}

/// Send a null-terminated string to the PTY
///
/// # Safety
/// - `term` must be a valid pointer
/// - `text` must be a valid null-terminated C string
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_send_text(term: *mut Chau7Terminal, text: *const c_char) { unsafe {
    trace!("chau7_terminal_send_text({:p}, {:p})", term, text);
    if term.is_null() {
        warn!("chau7_terminal_send_text: term is null");
        return;
    }
    if text.is_null() {
        warn!("chau7_terminal_send_text: text is null");
        return;
    }
    let terminal = &*term;
    let cstr = CStr::from_ptr(text);
    let bytes = cstr.to_bytes();
    debug!("chau7_terminal_send_text: sending {} bytes", bytes.len());
    terminal.send_bytes(bytes);
}}

/// Resize the terminal
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_resize(term: *mut Chau7Terminal, cols: u16, rows: u16) { unsafe {
    info!("chau7_terminal_resize({:p}, {}, {})", term, cols, rows);
    if term.is_null() {
        warn!("chau7_terminal_resize: term is null");
        return;
    }
    let terminal = &mut *term;
    terminal.resize(cols, rows);
}}

// ============================================================================
// Grid snapshots
// ============================================================================

/// Get a snapshot of the current grid state
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned GridSnapshot must be freed with `chau7_terminal_free_grid`
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn chau7_terminal_get_grid(term: *mut Chau7Terminal) -> *mut GridSnapshot { unsafe {
    trace!("chau7_terminal_get_grid({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_grid: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let snapshot = terminal.get_grid_snapshot();
    let ptr = Box::into_raw(Box::new(snapshot));
    trace!("chau7_terminal_get_grid: returning {:p}", ptr);
    ptr
}}

/// Free a grid snapshot
///
/// # Safety
/// - `grid` must be a valid pointer returned by `chau7_terminal_get_grid`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_free_grid(grid: *mut GridSnapshot) { unsafe {
    trace!("chau7_terminal_free_grid({:p})", grid);
    if grid.is_null() {
        warn!("chau7_terminal_free_grid: grid is null");
        return;
    }
    let snapshot = Box::from_raw(grid);

    // Return the cells buffer to the pool for reuse instead of deallocating
    if !snapshot.cells.is_null() {
        let total_cells = (snapshot.cols as usize) * (snapshot.rows as usize);
        let capacity = snapshot.capacity;
        trace!("chau7_terminal_free_grid: returning cells to pool (len={}, cap={})", total_cells, capacity);
        let buffer = Vec::from_raw_parts(snapshot.cells, total_cells, capacity);
        get_cell_buffer_pool().release(buffer);
    }
    trace!("chau7_terminal_free_grid: complete");
}}

/// Get cell buffer pool statistics
#[unsafe(no_mangle)]
pub extern "C" fn chau7_terminal_pool_stats() -> PoolStats {
    let (acquired, returned, allocated, pooled) = get_cell_buffer_pool().stats();
    PoolStats {
        acquired,
        returned,
        allocated,
        pooled: pooled as u64,
    }
}

// ============================================================================
// Scrolling
// ============================================================================

/// Get current scroll position (0.0 = bottom, 1.0 = top of history)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_scroll_position(term: *mut Chau7Terminal) -> f64 { unsafe {
    trace!("chau7_terminal_scroll_position({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_scroll_position: term is null");
        return 0.0;
    }
    let terminal = &*term;
    terminal.scroll_position()
}}

/// Scroll to a normalized position (0.0 = bottom, 1.0 = top of history)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_scroll_to(term: *mut Chau7Terminal, position: f64) { unsafe {
    debug!("chau7_terminal_scroll_to({:p}, {})", term, position);
    if term.is_null() {
        warn!("chau7_terminal_scroll_to: term is null");
        return;
    }
    let terminal = &*term;
    terminal.scroll_to(position);
}}

/// Scroll by a number of lines (positive = up/back, negative = down/forward)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_scroll_lines(term: *mut Chau7Terminal, lines: i32) { unsafe {
    debug!("chau7_terminal_scroll_lines({:p}, {})", term, lines);
    if term.is_null() {
        warn!("chau7_terminal_scroll_lines: term is null");
        return;
    }
    let terminal = &*term;
    terminal.scroll_lines(lines);
}}

// ============================================================================
// Selection
// ============================================================================

/// Get currently selected text
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned string must be freed with `chau7_terminal_free_string`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_selection_text(term: *mut Chau7Terminal) -> *mut c_char { unsafe {
    trace!("chau7_terminal_selection_text({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_selection_text: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    match terminal.selection_text() {
        Some(text) => match CString::new(text) {
            Ok(cstr) => {
                let ptr = cstr.into_raw();
                trace!("chau7_terminal_selection_text: returning {:p}", ptr);
                ptr
            }
            Err(e) => {
                error!("chau7_terminal_selection_text: CString::new failed: {}", e);
                std::ptr::null_mut()
            }
        },
        None => {
            trace!("chau7_terminal_selection_text: no selection");
            std::ptr::null_mut()
        }
    }
}}

/// Clear any active selection
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_selection_clear(term: *mut Chau7Terminal) { unsafe {
    debug!("chau7_terminal_selection_clear({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_selection_clear: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_clear();
}}

/// Start a new selection at the given position
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_selection_start(
    term: *mut Chau7Terminal,
    col: i32,
    row: i32,
    selection_type: u8,
) { unsafe {
    debug!("chau7_terminal_selection_start({:p}, col={}, row={}, type={})", term, col, row, selection_type);
    if term.is_null() {
        warn!("chau7_terminal_selection_start: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_start(col, row, selection_type);
}}

/// Update the current selection to extend to the given position
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_selection_update(
    term: *mut Chau7Terminal,
    col: i32,
    row: i32,
) { unsafe {
    trace!("chau7_terminal_selection_update({:p}, col={}, row={})", term, col, row);
    if term.is_null() {
        warn!("chau7_terminal_selection_update: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_update(col, row);
}}

/// Select all content (screen + scrollback)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_selection_all(term: *mut Chau7Terminal) { unsafe {
    debug!("chau7_terminal_selection_all({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_selection_all: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_all();
}}

/// Free a string returned by the library
///
/// # Safety
/// - `s` must be a valid pointer returned by `chau7_terminal_selection_text` or similar
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_free_string(s: *mut c_char) { unsafe {
    trace!("chau7_terminal_free_string({:p})", s);
    if s.is_null() {
        warn!("chau7_terminal_free_string: s is null");
        return;
    }
    drop(CString::from_raw(s));
    trace!("chau7_terminal_free_string: complete");
}}

/// Get the text of a specific line in the terminal grid
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned string must be freed with `chau7_terminal_free_string`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_line_text(
    term: *mut Chau7Terminal,
    row: i32,
) -> *mut c_char { unsafe {
    trace!("chau7_terminal_get_line_text({:p}, row={})", term, row);
    if term.is_null() {
        warn!("chau7_terminal_get_line_text: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    match terminal.line_text(row) {
        Some(text) => match CString::new(text) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => {
                warn!("chau7_terminal_get_line_text: text contained null byte");
                std::ptr::null_mut()
            }
        },
        None => std::ptr::null_mut(),
    }
}}

// ============================================================================
// Cursor
// ============================================================================

/// Get cursor position
///
/// # Safety
/// - `term` must be a valid pointer
/// - `col` and `row` must be valid pointers to u16, or null
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_cursor_position(
    term: *mut Chau7Terminal,
    col: *mut u16,
    row: *mut u16,
) { unsafe {
    trace!("chau7_terminal_cursor_position({:p}, {:p}, {:p})", term, col, row);
    if term.is_null() {
        warn!("chau7_terminal_cursor_position: term is null");
        return;
    }
    let terminal = &*term;
    let (c, r) = terminal.cursor_position();
    if !col.is_null() {
        *col = c;
    }
    if !row.is_null() {
        *row = r;
    }
}}

// ============================================================================
// Polling
// ============================================================================

/// Poll for new data from PTY and process it
///
/// Returns true if the grid has changed and needs to be redrawn
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn chau7_terminal_poll(term: *mut Chau7Terminal, timeout_ms: u32) -> bool { unsafe {
    trace!("chau7_terminal_poll({:p}, {})", term, timeout_ms);
    if term.is_null() {
        warn!("chau7_terminal_poll: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.poll(timeout_ms)
}}

/// Get raw output bytes from the last poll
///
/// # Safety
/// - `term` must be a valid pointer
/// - `out_len` must be a valid pointer to a usize
/// - The returned pointer must be freed via chau7_terminal_free_output
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_last_output(
    term: *mut Chau7Terminal,
    out_len: *mut usize,
) -> *mut u8 { unsafe {
    trace!("chau7_terminal_get_last_output({:p}, {:p})", term, out_len);
    if term.is_null() {
        warn!("chau7_terminal_get_last_output: term is null");
        if !out_len.is_null() {
            *out_len = 0;
        }
        return std::ptr::null_mut();
    }
    if out_len.is_null() {
        warn!("chau7_terminal_get_last_output: out_len is null");
        return std::ptr::null_mut();
    }

    let terminal = &*term;
    let output = terminal.get_last_output();
    let len = output.len();

    if len == 0 {
        *out_len = 0;
        return std::ptr::null_mut();
    }

    let mut boxed = output.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);

    *out_len = len;
    trace!("chau7_terminal_get_last_output: returning {} bytes at {:p}", len, ptr);
    ptr
}}

/// Inject output bytes directly into the terminal (without sending to PTY)
///
/// # Safety
/// - `term` must be a valid pointer
/// - `data` must be a valid pointer to at least `len` bytes (unless `len` is 0)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_inject_output(
    term: *mut Chau7Terminal,
    data: *const u8,
    len: usize,
) { unsafe {
    trace!("chau7_terminal_inject_output({:p}, {:p}, {})", term, data, len);
    if term.is_null() {
        warn!("chau7_terminal_inject_output: term is null");
        return;
    }
    if data.is_null() {
        if len == 0 {
            return;
        }
        warn!("chau7_terminal_inject_output: data is null with len > 0");
        return;
    }

    let slice = std::slice::from_raw_parts(data, len);
    let terminal = &*term;
    terminal.inject_output(slice);
}}

/// Free output bytes returned by chau7_terminal_get_last_output
///
/// # Safety
/// - `data` must be a pointer returned by `chau7_terminal_get_last_output`
/// - `len` must be the length returned with that pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_free_output(data: *mut u8, len: usize) { unsafe {
    trace!("chau7_terminal_free_output({:p}, {})", data, len);
    if data.is_null() || len == 0 {
        return;
    }
    let slice = std::slice::from_raw_parts_mut(data, len);
    drop(Box::from_raw(slice));
    trace!("chau7_terminal_free_output: complete");
}}

// ============================================================================
// Theme colors
// ============================================================================

/// Set theme colors for rendering
///
/// # Safety
/// - `term` must be a valid pointer
/// - `palette` must be a valid pointer to an array of 48 bytes (16 RGB triplets)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_set_colors(
    term: *mut Chau7Terminal,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    cursor_r: u8,
    cursor_g: u8,
    cursor_b: u8,
    palette: *const u8,
) { unsafe {
    debug!(
        "chau7_terminal_set_colors({:p}, fg=({},{},{}), bg=({},{},{}), cursor=({},{},{}))",
        term, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, cursor_r, cursor_g, cursor_b
    );
    if term.is_null() {
        warn!("chau7_terminal_set_colors: term is null");
        return;
    }
    if palette.is_null() {
        warn!("chau7_terminal_set_colors: palette is null");
        return;
    }

    let terminal = &*term;

    let palette_slice = std::slice::from_raw_parts(palette, 48);
    let mut palette_colors: [(u8, u8, u8); 16] = [(0, 0, 0); 16];
    for i in 0..16 {
        palette_colors[i] = (
            palette_slice[i * 3],
            palette_slice[i * 3 + 1],
            palette_slice[i * 3 + 2],
        );
    }

    terminal.set_colors(
        (fg_r, fg_g, fg_b),
        (bg_r, bg_g, bg_b),
        (cursor_r, cursor_g, cursor_b),
        palette_colors,
    );
}}

// ============================================================================
// Scrollback management
// ============================================================================

/// Clear the scrollback history buffer
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_clear_scrollback(term: *mut Chau7Terminal) { unsafe {
    info!("chau7_terminal_clear_scrollback({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_clear_scrollback: term is null");
        return;
    }
    let terminal = &*term;
    terminal.clear_scrollback();
}}

/// Set the scrollback buffer size (number of lines)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_set_scrollback_size(term: *mut Chau7Terminal, lines: u32) { unsafe {
    info!("chau7_terminal_set_scrollback_size({:p}, {})", term, lines);
    if term.is_null() {
        warn!("chau7_terminal_set_scrollback_size: term is null");
        return;
    }
    let terminal = &*term;
    terminal.set_scrollback_size(lines as usize);
}}

/// Get the current display offset (scroll position in lines)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_display_offset(term: *mut Chau7Terminal) -> u32 { unsafe {
    trace!("chau7_terminal_display_offset({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_display_offset: term is null");
        return 0;
    }
    let terminal = &*term;
    terminal.display_offset() as u32
}}

// ============================================================================
// Terminal mode queries
// ============================================================================

/// Check if bracketed paste mode is enabled
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_is_bracketed_paste_mode(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_is_bracketed_paste_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_bracketed_paste_mode: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.is_bracketed_paste_mode()
}}

/// Check if application cursor mode (DECCKM) is enabled
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_is_application_cursor_mode(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_is_application_cursor_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_application_cursor_mode: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.is_application_cursor_mode()
}}

/// Check if a bell event has occurred since the last check
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn chau7_terminal_check_bell(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_check_bell({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_check_bell: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.check_bell()
}}

/// Get the current mouse mode as a bitmask (alias for chau7_terminal_mouse_mode)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_mouse_mode(term: *mut Chau7Terminal) -> u32 { unsafe {
    trace!("chau7_terminal_get_mouse_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_mouse_mode: term is null");
        return 0;
    }
    let terminal = &*term;
    terminal.mouse_mode()
}}

/// Check if any mouse tracking mode is active
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_is_mouse_reporting_active(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_is_mouse_reporting_active({:p})", term);
    if term.is_null() {
        return false;
    }
    let terminal = &*term;
    terminal.is_mouse_reporting_active()
}}

// ============================================================================
// Debug and Performance
// ============================================================================

/// Get the shell process ID
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_shell_pid(term: *mut Chau7Terminal) -> u64 { unsafe {
    trace!("chau7_terminal_get_shell_pid({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_shell_pid: term is null");
        return 0;
    }
    let terminal = &*term;
    let pid = terminal.shell_pid();
    debug!("chau7_terminal_get_shell_pid: returning {}", pid);
    pid
}}

/// Get a comprehensive debug state snapshot
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned pointer must be freed with `chau7_terminal_free_debug_state`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_debug_state(term: *mut Chau7Terminal) -> *mut DebugState { unsafe {
    info!("chau7_terminal_get_debug_state({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_debug_state: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let state = terminal.debug_state();
    let ptr = Box::into_raw(Box::new(state));
    debug!("chau7_terminal_get_debug_state: returning {:p}", ptr);
    ptr
}}

/// Free a debug state
///
/// # Safety
/// - `state` must be a valid pointer returned by `chau7_terminal_get_debug_state`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_free_debug_state(state: *mut DebugState) { unsafe {
    trace!("chau7_terminal_free_debug_state({:p})", state);
    if state.is_null() {
        return;
    }
    drop(Box::from_raw(state));
}}

/// Get the full buffer text (visible + scrollback) for debugging
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned pointer must be freed with `chau7_terminal_free_string`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_full_buffer_text(term: *mut Chau7Terminal) -> *mut c_char { unsafe {
    info!("chau7_terminal_get_full_buffer_text({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_full_buffer_text: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let text = terminal.full_buffer_text();
    match CString::new(text) {
        Ok(cstr) => cstr.into_raw(),
        Err(e) => {
            error!("chau7_terminal_get_full_buffer_text: CString::new failed: {}", e);
            std::ptr::null_mut()
        }
    }
}}

/// Reset performance metrics
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_reset_metrics(term: *mut Chau7Terminal) { unsafe {
    info!("chau7_terminal_reset_metrics({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_reset_metrics: term is null");
        return;
    }
    let terminal = &*term;
    terminal.reset_metrics();
}}

/// Get current activity level (0-100)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_activity_level(term: *mut Chau7Terminal) -> u8 { unsafe {
    if term.is_null() {
        return 0;
    }
    let terminal = &*term;
    terminal.activity_level()
}}

/// Check if poll should be skipped (power saving)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_should_skip_poll(term: *mut Chau7Terminal) -> bool { unsafe {
    if term.is_null() {
        return false;
    }
    let terminal = &*term;
    terminal.should_skip_poll()
}}

/// Get count of dirty rows
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_dirty_row_count(term: *mut Chau7Terminal) -> u32 { unsafe {
    if term.is_null() {
        return 0;
    }
    let terminal = &*term;
    terminal.dirty_rows.dirty_count() as u32
}}

/// Clear dirty row tracking
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_clear_dirty_rows(term: *mut Chau7Terminal) { unsafe {
    if term.is_null() {
        return;
    }
    let terminal = &*term;
    terminal.clear_dirty_rows();
}}

// ============================================================================
// Terminal Event FFI Functions
// ============================================================================

/// Get pending title change from OSC 0/1/2 escape sequences
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned string must be freed with `chau7_terminal_free_string`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_pending_title(term: *mut Chau7Terminal) -> *mut c_char { unsafe {
    trace!("chau7_terminal_get_pending_title({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_pending_title: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    // Fast path: check atomic flag before locking the Mutex.
    // Title changes are rare (once per command), but this is called 60x/sec.
    if !terminal.has_pending_title.load(std::sync::atomic::Ordering::Acquire) {
        return std::ptr::null_mut();
    }
    let mut pending = terminal.pending_title.lock();
    let title = pending.take();
    // Clear flag *after* lock to avoid TOCTOU: producer could set a new title
    // between flag-clear and lock-acquire, leaving it stranded.
    if title.is_some() {
        terminal.has_pending_title.store(false, std::sync::atomic::Ordering::Release);
    }
    match title {
        Some(title) => {
            debug!("chau7_terminal_get_pending_title: returning title {:?}", title);
            match CString::new(title) {
                Ok(cstr) => cstr.into_raw(),
                Err(e) => {
                    warn!("chau7_terminal_get_pending_title: title contains null byte at pos {}", e.nul_position());
                    std::ptr::null_mut()
                }
            }
        }
        None => std::ptr::null_mut(),
    }
}}

/// Get pending child exit code
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_pending_exit_code(term: *mut Chau7Terminal) -> i32 { unsafe {
    trace!("chau7_terminal_get_pending_exit_code({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_pending_exit_code: term is null");
        return -1;
    }
    let terminal = &*term;
    let mut pending = terminal.pending_exit_code.lock();
    match pending.take() {
        Some(code) => {
            info!("chau7_terminal_get_pending_exit_code: returning exit code {}", code);
            code
        }
        None => -1,
    }
}}

/// Check if the PTY has closed
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_is_pty_closed(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_is_pty_closed({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_pty_closed: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.pty_closed.load(Ordering::Acquire)
}}

/// Check if the PTY has echo disabled (password mode)
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_is_echo_disabled(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_is_echo_disabled({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_echo_disabled: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.is_echo_disabled()
}}

// ============================================================================
// Hyperlink (OSC 8) FFI
// ============================================================================

/// Get the URL for a hyperlink ID from the most recent grid snapshot.
/// Returns null if the ID is 0 or invalid.
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned string must be freed with `chau7_terminal_free_string`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_link_url(term: *mut Chau7Terminal, link_id: u16) -> *mut c_char { unsafe {
    trace!("chau7_terminal_get_link_url({:p}, {})", term, link_id);
    if term.is_null() {
        warn!("chau7_terminal_get_link_url: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    match terminal.get_link_url(link_id) {
        Some(url) => {
            trace!("chau7_terminal_get_link_url: link_id={} -> {:?}", link_id, url);
            match CString::new(url) {
                Ok(cstr) => cstr.into_raw(),
                Err(e) => {
                    warn!("chau7_terminal_get_link_url: URL contains null byte at pos {}", e.nul_position());
                    std::ptr::null_mut()
                }
            }
        }
        None => std::ptr::null_mut(),
    }
}}

// ============================================================================
// Clipboard (OSC 52) FFI
// ============================================================================

/// Get pending clipboard store text (OSC 52 write to system clipboard).
/// Returns a C string that must be freed with `chau7_terminal_free_string`,
/// or null if no clipboard store is pending.
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned string must be freed with `chau7_terminal_free_string`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_pending_clipboard(term: *mut Chau7Terminal) -> *mut c_char { unsafe {
    trace!("chau7_terminal_get_pending_clipboard({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_pending_clipboard: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    match terminal.take_pending_clipboard_store() {
        Some(text) => {
            debug!("chau7_terminal_get_pending_clipboard: returning {} chars", text.len());
            match CString::new(text) {
                Ok(cstr) => cstr.into_raw(),
                Err(e) => {
                    warn!("chau7_terminal_get_pending_clipboard: text contains null byte at pos {}", e.nul_position());
                    std::ptr::null_mut()
                }
            }
        }
        None => std::ptr::null_mut(),
    }
}}

/// Check if the terminal has a pending clipboard load request (OSC 52 read).
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_has_clipboard_request(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_has_clipboard_request({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_has_clipboard_request: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.has_pending_clipboard_load()
}}

/// Respond to a pending clipboard load request by providing the current system clipboard text.
/// The text is wrapped in the proper OSC 52 response sequence and written to the PTY.
///
/// # Safety
/// - `term` must be a valid pointer
/// - `text` must be a valid null-terminated C string
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_respond_clipboard(term: *mut Chau7Terminal, text: *const c_char) { unsafe {
    trace!("chau7_terminal_respond_clipboard({:p}, {:p})", term, text);
    if term.is_null() {
        warn!("chau7_terminal_respond_clipboard: term is null");
        return;
    }
    if text.is_null() {
        warn!("chau7_terminal_respond_clipboard: text is null");
        return;
    }
    let terminal = &*term;
    let clipboard_text = CStr::from_ptr(text).to_string_lossy();
    debug!("chau7_terminal_respond_clipboard: responding with {} chars", clipboard_text.len());
    terminal.respond_clipboard_load(&clipboard_text);
}}

// ============================================================================
// Graphics Protocol FFI
// ============================================================================

/// Get pending images from the graphics interceptor
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned FFIImageArray must be freed with `chau7_terminal_free_images`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_get_pending_images(
    term: *mut Chau7Terminal,
) -> *mut FFIImageArray { unsafe {
    trace!("chau7_terminal_get_pending_images({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_pending_images: term is null");
        return std::ptr::null_mut();
    }

    let terminal = &*term;
    let images = terminal.image_store.lock().take_pending();

    if images.is_empty() {
        return std::ptr::null_mut();
    }

    debug!("chau7_terminal_get_pending_images: {} images pending", images.len());

    // Convert DecodedImage vec to FFIImageData vec
    let mut ffi_images: Vec<FFIImageData> = Vec::with_capacity(images.len());
    for img in images {
        let protocol: u8 = match img.protocol {
            graphics::ImageProtocol::ITerm2 => 0,
            graphics::ImageProtocol::Sixel => 1,
            graphics::ImageProtocol::Kitty => 2,
        };

        // Transfer ownership of the image data to the FFI layer
        let mut data = img.rgba;
        let data_ptr = data.as_mut_ptr();
        let data_len = data.len();
        let data_capacity = data.capacity();
        std::mem::forget(data);

        ffi_images.push(FFIImageData {
            id: img.id,
            data: data_ptr,
            data_len,
            data_capacity,
            anchor_row: img.anchor_row,
            anchor_col: img.anchor_col,
            protocol,
        });
    }

    let images_ptr = ffi_images.as_mut_ptr();
    let count = ffi_images.len();
    let capacity = ffi_images.capacity();
    std::mem::forget(ffi_images);

    let array = Box::new(FFIImageArray {
        images: images_ptr,
        count,
        capacity,
    });

    Box::into_raw(array)
}}

/// Free an FFIImageArray returned by chau7_terminal_get_pending_images
///
/// # Safety
/// - `array` must be a valid pointer returned by `chau7_terminal_get_pending_images`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_free_images(array: *mut FFIImageArray) { unsafe {
    trace!("chau7_terminal_free_images({:p})", array);
    if array.is_null() {
        return;
    }

    let array = *Box::from_raw(array);

    if !array.images.is_null() && array.count > 0 {
        let images = Vec::from_raw_parts(array.images, array.count, array.capacity);
        for img in images {
            if !img.data.is_null() && img.data_len > 0 {
                let _ = Vec::from_raw_parts(img.data, img.data_len, img.data_capacity);
            }
        }
    }
}}

/// Set which image protocols the graphics interceptor should detect
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_set_image_protocols(
    term: *mut Chau7Terminal,
    sixel: bool,
    kitty: bool,
    iterm2: bool,
) { unsafe {
    trace!("chau7_terminal_set_image_protocols({:p}, sixel={}, kitty={}, iterm2={})",
           term, sixel, kitty, iterm2);
    if term.is_null() {
        warn!("chau7_terminal_set_image_protocols: term is null");
        return;
    }
    let terminal = &*term;
    let mut interceptor = terminal.graphics_interceptor.lock();
    interceptor.sixel_enabled = sixel;
    interceptor.kitty_enabled = kitty;
    interceptor.iterm2_enabled = iterm2;
}}

/// Check if there are pending images
///
/// # Safety
/// - `term` must be a valid pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chau7_terminal_has_pending_images(term: *mut Chau7Terminal) -> bool { unsafe {
    trace!("chau7_terminal_has_pending_images({:p})", term);
    if term.is_null() {
        return false;
    }
    let terminal = &*term;
    terminal.image_store.lock().has_pending()
}}
