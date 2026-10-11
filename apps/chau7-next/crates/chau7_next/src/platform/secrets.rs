//! Secrets (LLM API keys, SSH passwords) in the Keychain, as generic
//! passwords readable only on this Mac while it is unlocked (UTL-003).
//!
//! Chau7 Next keeps its own items: every service name is prefixed with
//! [`SERVICE_PREFIX`], so the Swift app's items (`com.chau7.llm.*`,
//! `com.chau7.ssh`) are never read or overwritten. Callers pass the short
//! service (`llm.openai.apikey`, `ssh`) and the account.

use std::collections::HashMap;
use std::sync::Mutex;

use super::Result;

/// Prefix of every Keychain service name Chau7 Next writes.
pub const SERVICE_PREFIX: &str = "com.chau7.next.";

/// Full Keychain service name for a short service name. A name that already
/// carries the prefix is kept as is. In an isolated run,
/// `CHAU7_NEXT_KEYCHAIN_SERVICE_PREFIX` goes in front
/// (`RuntimeIsolation.keychainServiceName`).
pub fn service_name(service: &str) -> String {
    let short = service.trim().trim_start_matches('.');
    let full = if short.starts_with(SERVICE_PREFIX) {
        short.to_string()
    } else {
        format!("{SERVICE_PREFIX}{short}")
    };
    chau7_next_core::data_root::keychain_service_name_from_env(&full)
}

/// Store for small UTF-8 secrets, keyed by service and account.
pub trait SecretStore: Send + Sync {
    /// The secret, or `None` when there is no item.
    fn get(&self, service: &str, account: &str) -> Result<Option<String>>;
    /// Creates or replaces the item.
    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()>;
    /// Removes the item. Removing a missing item is not an error.
    fn delete(&self, service: &str, account: &str) -> Result<()>;
}

/// The Keychain on macOS; a stub elsewhere.
pub fn current() -> &'static dyn SecretStore {
    static STORE: imp::Store = imp::Store;
    &STORE
}

/// In-memory store, for tests of features that keep secrets.
#[derive(Default)]
pub struct MemorySecretStore {
    items: Mutex<HashMap<(String, String), String>>,
}

impl SecretStore for MemorySecretStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
        let items = self.items.lock().unwrap_or_else(|e| e.into_inner());
        Ok(items
            .get(&(service_name(service), account.to_string()))
            .cloned())
    }

    fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
        let mut items = self.items.lock().unwrap_or_else(|e| e.into_inner());
        items.insert(
            (service_name(service), account.to_string()),
            secret.to_string(),
        );
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<()> {
        let mut items = self.items.lock().unwrap_or_else(|e| e.into_inner());
        items.remove(&(service_name(service), account.to_string()));
        Ok(())
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use security_framework::passwords::{delete_generic_password, get_generic_password};

    use super::service_name;
    use crate::platform::{PlatformError, Result};

    /// `errSecItemNotFound`.
    const ITEM_NOT_FOUND: i32 = -25300;

    pub struct Store;

    fn failed(err: security_framework::base::Error) -> PlatformError {
        PlatformError::Failed(format!("Keychain: {err}"))
    }

    impl super::SecretStore for Store {
        fn get(&self, service: &str, account: &str) -> Result<Option<String>> {
            match get_generic_password(&service_name(service), account) {
                Ok(bytes) => String::from_utf8(bytes)
                    .map(Some)
                    .map_err(|_| PlatformError::Failed("Keychain item is not UTF-8".into())),
                Err(err) if err.code() == ITEM_NOT_FOUND => Ok(None),
                Err(err) => Err(failed(err)),
            }
        }

        fn set(&self, service: &str, account: &str, secret: &str) -> Result<()> {
            use core_foundation::base::TCFType;
            use core_foundation::string::CFString;
            use core_foundation_sys::string::CFStringRef;
            use security_framework::passwords::set_generic_password_options;
            use security_framework::passwords_options::PasswordOptions;

            #[link(name = "Security", kind = "framework")]
            unsafe extern "C" {
                static kSecAttrAccessible: CFStringRef;
                static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFStringRef;
            }

            let service = service_name(service);
            // Replace any item (an update would keep the old item's
            // accessibility), as `KeychainHelper.save` deletes then adds.
            super::SecretStore::delete(self, &service, account)?;
            let mut options = PasswordOptions::new_generic_password(&service, account);
            // Readable only on this Mac while it is unlocked
            // (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
            // SAFETY: Security framework constants, valid for the process life.
            let (key, value) = unsafe {
                (
                    CFString::wrap_under_get_rule(kSecAttrAccessible),
                    CFString::wrap_under_get_rule(kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
                )
            };
            #[allow(deprecated)]
            options.query.push((key, value.into_CFType()));
            set_generic_password_options(secret.as_bytes(), options).map_err(failed)
        }

        fn delete(&self, service: &str, account: &str) -> Result<()> {
            match delete_generic_password(&service_name(service), account) {
                Ok(()) => Ok(()),
                Err(err) if err.code() == ITEM_NOT_FOUND => Ok(()),
                Err(err) => Err(failed(err)),
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub struct Store;

    impl super::SecretStore for Store {
        fn get(&self, _service: &str, _account: &str) -> Result<Option<String>> {
            unsupported("Keychain")
        }

        fn set(&self, _service: &str, _account: &str, _secret: &str) -> Result<()> {
            unsupported("Keychain")
        }

        fn delete(&self, _service: &str, _account: &str) -> Result<()> {
            unsupported("Keychain")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_names_get_the_prefix_once() {
        assert_eq!(service_name("ssh"), "com.chau7.next.ssh");
        assert_eq!(
            service_name("llm.openai.apikey"),
            "com.chau7.next.llm.openai.apikey"
        );
        assert_eq!(service_name("com.chau7.next.ssh"), "com.chau7.next.ssh");
        assert_eq!(service_name(" .ssh "), "com.chau7.next.ssh");
    }

    #[test]
    fn memory_store_round_trip() {
        let store = MemorySecretStore::default();
        assert_eq!(store.get("ssh", "host-1").unwrap(), None);
        store.set("ssh", "host-1", "pw").unwrap();
        assert_eq!(store.get("ssh", "host-1").unwrap().as_deref(), Some("pw"));
        // The same item under its full name.
        assert_eq!(
            store
                .get("com.chau7.next.ssh", "host-1")
                .unwrap()
                .as_deref(),
            Some("pw")
        );
        store.delete("ssh", "host-1").unwrap();
        store.delete("ssh", "host-1").unwrap();
        assert_eq!(store.get("ssh", "host-1").unwrap(), None);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_reports_unsupported() {
        use crate::platform::PlatformError;
        assert_eq!(
            current().get("ssh", "a"),
            Err(PlatformError::Unsupported("Keychain"))
        );
    }
}
