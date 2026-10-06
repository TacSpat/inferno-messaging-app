use super::*;

fn vault() -> Vault<MemorySecrets> {
    Vault::new(MemorySecrets::default())
}

#[test]
fn sign_up_signs_in_and_saves_a_backup() {
    let v = vault();
    assert!(v.active().unwrap().is_none());
    let me = Identity::generate();
    v.sign_up(&me, "pw", "Tac").unwrap();

    assert_eq!(v.active().unwrap().unwrap().pubkey_hex(), me.pubkey_hex());
    let accounts = v.accounts().unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].display_name, "Tac");
    assert_eq!(accounts[0].npub, me.npub());
    assert!(v.verify_backup_password("pw").unwrap());
    assert!(!v.verify_backup_password("nope").unwrap());
}

#[test]
fn switching_needs_the_right_password() {
    let v = vault();
    let a = Identity::generate();
    let b = Identity::generate();
    v.sign_up(&a, "pw-a", "A").unwrap();
    v.add_account(&b.export_backup("pw-b").unwrap(), "pw-b", "B").unwrap();
    assert_eq!(v.active().unwrap().unwrap().pubkey_hex(), a.pubkey_hex(), "adding doesn't switch");

    assert!(matches!(
        v.switch(&b.pubkey_hex(), "pw-a"),
        Err(VaultError::Key(KeyError::WrongPassword))
    ));
    v.switch(&b.pubkey_hex(), "pw-b").unwrap();
    assert_eq!(v.active().unwrap().unwrap().pubkey_hex(), b.pubkey_hex());
}

#[test]
fn add_account_refuses_a_wrong_password_and_stores_nothing() {
    let v = vault();
    let b = Identity::generate();
    assert!(v.add_account(&b.export_backup("right").unwrap(), "wrong", "B").is_err());
    assert!(v.accounts().unwrap().is_empty());
}

#[test]
fn sign_out_keeps_the_account_switchable() {
    let v = vault();
    let me = Identity::generate();
    v.sign_up(&me, "pw", "Me").unwrap();
    v.sign_out().unwrap();
    assert!(v.active().unwrap().is_none());
    assert!(matches!(v.verify_backup_password("pw"), Err(VaultError::NotSignedIn)));
    v.switch(&me.pubkey_hex(), "pw").unwrap();
    assert!(v.active().unwrap().is_some());
}

#[test]
fn removing_the_active_account_signs_out() {
    let v = vault();
    let me = Identity::generate();
    v.sign_up(&me, "pw", "Me").unwrap();
    v.remove(&me.pubkey_hex()).unwrap();
    assert!(v.active().unwrap().is_none());
    assert!(v.accounts().unwrap().is_empty());
    assert!(matches!(v.switch(&me.pubkey_hex(), "pw"), Err(VaultError::UnknownAccount(_))));
}

#[test]
fn re_adding_updates_instead_of_duplicating() {
    let v = vault();
    let me = Identity::generate();
    v.sign_up(&me, "pw", "Old name").unwrap();
    v.add_account(&me.export_backup("pw").unwrap(), "pw", "New name").unwrap();
    let accounts = v.accounts().unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].display_name, "New name");
}

#[test]
fn changing_the_backup_password() {
    let v = vault();
    let me = Identity::generate();
    v.sign_up(&me, "old", "Me").unwrap();
    assert!(v.change_backup_password("wrong", "new").is_err());
    let backup = v.change_backup_password("old", "new").unwrap();
    assert!(v.verify_backup_password("new").unwrap());
    assert!(!v.verify_backup_password("old").unwrap());
    assert_eq!(Identity::import_backup(&backup, "new").unwrap().pubkey_hex(), me.pubkey_hex());
}

/// Talks to the real OS store (GNOME Keyring / KWallet / Keychain / Windows
/// Credential Manager) under a throwaway service name. Ignored by default
/// because CI machines usually have no unlocked keyring.
#[test]
#[ignore = "needs an unlocked OS keyring"]
fn os_keyring_round_trip() {
    let store = OsKeyring::with_service("inferno-test").unwrap();
    store.delete("probe").unwrap();
    assert_eq!(store.get("probe").unwrap(), None);
    store.set("probe", "secret value").unwrap();
    assert_eq!(store.get("probe").unwrap().as_deref(), Some("secret value"));
    store.delete("probe").unwrap();
    store.delete("probe").unwrap();
    assert_eq!(store.get("probe").unwrap(), None);
}

#[test]
fn pending_backup_signs_in_now_and_backs_up_later() {
    let v = vault();
    let me = Identity::generate();
    v.sign_up_pending_backup(&me, "Me").unwrap();
    assert_eq!(v.active().unwrap().unwrap().pubkey_hex(), me.pubkey_hex());
    assert!(!v.has_backup(&me.pubkey_hex()).unwrap());
    v.add_backup("pw").unwrap();
    assert!(v.has_backup(&me.pubkey_hex()).unwrap());
    assert!(v.verify_backup_password("pw").unwrap());
}
