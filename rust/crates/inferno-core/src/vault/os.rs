//! The OS credential store via keyring-core: macOS Keychain, Windows
//! Credential Manager, and the Secret Service (GNOME Keyring, KWallet) on
//! Linux and the BSDs. iOS and Android are wired in the mobile pass.

use std::sync::OnceLock;

use keyring_core::{Entry, Error};

use super::{SecretStore, VaultError};

/// Service name every entry is filed under in the OS store.
const SERVICE: &str = "inferno";

pub struct OsKeyring {
    service: String,
}

impl OsKeyring {
    /// Connects to the platform store once per process.
    pub fn new() -> Result<Self, VaultError> {
        Self::with_service(SERVICE)
    }

    /// A separate namespace, e.g. for a second install or for tests.
    pub fn with_service(service: &str) -> Result<Self, VaultError> {
        static INIT: OnceLock<Result<(), String>> = OnceLock::new();
        INIT.get_or_init(|| init_platform_store().map_err(|e| e.to_string()))
            .clone()
            .map_err(VaultError::Unavailable)?;
        Ok(Self { service: service.to_owned() })
    }

    fn entry(&self, name: &str) -> Result<Entry, VaultError> {
        Entry::new(&self.service, name).map_err(store_err)
    }
}

impl SecretStore for OsKeyring {
    fn get(&self, name: &str) -> Result<Option<String>, VaultError> {
        match self.entry(name)?.get_password() {
            Ok(value) => Ok(Some(value)),
            Err(Error::NoEntry) => Ok(None),
            Err(e) => Err(store_err(e)),
        }
    }

    fn set(&self, name: &str, value: &str) -> Result<(), VaultError> {
        self.entry(name)?.set_password(value).map_err(store_err)
    }

    fn delete(&self, name: &str) -> Result<(), VaultError> {
        match self.entry(name)?.delete_credential() {
            Ok(()) | Err(Error::NoEntry) => Ok(()),
            Err(e) => Err(store_err(e)),
        }
    }
}

fn store_err(e: Error) -> VaultError {
    match e {
        Error::NoStorageAccess(_) | Error::NoDefaultStore => VaultError::Unavailable(e.to_string()),
        e => VaultError::Store(e.to_string()),
    }
}

fn init_platform_store() -> keyring_core::Result<()> {
    #[cfg(target_os = "macos")]
    keyring_core::set_default_store(apple_native_keyring_store::keychain::Store::new()?);
    #[cfg(target_os = "windows")]
    keyring_core::set_default_store(windows_native_keyring_store::Store::new()?);
    #[cfg(all(unix, not(any(target_os = "macos", target_os = "ios", target_os = "android"))))]
    keyring_core::set_default_store(zbus_secret_service_keyring_store::Store::new()?);
    #[cfg(any(target_os = "ios", target_os = "android"))]
    return Err(Error::NotSupportedByStore(
        "mobile credential stores are wired in the mobile pass".to_owned(),
    ));
    #[allow(unreachable_code)]
    Ok(())
}
