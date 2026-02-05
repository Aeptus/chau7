use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[repr(C)]
pub struct PatternSet {
    patterns: Vec<String>,
}

#[repr(C)]
pub struct MatchPatternSet {
    patterns: Vec<String>,
}

#[repr(C)]
pub struct AnsiColor {
    kind: u8,
    index: u8,
    r: u8,
    g: u8,
    b: u8,
}

#[repr(C)]
pub struct AnsiSegment {
    text: *mut c_char,
    flags: u32,
    fg: AnsiColor,
    bg: AnsiColor,
}

#[repr(C)]
pub struct AnsiSegments {
    segments: *mut AnsiSegment,
    count: usize,
}

fn normalize(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let mut out = String::with_capacity(trimmed.len());
    let mut last_was_space = false;
    for ch in trimmed.chars() {
        if ch.is_whitespace() {
            if !last_was_space {
                out.push(' ');
                last_was_space = true;
            }
        } else {
            for lower in ch.to_lowercase() {
                out.push(lower);
            }
            last_was_space = false;
        }
    }
    out
}

fn sanitize_text(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;

    while i < bytes.len() {
        let b = bytes[i];

        if b == 0x1b {
            if i + 1 < bytes.len() {
                let next = bytes[i + 1];
                if next == b'[' {
                    i += 2;
                    while i < bytes.len()
                        && (bytes[i].is_ascii_digit() || bytes[i] == b';' || bytes[i] == b'?')
                    {
                        i += 1;
                    }
                    if i < bytes.len() && (0x40..=0x7e).contains(&bytes[i]) {
                        i += 1;
                    }
                    continue;
                }
                if next == b']' {
                    i += 2;
                    while i < bytes.len() {
                        if bytes[i] == 0x07 {
                            i += 1;
                            break;
                        }
                        if bytes[i] == 0x1b {
                            if i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
                                i += 2;
                            }
                            break;
                        }
                        i += 1;
                    }
                    continue;
                }
                // Simple ESC + single char
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        if b == b'[' {
            if i + 4 < bytes.len()
                && bytes[i + 1] == b'2'
                && bytes[i + 2] == b'0'
                && (bytes[i + 3] == b'0' || bytes[i + 3] == b'1')
                && bytes[i + 4] == b'~'
            {
                i += 5;
                continue;
            }
            let mut j = i + 1;
            while j < bytes.len()
                && (bytes[j].is_ascii_digit() || bytes[j] == b';' || bytes[j] == b'?')
            {
                j += 1;
            }
            if j < bytes.len()
                && ((bytes[j] >= b'A' && bytes[j] <= b'Z')
                    || (bytes[j] >= b'a' && bytes[j] <= b'z'))
            {
                i = j + 1;
                continue;
            }
        }

        if b == b']' {
            if i + 1 < bytes.len()
                && (bytes[i + 1].is_ascii_digit() || bytes[i + 1] == b';')
            {
                let mut j = i + 1;
                while j < bytes.len()
                    && (bytes[j].is_ascii_digit() || bytes[j] == b';')
                {
                    j += 1;
                }
                while j < bytes.len() {
                    if bytes[j] == 0x07 {
                        j += 1;
                        break;
                    }
                    if bytes[j] == 0x1b {
                        if j + 1 < bytes.len() && bytes[j + 1] == b'\\' {
                            j += 2;
                        }
                        break;
                    }
                    j += 1;
                }
                i = j;
                continue;
            }
        }

        if b < 0x20 || b == 0x7f {
            if b == b'\n' || b == b'\r' || b == b'\t' {
                out.push(b);
            }
            i += 1;
            continue;
        }

        out.push(b);
        i += 1;
    }

    let mut collapsed: Vec<u8> = Vec::with_capacity(out.len());
    let mut last_space = false;
    for &b in &out {
        if b == b' ' {
            if !last_space {
                collapsed.push(b);
            }
            last_space = true;
        } else {
            collapsed.push(b);
            last_space = false;
        }
    }

    let mut start = 0;
    while start < collapsed.len() && collapsed[start] == b' ' {
        start += 1;
    }
    let mut end = collapsed.len();
    while end > start && collapsed[end - 1] == b' ' {
        end -= 1;
    }

    String::from_utf8_lossy(&collapsed[start..end]).to_string()
}

#[derive(Clone)]
struct StyleSpec {
    bold: bool,
    dim: bool,
    underline: bool,
    inverse: bool,
    italic: bool,
    fg: ColorSpec,
    bg: ColorSpec,
}

#[derive(Clone)]
enum ColorSpec {
    Default,
    Ansi(u8),
    Ansi256(u8),
    Rgb(u8, u8, u8),
}

impl Default for StyleSpec {
    fn default() -> Self {
        StyleSpec {
            bold: false,
            dim: false,
            underline: false,
            inverse: false,
            italic: false,
            fg: ColorSpec::Default,
            bg: ColorSpec::Default,
        }
    }
}

fn style_to_flags(style: &StyleSpec) -> u32 {
    let mut flags = 0u32;
    if style.bold { flags |= 1; }
    if style.dim { flags |= 2; }
    if style.underline { flags |= 4; }
    if style.inverse { flags |= 8; }
    if style.italic { flags |= 16; }
    flags
}

fn color_to_ansi(color: &ColorSpec) -> AnsiColor {
    match color {
        ColorSpec::Default => AnsiColor { kind: 0, index: 0, r: 0, g: 0, b: 0 },
        ColorSpec::Ansi(index) => AnsiColor { kind: 1, index: *index, r: 0, g: 0, b: 0 },
        ColorSpec::Ansi256(index) => AnsiColor { kind: 2, index: *index, r: 0, g: 0, b: 0 },
        ColorSpec::Rgb(r, g, b) => AnsiColor { kind: 3, index: 0, r: *r, g: *g, b: *b },
    }
}

fn apply_sgr(params: &[i32], style: &mut StyleSpec) {
    let mut i = 0usize;
    while i < params.len() {
        let code = params[i];
        match code {
            0 => *style = StyleSpec::default(),
            1 => { style.bold = true; style.dim = false; }
            2 => { style.dim = true; style.bold = false; }
            3 => style.italic = true,
            4 => style.underline = true,
            7 => style.inverse = true,
            22 => { style.bold = false; style.dim = false; }
            23 => style.italic = false,
            24 => style.underline = false,
            27 => style.inverse = false,
            30..=37 => style.fg = ColorSpec::Ansi((code - 30) as u8),
            90..=97 => style.fg = ColorSpec::Ansi((code - 90 + 8) as u8),
            39 => style.fg = ColorSpec::Default,
            40..=47 => style.bg = ColorSpec::Ansi((code - 40) as u8),
            100..=107 => style.bg = ColorSpec::Ansi((code - 100 + 8) as u8),
            49 => style.bg = ColorSpec::Default,
            38 | 48 => {
                let is_fg = code == 38;
                if i + 1 < params.len() {
                    let mode = params[i + 1];
                    if mode == 2 && i + 4 < params.len() {
                        let r = params[i + 2].clamp(0, 255) as u8;
                        let g = params[i + 3].clamp(0, 255) as u8;
                        let b = params[i + 4].clamp(0, 255) as u8;
                        if is_fg { style.fg = ColorSpec::Rgb(r, g, b); }
                        else { style.bg = ColorSpec::Rgb(r, g, b); }
                        i += 4;
                    } else if mode == 5 && i + 2 < params.len() {
                        let idx = params[i + 2].clamp(0, 255) as u8;
                        if is_fg { style.fg = ColorSpec::Ansi256(idx); }
                        else { style.bg = ColorSpec::Ansi256(idx); }
                        i += 2;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
}

fn parse_csi_params(param_bytes: &[u8]) -> Vec<i32> {
    let param_str = String::from_utf8_lossy(param_bytes);
    let mut params: Vec<i32> = Vec::new();
    for part in param_str.split(';') {
        if let Ok(val) = part.parse::<i32>() {
            params.push(val);
        }
    }
    if params.is_empty() {
        params.push(0);
    }
    params
}

fn parse_ansi_segments(input: &str) -> Vec<AnsiSegment> {
    let bytes = input.as_bytes();
    let mut segments: Vec<AnsiSegment> = Vec::new();
    let mut buffer: Vec<u8> = Vec::new();
    let mut style = StyleSpec::default();
    let mut i = 0usize;

    let flush = |buf: &mut Vec<u8>, current: &StyleSpec, segs: &mut Vec<AnsiSegment>| {
        if buf.is_empty() {
            return;
        }
        for b in buf.iter_mut() {
            if *b == 0 {
                *b = b' ';
            }
        }
        let text = String::from_utf8_lossy(buf).to_string();
        buf.clear();
        let Ok(cstr) = CString::new(text) else { return; };
        let segment = AnsiSegment {
            text: cstr.into_raw(),
            flags: style_to_flags(current),
            fg: color_to_ansi(&current.fg),
            bg: color_to_ansi(&current.bg),
        };
        segs.push(segment);
    };

    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b {
            if i + 1 < bytes.len() {
                let next = bytes[i + 1];
                if next == b'[' {
                    let mut j = i + 2;
                    while j < bytes.len() && !(bytes[j] >= 0x40 && bytes[j] <= 0x7e) {
                        j += 1;
                    }
                    if j < bytes.len() {
                        let command = bytes[j] as char;
                        let params = parse_csi_params(&bytes[i + 2..j]);
                        if command == 'm' {
                            flush(&mut buffer, &style, &mut segments);
                            apply_sgr(&params, &mut style);
                        }
                        i = j + 1;
                        continue;
                    }
                } else if next == b']' {
                    let mut j = i + 2;
                    while j < bytes.len() {
                        if bytes[j] == 0x07 {
                            j += 1;
                            break;
                        }
                        if bytes[j] == 0x1b {
                            if j + 1 < bytes.len() && bytes[j + 1] == b'\\' {
                                j += 2;
                            }
                            break;
                        }
                        j += 1;
                    }
                    i = j;
                    continue;
                } else {
                    i += 2;
                    continue;
                }
            }
            i += 1;
            continue;
        }

        if b < 0x20 || b == 0x7f {
            if b == b'\n' || b == b'\r' || b == b'\t' {
                buffer.push(b);
            }
            i += 1;
            continue;
        }

        buffer.push(b);
        i += 1;
    }

    flush(&mut buffer, &style, &mut segments);
    segments
}

#[no_mangle]
pub extern "C" fn chau7_risk_patterns_create(
    patterns: *const *const c_char,
    count: usize,
) -> *mut PatternSet {
    if patterns.is_null() {
        return std::ptr::null_mut();
    }
    let mut normalized: Vec<String> = Vec::with_capacity(count);
    for i in 0..count {
        unsafe {
            let ptr = *patterns.add(i);
            if ptr.is_null() {
                continue;
            }
            if let Ok(raw) = CStr::from_ptr(ptr).to_str() {
                let norm = normalize(raw);
                if !norm.is_empty() {
                    normalized.push(norm);
                }
            }
        }
    }
    let set = PatternSet { patterns: normalized };
    Box::into_raw(Box::new(set))
}

#[no_mangle]
pub extern "C" fn chau7_risk_patterns_free(handle: *mut PatternSet) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn chau7_risk_is_risky(
    handle: *const PatternSet,
    command: *const c_char,
) -> bool {
    if handle.is_null() || command.is_null() {
        return false;
    }

    let command_str = unsafe { CStr::from_ptr(command) };
    let Ok(command_str) = command_str.to_str() else {
        return false;
    };
    let normalized_command = normalize(command_str);
    if normalized_command.is_empty() {
        return false;
    }

    let patterns = unsafe { &(*handle).patterns };
    for pattern in patterns {
        if normalized_command.contains(pattern) {
            return true;
        }
    }
    false
}

#[no_mangle]
pub extern "C" fn chau7_risk_normalize(value: *const c_char) -> *mut c_char {
    if value.is_null() {
        return std::ptr::null_mut();
    }
    let value_str = unsafe { CStr::from_ptr(value) };
    let Ok(value_str) = value_str.to_str() else {
        return std::ptr::null_mut();
    };
    let normalized = normalize(value_str);
    let Ok(cstr) = CString::new(normalized) else {
        return std::ptr::null_mut();
    };
    cstr.into_raw()
}

#[no_mangle]
pub extern "C" fn chau7_risk_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub extern "C" fn chau7_escape_sanitize(value: *const c_char) -> *mut c_char {
    if value.is_null() {
        return std::ptr::null_mut();
    }
    let value_str = unsafe { CStr::from_ptr(value) };
    let Ok(value_str) = value_str.to_str() else {
        return std::ptr::null_mut();
    };
    let sanitized = sanitize_text(value_str);
    let Ok(cstr) = CString::new(sanitized) else {
        return std::ptr::null_mut();
    };
    cstr.into_raw()
}

#[no_mangle]
pub extern "C" fn chau7_escape_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub extern "C" fn chau7_match_patterns_create(
    patterns: *const *const c_char,
    count: usize,
) -> *mut MatchPatternSet {
    if patterns.is_null() {
        return std::ptr::null_mut();
    }
    let mut list: Vec<String> = Vec::with_capacity(count);
    for i in 0..count {
        unsafe {
            let ptr = *patterns.add(i);
            if ptr.is_null() {
                continue;
            }
            if let Ok(raw) = CStr::from_ptr(ptr).to_str() {
                if !raw.is_empty() {
                    list.push(raw.to_string());
                }
            }
        }
    }
    let set = MatchPatternSet { patterns: list };
    Box::into_raw(Box::new(set))
}

#[no_mangle]
pub extern "C" fn chau7_match_patterns_free(handle: *mut MatchPatternSet) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn chau7_match_first(handle: *const MatchPatternSet, haystack: *const c_char) -> i32 {
    if handle.is_null() || haystack.is_null() {
        return -1;
    }
    let Ok(haystack) = (unsafe { CStr::from_ptr(haystack).to_str() }) else {
        return -1;
    };
    let patterns = unsafe { &(*handle).patterns };
    for (idx, pattern) in patterns.iter().enumerate() {
        if haystack.contains(pattern) {
            return idx as i32;
        }
    }
    -1
}

#[no_mangle]
pub extern "C" fn chau7_match_any(handle: *const MatchPatternSet, haystack: *const c_char) -> bool {
    chau7_match_first(handle, haystack) >= 0
}

#[no_mangle]
pub extern "C" fn chau7_ansi_parse(text: *const c_char) -> *mut AnsiSegments {
    if text.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(text) = (unsafe { CStr::from_ptr(text).to_str() }) else {
        return std::ptr::null_mut();
    };
    let segments = parse_ansi_segments(text);
    let count = segments.len();
    let mut boxed = segments.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    let wrapper = AnsiSegments { segments: ptr, count };
    Box::into_raw(Box::new(wrapper))
}

#[no_mangle]
pub extern "C" fn chau7_ansi_segments_free(ptr: *mut AnsiSegments) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let wrapper = Box::from_raw(ptr);
        let segments = std::slice::from_raw_parts_mut(wrapper.segments, wrapper.count);
        for seg in segments.iter_mut() {
            if !seg.text.is_null() {
                let _ = CString::from_raw(seg.text);
                seg.text = std::ptr::null_mut();
            }
        }
        let _ = Vec::from_raw_parts(wrapper.segments, wrapper.count, wrapper.count);
    }
}

#[cfg(test)]
mod tests {
    use super::{normalize, sanitize_text, parse_ansi_segments};

    #[test]
    fn normalize_collapses_whitespace() {
        assert_eq!(normalize("  rm   -rf   / "), "rm -rf /");
    }

    #[test]
    fn normalize_lowercases() {
        assert_eq!(normalize("Sudo RM"), "sudo rm");
    }

    #[test]
    fn sanitize_removes_csi() {
        let input = "Hello\u{1b}[32mWorld\u{1b}[0m";
        assert_eq!(sanitize_text(input), "HelloWorld");
    }

    #[test]
    fn sanitize_removes_osc() {
        let input = "text\u{1b}]10;rgb:ff/ff/ff\u{07}more";
        assert_eq!(sanitize_text(input), "textmore");
    }

    #[test]
    fn sanitize_collapses_spaces() {
        let input = "hello     world";
        assert_eq!(sanitize_text(input), "hello world");
    }

    #[test]
    fn ansi_parse_segments() {
        let input = "hi\u{1b}[31mred\u{1b}[0m";
        let segments = parse_ansi_segments(input);
        assert_eq!(segments.len(), 2);
    }
}
