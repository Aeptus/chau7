//! Facts about this Mac and its settings: the computer name and hardware
//! UUID (remote control pairing), accessibility display flags (Increase
//! contrast, Reduce motion) and whether the screen is locked (notifications
//! are held while it is).

/// The computer name shown to paired devices ("Christophe's MacBook Pro").
pub fn host_name() -> Option<String> {
    imp::host_name().filter(|name| !name.trim().is_empty())
}

/// The hardware UUID (`IOPlatformUUID`), stable across reinstalls.
pub fn hardware_uuid() -> Option<String> {
    imp::hardware_uuid()
}

/// System Settings > Accessibility > Display > Increase contrast.
pub fn increase_contrast() -> bool {
    imp::increase_contrast()
}

/// System Settings > Accessibility > Display > Reduce motion.
pub fn reduce_motion() -> bool {
    imp::reduce_motion()
}

/// Whether the login session's screen is locked.
pub fn screen_locked() -> bool {
    imp::screen_locked()
}

/// The OS preferred languages, most preferred first ("fr-FR", "en-US"); what
/// "System Default" follows (`Bundle.preferredLocalizations`). NSLocale
/// preferred languages on macOS, the locale environment on Linux.
pub fn preferred_languages() -> Vec<String> {
    sys_locale::get_locales().collect()
}

/// A string of the app bundle's `Info.plist` (`CFBundleShortVersionString`,
/// `CFBundleVersion`, `CFBundleIdentifier`); `None` when not run from a
/// bundle. Read from `Contents/Info.plist` next to the executable, which
/// `scripts/bundle-macos.sh` writes as XML.
pub fn bundle_string(key: &str) -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let plist = exe.parent()?.parent()?.join("Info.plist");
    let xml = std::fs::read_to_string(plist).ok()?;
    chau7_next_core::app_shell::plist_string(&xml, key)
}

/// The operating system and its version ("Version 15.1 (Build 24B83)" on
/// macOS), for the About pane (`operatingSystemVersionString`).
pub fn os_version() -> String {
    os_version_impl()
}

#[cfg(target_os = "macos")]
fn os_version_impl() -> String {
    objc2_foundation::NSProcessInfo::processInfo()
        .operatingSystemVersionString()
        .to_string()
}

#[cfg(not(target_os = "macos"))]
fn os_version_impl() -> String {
    std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.strip_prefix("PRETTY_NAME="))
                .map(|v| v.trim_matches('"').to_string())
        })
        .unwrap_or_else(|| std::env::consts::OS.to_string())
}

/// `IOPlatformUUID` from the output of
/// `ioreg -rd1 -c IOPlatformExpertDevice`.
pub fn parse_ioreg_uuid(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let (key, value) = line.split_once('=')?;
        if key.trim().trim_matches('"') != "IOPlatformUUID" {
            return None;
        }
        let value = value.trim().trim_matches('"');
        (!value.is_empty()).then(|| value.to_string())
    })
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_app_kit::NSWorkspace;

    pub fn host_name() -> Option<String> {
        #[allow(deprecated)] // NSHost: still the API for the localized computer name.
        let name = objc2_foundation::NSHost::currentHost().localizedName();
        name.map(|name| name.to_string())
    }

    pub fn hardware_uuid() -> Option<String> {
        // The same lookup the remote agent does.
        let output = std::process::Command::new("/usr/sbin/ioreg")
            .args(["-rd1", "-c", "IOPlatformExpertDevice"])
            .output()
            .ok()?;
        super::parse_ioreg_uuid(&String::from_utf8_lossy(&output.stdout))
    }

    pub fn increase_contrast() -> bool {
        NSWorkspace::sharedWorkspace().accessibilityDisplayShouldIncreaseContrast()
    }

    pub fn reduce_motion() -> bool {
        NSWorkspace::sharedWorkspace().accessibilityDisplayShouldReduceMotion()
    }

    pub fn screen_locked() -> bool {
        use core_foundation::base::{CFType, TCFType};
        use core_foundation::boolean::CFBoolean;
        use core_foundation::dictionary::CFDictionary;
        use core_foundation::string::CFString;
        use core_foundation_sys::dictionary::CFDictionaryRef;

        #[link(name = "CoreGraphics", kind = "framework")]
        unsafe extern "C" {
            fn CGSessionCopyCurrentDictionary() -> CFDictionaryRef;
        }

        // SAFETY: returns a new dictionary we own, or null outside a GUI
        // login session.
        let raw = unsafe { CGSessionCopyCurrentDictionary() };
        if raw.is_null() {
            return false;
        }
        // SAFETY: `raw` is a CFDictionary following the create rule.
        let session: CFDictionary<CFString, CFType> =
            unsafe { TCFType::wrap_under_create_rule(raw) };
        let key = CFString::from_static_string("CGSSessionScreenIsLocked");
        session
            .find(&key)
            .and_then(|value| value.downcast::<CFBoolean>())
            .is_some_and(bool::from)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use crate::platform::log_unsupported_once;

    pub fn host_name() -> Option<String> {
        std::fs::read_to_string("/proc/sys/kernel/hostname")
            .ok()
            .map(|name| name.trim().to_string())
    }

    pub fn hardware_uuid() -> Option<String> {
        log_unsupported_once("hardware UUID");
        None
    }

    pub fn increase_contrast() -> bool {
        log_unsupported_once("accessibility display flags");
        false
    }

    pub fn reduce_motion() -> bool {
        log_unsupported_once("accessibility display flags");
        false
    }

    pub fn screen_locked() -> bool {
        log_unsupported_once("screen lock state");
        false
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use crate::platform::log_unsupported_once;

    pub fn host_name() -> Option<String> {
        std::env::var("COMPUTERNAME").ok()
    }

    pub fn hardware_uuid() -> Option<String> {
        log_unsupported_once("hardware UUID");
        None
    }

    pub fn increase_contrast() -> bool {
        log_unsupported_once("accessibility display flags");
        false
    }

    pub fn reduce_motion() -> bool {
        log_unsupported_once("accessibility display flags");
        false
    }

    pub fn screen_locked() -> bool {
        log_unsupported_once("screen lock state");
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ioreg_uuid() {
        let output = r#"+-o MacBookPro18,3  <class IOPlatformExpertDevice, id 0x100000110, registered>
    {
      "IOPolledInterface" = "AppleARMWatchdogTimerHibernateHandler is not serializable"
      "IOPlatformSerialNumber" = "ABC123"
      "IOPlatformUUID" = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"
      "IOPlatformExpertDevice" = <>
    }"#;
        assert_eq!(
            parse_ioreg_uuid(output).as_deref(),
            Some("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
        );
        assert_eq!(parse_ioreg_uuid("nothing here"), None);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn neutral_flags_off_macos() {
        assert!(!increase_contrast());
        assert!(!reduce_motion());
        assert!(!screen_locked());
    }
}
