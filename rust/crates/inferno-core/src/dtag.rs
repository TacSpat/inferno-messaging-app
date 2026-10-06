//! d-tags for the server-state kinds. These must match Rails byte for byte
//! (`app/jobs/nostr_server_publish_job.rb`, `app/services/nostr_server_sync_service.rb`).
//!
//! `gid` is always the server's `nostr_group_id` used as-is. Servers created by
//! Rails already carry an `inferno-` prefix in that id (`inferno-{public_id}`),
//! so the metadata tag is `inferno-inferno-{public_id}` and the member tag is
//! `inferno-mbr-inferno-{public_id}-{pubkey16}`. Never strip or add a prefix.

use crate::kinds;

/// Member, ban and invite tags carry the first 16 hex chars of the pubkey.
const PUBKEY_PREFIX_LEN: usize = 16;

pub fn metadata(gid: &str) -> String {
    format!("inferno-{gid}")
}

pub fn structure(gid: &str) -> String {
    format!("inferno-struct-{gid}")
}

pub fn roles(gid: &str) -> String {
    format!("inferno-roles-{gid}")
}

pub fn emojis(gid: &str) -> String {
    format!("inferno-emojis-{gid}")
}

pub fn stickers(gid: &str) -> String {
    format!("inferno-stickers-{gid}")
}

pub fn member(gid: &str, pubkey_hex: &str) -> String {
    format!("{}{}", member_prefix(gid), pubkey_prefix(pubkey_hex))
}

pub fn ban(gid: &str, pubkey_hex: &str) -> String {
    format!("{}{}", ban_prefix(gid), pubkey_prefix(pubkey_hex))
}

pub fn invite(gid: &str, code: &str) -> String {
    format!("{}{code}", invite_prefix(gid))
}

/// Prefixes for the per-member kinds; relays can't filter on a prefix, so
/// fetch by kind and keep the events whose d-tag starts with one of these.
pub fn member_prefix(gid: &str) -> String {
    format!("inferno-mbr-{gid}-")
}

pub fn ban_prefix(gid: &str) -> String {
    format!("inferno-ban-{gid}-")
}

pub fn invite_prefix(gid: &str) -> String {
    format!("inferno-invite-{gid}-")
}

fn pubkey_prefix(pubkey_hex: &str) -> &str {
    &pubkey_hex[..pubkey_hex.len().min(PUBKEY_PREFIX_LEN)]
}

/// Recovers the server gid from a single-per-server state event's d-tag.
/// Returns `None` for kinds whose tag also carries a pubkey or code, since a
/// gid may itself contain `-` and can't be split back out of those reliably;
/// read the gid from the event's `h` tag instead.
pub fn gid_from(kind: u16, d: &str) -> Option<&str> {
    let prefix = match kind {
        kinds::SERVER_METADATA => "inferno-",
        kinds::SERVER_STRUCTURE => "inferno-struct-",
        kinds::SERVER_ROLES => "inferno-roles-",
        kinds::SERVER_EMOJI => "inferno-emojis-",
        kinds::SERVER_STICKERS => "inferno-stickers-",
        _ => return None,
    };
    d.strip_prefix(prefix).filter(|gid| !gid.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    const RAILS_GID: &str = "inferno-abc123";
    const PUBKEY: &str = "f7234bd4c1394dda46d09f35bd384dd30cc552ad5541990f98844fb06676e9ca";

    #[test]
    fn rails_created_server_keeps_the_doubled_prefix() {
        assert_eq!(metadata(RAILS_GID), "inferno-inferno-abc123");
        assert_eq!(structure(RAILS_GID), "inferno-struct-inferno-abc123");
        assert_eq!(roles(RAILS_GID), "inferno-roles-inferno-abc123");
        assert_eq!(emojis(RAILS_GID), "inferno-emojis-inferno-abc123");
        assert_eq!(stickers(RAILS_GID), "inferno-stickers-inferno-abc123");
    }

    #[test]
    fn per_member_tags_use_a_16_char_pubkey_prefix() {
        assert_eq!(member(RAILS_GID, PUBKEY), "inferno-mbr-inferno-abc123-f7234bd4c1394dda");
        assert_eq!(ban(RAILS_GID, PUBKEY), "inferno-ban-inferno-abc123-f7234bd4c1394dda");
        assert!(member(RAILS_GID, PUBKEY).starts_with(&member_prefix(RAILS_GID)));
    }

    #[test]
    fn invite_tag() {
        assert_eq!(invite(RAILS_GID, "XyZ9"), "inferno-invite-inferno-abc123-XyZ9");
    }

    #[test]
    fn gid_round_trips_for_single_per_server_kinds() {
        assert_eq!(gid_from(kinds::SERVER_METADATA, &metadata(RAILS_GID)), Some(RAILS_GID));
        assert_eq!(gid_from(kinds::SERVER_STRUCTURE, &structure(RAILS_GID)), Some(RAILS_GID));
        assert_eq!(gid_from(kinds::SERVER_ROLES, &roles(RAILS_GID)), Some(RAILS_GID));
        assert_eq!(gid_from(kinds::SERVER_MEMBER, &member(RAILS_GID, PUBKEY)), None);
        assert_eq!(gid_from(kinds::SERVER_METADATA, "inferno-"), None);
    }
}
