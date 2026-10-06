//! Account vault: where identities live at rest.
//!
//! Secrets go to the OS credential store, never to SQLite or plain files:
//! - the active account's raw secret key, so the app can sign without asking;
//! - a NIP-49 `ncryptsec` backup per saved account, so the user can switch
//!   accounts with the backup password instead of re-importing.
//!
//! Signing up requires choosing a backup password (Flutter's mandatory backup
//! step). Unlike Flutter there's no stored SHA-256 of that password: proving
//! you know it means decrypting your own `ncryptsec`, which an unsalted fast
//! hash sitting next to it would only weaken.

mod os;

use std::collections::HashMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::keys::{Identity, KeyError};

pub use os::OsKeyring;

/// A credential store holding UTF-8 secrets by name.
pub trait SecretStore: Send + Sync {
    fn get(&self, name: &str) -> Result<Option<String>, VaultError>;
    fn set(&self, name: &str, value: &str) -> Result<(), VaultError>;
    /// Deleting a missing secret is not an error.
    fn delete(&self, name: &str) -> Result<(), VaultError>;
}

#[derive(Debug, thiserror::Error)]
pub enum VaultError {
    #[error("the OS credential store is unavailable: {0}")]
    Unavailable(String),
    #[error("credential store error: {0}")]
    Store(String),
    #[error("no saved account {0}")]
    UnknownAccount(String),
    #[error("no account is signed in")]
    NotSignedIn,
    #[error(transparent)]
    Key(#[from] KeyError),
    #[error("saved account list is corrupt: {0}")]
    Corrupt(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub pubkey: String,
    pub npub: String,
    pub display_name: String,
}

const ACCOUNTS: &str = "accounts";
const ACTIVE: &str = "active";
const ACTIVE_SECRET: &str = "active_nsec";

fn backup_name(pubkey: &str) -> String {
    format!("ncryptsec_{pubkey}")
}

pub struct Vault<S: SecretStore> {
    secrets: S,
}

impl<S: SecretStore> Vault<S> {
    pub fn new(secrets: S) -> Self {
        Self { secrets }
    }

    pub fn accounts(&self) -> Result<Vec<Account>, VaultError> {
        match self.secrets.get(ACCOUNTS)? {
            None => Ok(Vec::new()),
            Some(json) => serde_json::from_str(&json).map_err(|e| VaultError::Corrupt(e.to_string())),
        }
    }

    /// The signed-in identity, if any. Called at startup.
    pub fn active(&self) -> Result<Option<Identity>, VaultError> {
        let Some(nsec) = self.secrets.get(ACTIVE_SECRET)? else { return Ok(None) };
        Ok(Some(Identity::import(&nsec)?))
    }

    /// Saves a new or imported identity, backed up under `backup_password`,
    /// and signs it in.
    pub fn sign_up(
        &self,
        identity: &Identity,
        backup_password: &str,
        display_name: &str,
    ) -> Result<(), VaultError> {
        let backup = identity.export_backup(backup_password)?;
        self.save_account(identity, &backup, display_name)?;
        self.activate(identity)
    }

    /// Adds an account from an `ncryptsec` backup without signing it in.
    /// Decrypting first proves the password before anything is stored.
    pub fn add_account(
        &self,
        ncryptsec: &str,
        password: &str,
        display_name: &str,
    ) -> Result<Identity, VaultError> {
        let identity = Identity::import_backup(ncryptsec, password)?;
        self.save_account(&identity, ncryptsec.trim(), display_name)?;
        Ok(identity)
    }

    /// Signs in a saved account; needs that account's backup password.
    pub fn switch(&self, pubkey: &str, password: &str) -> Result<Identity, VaultError> {
        let backup = self
            .secrets
            .get(&backup_name(pubkey))?
            .ok_or_else(|| VaultError::UnknownAccount(pubkey.to_owned()))?;
        let identity = Identity::import_backup(&backup, password)?;
        self.activate(&identity)?;
        Ok(identity)
    }

    /// Forgets the active key. The account stays saved and can be switched
    /// back to with its backup password.
    pub fn sign_out(&self) -> Result<(), VaultError> {
        self.secrets.delete(ACTIVE_SECRET)?;
        self.secrets.delete(ACTIVE)
    }

    /// Removes a saved account and its backup; signs out if it was active.
    pub fn remove(&self, pubkey: &str) -> Result<(), VaultError> {
        let mut accounts = self.accounts()?;
        accounts.retain(|a| a.pubkey != pubkey);
        self.write_accounts(&accounts)?;
        self.secrets.delete(&backup_name(pubkey))?;
        if self.secrets.get(ACTIVE)?.as_deref() == Some(pubkey) {
            self.sign_out()?;
        }
        Ok(())
    }

    /// True if `password` opens the active account's backup.
    pub fn verify_backup_password(&self, password: &str) -> Result<bool, VaultError> {
        let pubkey = self.secrets.get(ACTIVE)?.ok_or(VaultError::NotSignedIn)?;
        let backup = self
            .secrets
            .get(&backup_name(&pubkey))?
            .ok_or(VaultError::UnknownAccount(pubkey))?;
        match Identity::import_backup(&backup, password) {
            Ok(_) => Ok(true),
            Err(KeyError::WrongPassword) => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// Re-encrypts the active account's backup; returns the new `ncryptsec`
    /// so the UI can offer to save it to a file.
    pub fn change_backup_password(&self, old: &str, new: &str) -> Result<String, VaultError> {
        if !self.verify_backup_password(old)? {
            return Err(KeyError::WrongPassword.into());
        }
        let identity = self.active()?.ok_or(VaultError::NotSignedIn)?;
        let backup = identity.export_backup(new)?;
        self.secrets.set(&backup_name(&identity.pubkey_hex()), &backup)?;
        Ok(backup)
    }

    fn save_account(
        &self,
        identity: &Identity,
        backup: &str,
        display_name: &str,
    ) -> Result<(), VaultError> {
        let pubkey = identity.pubkey_hex();
        // Backup first: an account listed without its backup can't be switched to.
        self.secrets.set(&backup_name(&pubkey), backup)?;
        let entry = Account { pubkey: pubkey.clone(), npub: identity.npub(), display_name: display_name.to_owned() };
        let mut accounts = self.accounts()?;
        match accounts.iter_mut().find(|a| a.pubkey == pubkey) {
            Some(existing) => *existing = entry,
            None => accounts.push(entry),
        }
        self.write_accounts(&accounts)
    }

    fn activate(&self, identity: &Identity) -> Result<(), VaultError> {
        self.secrets.set(ACTIVE_SECRET, &identity.nsec())?;
        self.secrets.set(ACTIVE, &identity.pubkey_hex())
    }

    fn write_accounts(&self, accounts: &[Account]) -> Result<(), VaultError> {
        let json = serde_json::to_string(accounts).map_err(|e| VaultError::Corrupt(e.to_string()))?;
        self.secrets.set(ACCOUNTS, &json)
    }
}

/// In-process store for tests and for running without an OS keyring.
#[derive(Default)]
pub struct MemorySecrets(Mutex<HashMap<String, String>>);

impl SecretStore for MemorySecrets {
    fn get(&self, name: &str) -> Result<Option<String>, VaultError> {
        Ok(self.0.lock().unwrap_or_else(|e| e.into_inner()).get(name).cloned())
    }

    fn set(&self, name: &str, value: &str) -> Result<(), VaultError> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_owned(), value.to_owned());
        Ok(())
    }

    fn delete(&self, name: &str) -> Result<(), VaultError> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
        Ok(())
    }
}

#[cfg(test)]
mod tests;
