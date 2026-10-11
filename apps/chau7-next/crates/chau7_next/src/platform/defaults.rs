//! macOS app defaults (CFPreferences for `com.chau7.next`): the per-app
//! defaults set before the first window opens, and hidden preferences set
//! with `defaults write com.chau7.next <key> ...` (for example
//! `window.menuBarOnlyMode`, SET-023).
//!
//! Regular settings live in Chau7 Next's own config file, not here. Off
//! macOS every key reads as missing.

/// A boolean app default; `None` when unset or not a boolean (`-bool`,
/// `-int 0/1` and the strings `YES`/`NO`/`true`/`false` are read).
pub fn app_bool(key: &str) -> Option<bool> {
    match imp::app_value(key)? {
        Value::Bool(value) => Some(value),
        Value::Int(value) => Some(value != 0),
        Value::Text(text) => parse_bool(&text),
    }
}

/// A string app default.
pub fn app_string(key: &str) -> Option<String> {
    match imp::app_value(key)? {
        Value::Text(text) => Some(text),
        _ => None,
    }
}

/// An integer app default.
pub fn app_int(key: &str) -> Option<i64> {
    match imp::app_value(key)? {
        Value::Int(value) => Some(value),
        Value::Text(text) => text.trim().parse().ok(),
        Value::Bool(_) => None,
    }
}

/// Sets (`Some`) or removes (`None`) a boolean app default.
pub fn set_app_bool(key: &str, value: Option<bool>) -> super::Result<()> {
    imp::set_app_bool(key, value)
}

/// Sets or removes a local string app default (never the cloud store).
pub fn set_app_string(key: &str, value: Option<&str>) -> super::Result<()> {
    imp::set_app_string(key, value)
}

/// A value read from the app defaults.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Value {
    Bool(bool),
    Int(i64),
    Text(String),
}

fn parse_bool(text: &str) -> Option<bool> {
    match text.trim().to_ascii_lowercase().as_str() {
        "yes" | "true" | "1" => Some(true),
        "no" | "false" | "0" => Some(false),
        _ => None,
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::number::CFNumber;
    use core_foundation::string::CFString;
    use core_foundation_sys::preferences::{
        CFPreferencesAppSynchronize, CFPreferencesCopyAppValue, CFPreferencesSetAppValue,
        kCFPreferencesCurrentApplication,
    };

    use super::Value;
    use crate::platform::Result;

    pub fn app_value(key: &str) -> Option<Value> {
        let key = CFString::new(key);
        // SAFETY: valid key and the static current-application id; the
        // returned value (if any) is owned by us.
        let raw = unsafe {
            CFPreferencesCopyAppValue(key.as_concrete_TypeRef(), kCFPreferencesCurrentApplication)
        };
        if raw.is_null() {
            return None;
        }
        // SAFETY: a property list object following the create rule.
        let value = unsafe { CFType::wrap_under_create_rule(raw) };
        if let Some(flag) = value.downcast::<CFBoolean>() {
            return Some(Value::Bool(flag.into()));
        }
        if let Some(number) = value.downcast::<CFNumber>() {
            return number.to_i64().map(Value::Int);
        }
        value
            .downcast::<CFString>()
            .map(|text| Value::Text(text.to_string()))
    }

    pub fn set_app_string(key: &str, value: Option<&str>) -> Result<()> {
        let key = CFString::new(key);
        let value = value.map(CFString::new);
        let raw = value
            .as_ref()
            .map_or(std::ptr::null(), |value| value.as_CFTypeRef());
        // SAFETY: owned property-list strings and the static current app ID.
        let success = unsafe {
            CFPreferencesSetAppValue(
                key.as_concrete_TypeRef(),
                raw,
                kCFPreferencesCurrentApplication,
            );
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        };
        if success != 0 {
            Ok(())
        } else {
            Err(crate::platform::PlatformError::Failed(
                "could not persist local app default".into(),
            ))
        }
    }

    pub fn set_app_bool(key: &str, value: Option<bool>) -> Result<()> {
        let key = CFString::new(key);
        let flag = value.map(CFBoolean::from);
        let raw = flag
            .as_ref()
            .map_or(std::ptr::null(), |flag| flag.as_CFTypeRef());
        // SAFETY: valid key, value (or null to remove) and the static
        // current-application id.
        unsafe {
            CFPreferencesSetAppValue(
                key.as_concrete_TypeRef(),
                raw,
                kCFPreferencesCurrentApplication,
            );
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        }
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::Value;
    use crate::platform::{Result, unsupported};

    pub fn app_value(_key: &str) -> Option<Value> {
        None
    }

    pub fn set_app_string(_key: &str, _value: Option<&str>) -> Result<()> {
        unsupported("app defaults")
    }

    pub fn set_app_bool(_key: &str, _value: Option<bool>) -> Result<()> {
        unsupported("app defaults")
    }
}

/// Key repeat instead of the accent popup when a letter is held, as terminals
/// expect (holding `j` in vim, `x` in a prompt). Only set when the user has
/// not chosen a value for Chau7 Next (`defaults write com.chau7.next
/// ApplePressAndHoldEnabled -bool true` brings the popup back).
#[cfg(target_os = "macos")]
pub fn disable_press_and_hold() {
    use std::ffi::c_void;
    type CFTypeRef = *const c_void;
    type CFStringRef = *const c_void;
    const UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFBooleanFalse: CFTypeRef;
        static kCFPreferencesCurrentApplication: CFStringRef;
        fn CFStringCreateWithCString(
            alloc: CFTypeRef,
            c_str: *const std::ffi::c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFPreferencesCopyAppValue(key: CFStringRef, app: CFStringRef) -> CFTypeRef;
        fn CFPreferencesSetAppValue(key: CFStringRef, value: CFTypeRef, app: CFStringRef);
        fn CFRelease(cf: CFTypeRef);
    }

    // SAFETY: plain CoreFoundation calls with valid, owned or static objects;
    // every created or copied object is released.
    unsafe {
        let key =
            CFStringCreateWithCString(std::ptr::null(), c"ApplePressAndHoldEnabled".as_ptr(), UTF8);
        if key.is_null() {
            return;
        }
        let existing = CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication);
        if existing.is_null() {
            CFPreferencesSetAppValue(key, kCFBooleanFalse, kCFPreferencesCurrentApplication);
        } else {
            CFRelease(existing);
        }
        CFRelease(key);
    }
}

#[cfg(not(target_os = "macos"))]
pub fn disable_press_and_hold() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bool_strings() {
        assert_eq!(parse_bool("YES"), Some(true));
        assert_eq!(parse_bool(" true "), Some(true));
        assert_eq!(parse_bool("0"), Some(false));
        assert_eq!(parse_bool("No"), Some(false));
        assert_eq!(parse_bool("maybe"), None);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn missing_off_macos() {
        assert_eq!(app_bool("window.menuBarOnlyMode"), None);
        assert_eq!(app_string("x"), None);
        assert_eq!(app_int("x"), None);
        assert!(set_app_bool("x", Some(true)).is_err());
        disable_press_and_hold();
    }
}
