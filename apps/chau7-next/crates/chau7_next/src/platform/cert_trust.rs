//! Trusting the local TLS proxy's self-signed certificate (PRX-005) in the
//! login keychain, so tools that use the system trust store accept it.
//!
//! [`trust`] asks for the user's password (a system dialog), so call it from
//! a button, never at launch. Certificates are passed as DER; read the
//! proxy's `proxy-cert.pem` with [`pem_to_der`].

use base64::Engine as _;

use super::Result;

/// The DER bytes of the first `CERTIFICATE` block of a PEM file.
pub fn pem_to_der(pem: &str) -> Option<Vec<u8>> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let start = pem.find(BEGIN)? + BEGIN.len();
    let end = start + pem[start..].find(END)?;
    let body: String = pem[start..end]
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(body)
        .ok()
        .filter(|der| !der.is_empty())
}

/// Whether the certificate is trusted for TLS by the user's trust settings.
pub fn is_trusted(der: &[u8]) -> Result<bool> {
    imp::is_trusted(der)
}

/// Adds the certificate to the login keychain (if missing) and marks it
/// "Always Trust". Shows the system password prompt.
pub fn trust(der: &[u8]) -> Result<()> {
    imp::trust(der)
}

/// Removes the user's trust setting for the certificate (the certificate
/// stays in the keychain). Shows the system password prompt.
pub fn remove_trust(der: &[u8]) -> Result<()> {
    imp::remove_trust(der)
}

#[cfg(target_os = "macos")]
mod imp {
    use core_foundation::base::TCFType;
    use security_framework::certificate::SecCertificate;
    use security_framework::trust_settings::{Domain, TrustSettings, TrustSettingsForCertificate};

    use crate::platform::{PlatformError, Result};

    /// `errSecItemNotFound`: no trust settings for this certificate.
    const ITEM_NOT_FOUND: i32 = -25300;
    /// `errSecDuplicateItem`: the certificate is already in the keychain.
    const DUPLICATE_ITEM: i32 = -25299;

    // Not wrapped by security-framework.
    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        fn SecTrustSettingsRemoveTrustSettings(
            certificate: *mut std::ffi::c_void,
            domain: u32,
        ) -> i32;
    }

    /// `kSecTrustSettingsDomainUser`.
    const DOMAIN_USER: u32 = 0;

    fn failed(what: &str, err: security_framework::base::Error) -> PlatformError {
        PlatformError::Failed(format!("{what}: {err}"))
    }

    fn certificate(der: &[u8]) -> Result<SecCertificate> {
        SecCertificate::from_der(der).map_err(|err| failed("invalid certificate", err))
    }

    pub fn is_trusted(der: &[u8]) -> Result<bool> {
        let cert = certificate(der)?;
        match TrustSettings::new(Domain::User).tls_trust_settings_for_certificate(&cert) {
            Ok(Some(
                TrustSettingsForCertificate::TrustRoot | TrustSettingsForCertificate::TrustAsRoot,
            )) => Ok(true),
            Ok(_) => Ok(false),
            Err(err) if err.code() == ITEM_NOT_FOUND => Ok(false),
            Err(err) => Err(failed("trust settings", err)),
        }
    }

    pub fn trust(der: &[u8]) -> Result<()> {
        let cert = certificate(der)?;
        match cert.add_to_keychain(None) {
            Ok(()) => {}
            Err(err) if err.code() == DUPLICATE_ITEM => {}
            Err(err) => return Err(failed("adding to the login keychain", err)),
        }
        TrustSettings::new(Domain::User)
            .set_trust_settings_always(&cert)
            .map_err(|err| failed("trust settings", err))
    }

    pub fn remove_trust(der: &[u8]) -> Result<()> {
        let cert = certificate(der)?;
        // SAFETY: `cert` is a valid SecCertificate for the whole call.
        let status = unsafe {
            SecTrustSettingsRemoveTrustSettings(cert.as_concrete_TypeRef().cast(), DOMAIN_USER)
        };
        match status {
            0 | ITEM_NOT_FOUND => Ok(()),
            code => Err(failed(
                "trust settings",
                security_framework::base::Error::from_code(code),
            )),
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub fn is_trusted(_der: &[u8]) -> Result<bool> {
        unsupported("certificate trust")
    }

    pub fn trust(_der: &[u8]) -> Result<()> {
        unsupported("certificate trust")
    }

    pub fn remove_trust(_der: &[u8]) -> Result<()> {
        unsupported("certificate trust")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pem_decoding() {
        let pem = "junk\n-----BEGIN CERTIFICATE-----\nAQID\nBAU=\n-----END CERTIFICATE-----\n\
                   -----BEGIN CERTIFICATE-----\nBgc=\n-----END CERTIFICATE-----\n";
        assert_eq!(pem_to_der(pem), Some(vec![1, 2, 3, 4, 5]));
        assert_eq!(pem_to_der("no certificate"), None);
        assert_eq!(
            pem_to_der("-----BEGIN CERTIFICATE-----\n!!\n-----END CERTIFICATE-----"),
            None
        );
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unsupported() {
        assert!(is_trusted(&[1]).is_err());
        assert!(trust(&[1]).is_err());
    }
}
