//! LiveKit access tokens: HS256 JWTs signed with a provider's API secret,
//! with the claims Rails' `LivekitTokenService` puts in them.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Rails' six hours.
pub const TTL_SECS: u64 = 6 * 3600;

/// A provider's LiveKit server and keys.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Credentials {
    /// `wss://…`
    pub url: String,
    pub api_key: String,
    pub api_secret: String,
}

/// What a token lets its holder do.
#[derive(Debug, Clone, PartialEq)]
pub struct Grant {
    pub room: String,
    pub identity: String,
    pub name: String,
    pub can_publish: bool,
    /// Rails' subscribe-only token (a hearth heard from an ember): hidden,
    /// no publishing, no data.
    pub listen_only: bool,
    /// Rails' metadata: `{user_id, avatar_url, profile_color}`.
    pub metadata: Value,
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut k = [0u8; BLOCK];
    if key.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let pad = |b: u8| k.iter().map(|x| x ^ b).collect::<Vec<u8>>();
    let inner = Sha256::new().chain_update(pad(0x36)).chain_update(message).finalize();
    Sha256::new().chain_update(pad(0x5c)).chain_update(inner).finalize().into()
}

/// A signed token for `grant`, valid from `now` for `TTL_SECS`.
pub fn mint(creds: &Credentials, grant: &Grant, now: u64) -> String {
    let header = json!({"alg": "HS256", "typ": "JWT"});
    let jti: String = (0..16).map(|_| format!("{:02x}", rand::random::<u8>())).collect();
    let claims = json!({
        "iss": creds.api_key,
        "sub": grant.identity,
        "name": grant.name,
        "nbf": now.saturating_sub(5),
        "iat": now,
        "exp": now + TTL_SECS,
        "jti": jti,
        "video": {
            "roomJoin": true,
            "room": grant.room,
            "canPublish": grant.can_publish && !grant.listen_only,
            "canSubscribe": true,
            "canPublishData": !grant.listen_only,
            "hidden": grant.listen_only,
        },
        "metadata": grant.metadata.to_string(),
    });
    let body = format!("{}.{}", URL_SAFE_NO_PAD.encode(header.to_string()), URL_SAFE_NO_PAD.encode(claims.to_string()));
    let sig = hmac_sha256(creds.api_secret.as_bytes(), body.as_bytes());
    format!("{body}.{}", URL_SAFE_NO_PAD.encode(sig))
}

/// The claims of a token (unverified), for its expiry and room.
pub fn claims(token: &str) -> Option<Value> {
    let part = token.split('.').nth(1)?;
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(part).ok()?).ok()
}

/// Rails' room for a server channel: `srv-{server public id}-{channel id}`
/// (a gid is `inferno-{public id}`).
pub fn room_name(gid: &str, channel_id: &str) -> String {
    format!("srv-{}-{channel_id}", gid.strip_prefix("inferno-").unwrap_or(gid))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_matches_rfc4231() {
        // RFC 4231 test case 2.
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        let hex: String = mac.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    #[test]
    fn token_carries_rails_claims() {
        let creds = Credentials { url: "wss://lk.example".into(), api_key: "APIkey".into(), api_secret: "secret".into() };
        let grant = Grant { room: room_name("inferno-Ab3d", "ch1"), identity: "abc".into(), name: "Abc".into(), can_publish: true, listen_only: false, metadata: json!({"user_id": "abc"}) };
        let t = mint(&creds, &grant, 1_000);
        let c = claims(&t).unwrap();
        assert_eq!(c["iss"], "APIkey");
        assert_eq!(c["video"]["room"], "srv-Ab3d-ch1");
        assert_eq!(c["exp"], 1_000 + TTL_SECS);
        assert_eq!(c["metadata"], "{\"user_id\":\"abc\"}");
        let (body, sig) = t.rsplit_once('.').unwrap();
        assert_eq!(sig, URL_SAFE_NO_PAD.encode(hmac_sha256(b"secret", body.as_bytes())));
    }
}
