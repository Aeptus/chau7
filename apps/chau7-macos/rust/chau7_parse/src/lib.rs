use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[repr(C)]
pub struct PatternSet {
    patterns: Vec<String>,
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

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn normalize_collapses_whitespace() {
        assert_eq!(normalize("  rm   -rf   / "), "rm -rf /");
    }

    #[test]
    fn normalize_lowercases() {
        assert_eq!(normalize("Sudo RM"), "sudo rm");
    }
}
