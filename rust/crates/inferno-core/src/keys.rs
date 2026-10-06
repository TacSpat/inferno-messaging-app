//! Identity keys: generate, import (nsec or hex), and NIP-49 password backup.
//! Where the secret lives at rest (OS keyring) is the storage layer's job.

use nostr::nips::nip19::{FromBech32, ToBech32};
use nostr::nips::nip49::{EncryptedSecretKey, KeySecurity};
use nostr::key::{Keys, SecretKey};

/// scrypt cost for exported backups. 16 is NIP-49's suggested floor and keeps
/// decryption well under a second on phones.
const BACKUP_LOG_N: u8 = 16;

#[derive(Debug, thiserror::Error)]
pub enum KeyError {
    #[error("not a valid nsec or hex secret key")]
    InvalidSecret,
    #[error("not a valid ncryptsec backup")]
    InvalidBackup,
    #[error("wrong password or corrupted backup")]
    WrongPassword,
    #[error("could not encrypt the key: {0}")]
    Encrypt(String),
}

pub struct Identity {
    keys: Keys,
}

impl Identity {
    pub fn generate() -> Self {
        Self { keys: Keys::generate() }
    }

    /// Accepts `nsec1...` or 64-char hex, trimming surrounding whitespace.
    pub fn import(secret: &str) -> Result<Self, KeyError> {
        let keys = Keys::parse(secret.trim()).map_err(|_| KeyError::InvalidSecret)?;
        Ok(Self { keys })
    }

    pub fn keys(&self) -> &Keys {
        &self.keys
    }

    pub fn pubkey_hex(&self) -> String {
        self.keys.public_key().to_hex()
    }

    pub fn npub(&self) -> String {
        self.keys.public_key().to_bech32().expect("bech32 of a valid pubkey")
    }

    pub fn nsec(&self) -> String {
        self.keys.secret_key().to_bech32().expect("bech32 of a valid secret key")
    }

    /// NIP-49 `ncryptsec1...` backup protected by `password`.
    pub fn export_backup(&self, password: &str) -> Result<String, KeyError> {
        let encrypted = EncryptedSecretKey::new(
            self.keys.secret_key(),
            password,
            BACKUP_LOG_N,
            KeySecurity::Unknown,
        )
        .map_err(|e| KeyError::Encrypt(e.to_string()))?;
        encrypted.to_bech32().map_err(|e| KeyError::Encrypt(e.to_string()))
    }

    pub fn import_backup(ncryptsec: &str, password: &str) -> Result<Self, KeyError> {
        let encrypted = EncryptedSecretKey::from_bech32(ncryptsec.trim())
            .map_err(|_| KeyError::InvalidBackup)?;
        let secret: SecretKey = encrypted.decrypt(password).map_err(|_| KeyError::WrongPassword)?;
        Ok(Self { keys: Keys::new(secret) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nsec_and_hex_import_give_the_same_identity() {
        let id = Identity::generate();
        let from_nsec = Identity::import(&id.nsec()).unwrap();
        let from_hex = Identity::import(&format!("  {}\n", id.keys().secret_key().to_secret_hex())).unwrap();
        assert_eq!(from_nsec.pubkey_hex(), id.pubkey_hex());
        assert_eq!(from_hex.pubkey_hex(), id.pubkey_hex());
        assert!(id.npub().starts_with("npub1"));
    }

    #[test]
    fn rejects_garbage() {
        assert!(matches!(Identity::import("nsec1nope"), Err(KeyError::InvalidSecret)));
    }

    #[test]
    fn backup_round_trip_and_wrong_password() {
        let id = Identity::generate();
        let backup = id.export_backup("correct horse").unwrap();
        assert!(backup.starts_with("ncryptsec1"));
        let restored = Identity::import_backup(&backup, "correct horse").unwrap();
        assert_eq!(restored.pubkey_hex(), id.pubkey_hex());
        assert!(matches!(
            Identity::import_backup(&backup, "wrong"),
            Err(KeyError::WrongPassword)
        ));
    }
}
