//! iCloud key-value store (Settings > Sync & Backup, SET-008): the small
//! document the settings sync writes to `NSUbiquitousKeyValueStore`.
//!
//! The store only syncs for an app that is signed with the iCloud key-value
//! store entitlement (`com.apple.developer.ubiquity-kvstore-identifier`) and
//! runs from its bundle. Unsigned builds read and write a local copy that
//! never leaves the Mac, which looks like "iCloud is on but nothing syncs".
//! Other OSes get a stub that holds nothing.

use super::Result;

pub trait CloudStore: Send + Sync {
    /// iCloud can be used: the app runs from its bundle (and, on a signed
    /// build, the user is signed in to iCloud).
    fn is_available(&self) -> bool;
    /// The string saved under `key`, from this Mac or pushed by another one.
    fn string(&self, key: &str) -> Option<String>;
    /// Saves `value` under `key` and asks the system to upload it.
    fn set_string(&self, key: &str, value: &str) -> Result<()>;
    /// Pulls what other Macs pushed (`synchronize`). `false` when the system
    /// could not reach the store.
    fn synchronize(&self) -> bool;
}

/// `NSUbiquitousKeyValueStore.default` on macOS; a stub elsewhere.
pub fn current() -> &'static dyn CloudStore {
    static STORE: imp::Store = imp::Store;
    &STORE
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_foundation::{NSString, NSUbiquitousKeyValueStore};

    use crate::platform::{Result, running_from_app_bundle};

    pub struct Store;

    impl super::CloudStore for Store {
        fn is_available(&self) -> bool {
            running_from_app_bundle()
        }

        fn string(&self, key: &str) -> Option<String> {
            NSUbiquitousKeyValueStore::defaultStore()
                .stringForKey(&NSString::from_str(key))
                .map(|s| s.to_string())
        }

        fn set_string(&self, key: &str, value: &str) -> Result<()> {
            let store = NSUbiquitousKeyValueStore::defaultStore();
            store.setString_forKey(Some(&NSString::from_str(value)), &NSString::from_str(key));
            store.synchronize();
            Ok(())
        }

        fn synchronize(&self) -> bool {
            NSUbiquitousKeyValueStore::defaultStore().synchronize()
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub struct Store;

    impl super::CloudStore for Store {
        fn is_available(&self) -> bool {
            false
        }

        fn string(&self, _key: &str) -> Option<String> {
            None
        }

        fn set_string(&self, _key: &str, _value: &str) -> Result<()> {
            unsupported("iCloud sync")
        }

        fn synchronize(&self) -> bool {
            false
        }
    }
}
