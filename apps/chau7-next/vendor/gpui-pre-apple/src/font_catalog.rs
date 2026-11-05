//! Process-wide invalidation, with per-text-system font-family snapshots.
//!
//! CoreText may post synchronously during registration. The callback only bumps
//! an atomic; it must never re-enter the text system or take its locks.
use std::{
    ffi::c_void,
    sync::{
        Once,
        atomic::{AtomicU64, Ordering},
    },
};

static GENERATION: AtomicU64 = AtomicU64::new(0);
static REGISTER: Once = Once::new();

type Center = *const c_void;
type Callback =
    unsafe extern "C" fn(Center, *mut c_void, *const c_void, *const c_void, *const c_void);

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFNotificationCenterGetLocalCenter() -> Center;
    #[cfg(target_os = "macos")]
    fn CFNotificationCenterGetDistributedCenter() -> Center;
    fn CFNotificationCenterAddObserver(
        center: Center,
        observer: *const c_void,
        callback: Callback,
        name: *const c_void,
        object: *const c_void,
        behavior: isize,
    );
}
#[link(name = "CoreText", kind = "framework")]
unsafe extern "C" {
    static kCTFontManagerRegisteredFontsChangedNotification: *const c_void;
}

unsafe extern "C" fn changed(
    _: Center,
    _: *mut c_void,
    _: *const c_void,
    _: *const c_void,
    _: *const c_void,
) {
    GENERATION.fetch_add(1, Ordering::Release);
}

pub(crate) fn generation() -> u64 {
    REGISTER.call_once(|| {
        // SAFETY: the observer identity and callback both live for the process.
        // Local notifications cover process fonts; distributed notifications
        // also cover macOS session/persistent font installation and removal.
        unsafe {
            let observer = (&GENERATION as *const AtomicU64).cast();
            let name = kCTFontManagerRegisteredFontsChangedNotification;
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetLocalCenter(),
                observer,
                changed,
                name,
                std::ptr::null(),
                4,
            );
            #[cfg(target_os = "macos")]
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDistributedCenter(),
                observer,
                changed,
                name,
                std::ptr::null(),
                4,
            );
        }
    });
    GENERATION.load(Ordering::Acquire)
}

#[derive(Default)]
pub(crate) struct FontCatalog(Option<(u64, Vec<String>)>);

impl FontCatalog {
    pub(crate) fn get(&self, generation: u64) -> Option<&Vec<String>> {
        self.0
            .as_ref()
            .filter(|(saved, _)| *saved == generation)
            .map(|(_, names)| names)
    }
    pub(crate) fn store(&mut self, generation: u64, names: Vec<String>) {
        self.0 = Some((generation, names));
    }
    pub(crate) fn invalidate(&mut self) {
        self.0 = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reuses_snapshot_and_invalidates_on_registry_changes() {
        let mut cache = FontCatalog::default();
        assert!(cache.get(0).is_none());
        cache.store(0, vec!["Mono".into()]);
        for _ in 0..100 {
            assert_eq!(cache.get(0).unwrap(), &["Mono"]);
        }
        assert!(cache.get(1).is_none());
        cache.store(1, vec!["Mono".into(), "Installed".into()]);
        assert_eq!(cache.get(1).unwrap().len(), 2);
        cache.invalidate();
        assert!(cache.get(1).is_none());
    }
    #[test]
    fn notification_during_enumeration_does_not_publish_a_fresh_generation() {
        let mut cache = FontCatalog::default();
        cache.store(4, vec!["Old".into()]);
        assert!(cache.get(5).is_none());
    }
    #[test]
    fn receives_native_registry_notification() {
        let before = generation();
        unsafe extern "C" {
            fn CFNotificationCenterPostNotification(
                center: Center,
                name: *const c_void,
                object: *const c_void,
                info: *const c_void,
                deliver: u8,
            );
        }
        // SAFETY: posts the documented notification with no borrowed payload.
        unsafe {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetLocalCenter(),
                kCTFontManagerRegisteredFontsChangedNotification,
                std::ptr::null(),
                std::ptr::null(),
                1,
            );
        }
        assert!(generation() > before);
    }
}
