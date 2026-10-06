//! Relay pool. A thin layer over `nostr_sdk::Client` that bakes in the fixes
//! Flutter's `lib/nostr/relay_pool.dart` had to learn the hard way:
//!
//! - Long-lived subscriptions are keyed; re-subscribing under a key CLOSEs the
//!   old REQ first, so periodic re-syncs can't leak subscriptions until relays
//!   start rejecting them. Re-subscribing with the same filters sends nothing.
//! - Rate-limited publishes are retried with backoff, only to the relays that
//!   refused, instead of being reported as failures (or hammered).
//! - Publishing reports each relay's outcome and its NIP-20 reason, so the UI
//!   can say "rate limited" instead of failing silently.
//! - Replaceable and addressable events keep only the newest copy per address,
//!   so a stale copy from a lagging relay can never revert newer state.
//! - NIP-42 AUTH is answered automatically with the identity's keys.

use std::collections::HashMap;
use std::time::Duration;

use nostr_sdk::prelude::*;
use tokio::sync::Mutex;

/// Seeded on first run. Only ever added to: relays the user adds by hand or
/// learns from NIP-65 must survive restarts (Flutter used to wipe them).
pub const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.snort.social",
];

/// The one spelling of a relay URL we store and compare: lowercase scheme
/// and host, and no bare trailing slash, so `wss://Relay.x/` and `wss://relay.x`
/// are the same relay. `None` if it isn't a ws(s) URL.
pub fn normalize_url(url: &str) -> Option<String> {
    let parsed = RelayUrl::parse(url.trim()).ok()?;
    let s = parsed.to_string();
    Some(match s.strip_suffix('/') {
        Some(base) if !base.ends_with('/') && base.matches('/').count() == 2 => base.to_owned(),
        _ => s,
    })
}

const CONNECT_WAIT: Duration = Duration::from_secs(5);
const FETCH_TIMEOUT: Duration = Duration::from_secs(15);

pub struct RelayPool {
    client: Client,
    keyed: Mutex<HashMap<String, (SubscriptionId, Vec<Filter>)>>,
}

/// Backoff for relays that rate-limit a publish: three retries over ~7s.
const RATE_LIMIT_BACKOFF: [Duration; 3] =
    [Duration::from_secs(1), Duration::from_secs(2), Duration::from_secs(4)];

#[derive(Debug, Default)]
pub struct PublishReport {
    pub accepted: Vec<RelayUrl>,
    /// Relay URL and the reason it gave (or our transport error).
    pub rejected: Vec<(RelayUrl, String)>,
}

impl PublishReport {
    pub fn any_accepted(&self) -> bool {
        !self.accepted.is_empty()
    }

    pub fn rate_limited(&self) -> bool {
        self.rejected.iter().any(|(_, reason)| is_rate_limit(reason))
    }
}

fn is_rate_limit(reason: &str) -> bool {
    let r = reason.to_ascii_lowercase();
    r.starts_with("rate-limited") || r.contains("rate limit") || r.contains("too fast") || r.contains("slow down")
}

/// Retries `event` to the relays in `report` that rate-limited it, with
/// backoff, folding the outcomes back into the report.
async fn retry_rate_limited(client: &Client, event: &Event, report: &mut PublishReport) {
    for delay in RATE_LIMIT_BACKOFF {
        let limited: Vec<RelayUrl> =
            report.rejected.iter().filter(|(_, r)| is_rate_limit(r)).map(|(u, _)| u.clone()).collect();
        if limited.is_empty() {
            return;
        }
        tokio::time::sleep(delay).await;
        let Ok(out) = client.send_event(event).to(limited.iter().cloned()).await else { return };
        report.rejected.retain(|(u, _)| !limited.contains(u));
        report.accepted.extend(out.success.into_keys());
        report.rejected.extend(out.failed);
    }
}

impl RelayPool {
    pub fn new(keys: Keys) -> Self {
        let client = Client::builder()
            .authenticator(SignerAuthenticator::new(keys))
            .build();
        Self { client, keyed: Mutex::new(HashMap::new()) }
    }

    pub fn client(&self) -> &Client {
        &self.client
    }

    pub async fn add_relays<I, S>(&self, urls: I) -> Result<(), Error>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        for url in urls {
            self.client.add_relay(url.as_ref()).await?;
        }
        Ok(())
    }

    /// Starts connecting and waits up to a few seconds for relays to come up.
    pub async fn connect(&self) {
        self.client.connect().and_wait(CONNECT_WAIT).await;
    }

    /// Publishes to every relay. Relays that rate-limit get retried with
    /// backoff: in the background if another relay already took the event,
    /// otherwise before returning, so the caller learns whether it landed.
    pub async fn publish(&self, event: &Event) -> Result<PublishReport, Error> {
        let output = self.client.send_event(event).await?;
        let mut report = PublishReport {
            accepted: output.success.into_keys().collect(),
            rejected: output.failed.into_iter().collect(),
        };
        if report.rate_limited() {
            if report.any_accepted() {
                let (client, event) = (self.client.clone(), event.clone());
                let mut background = PublishReport { accepted: vec![], rejected: report.rejected.clone() };
                tokio::spawn(async move { retry_rate_limited(&client, &event, &mut background).await });
            } else {
                retry_rate_limited(&self.client, event, &mut report).await;
            }
        }
        Ok(report)
    }

    /// Opens (or replaces) the long-lived subscription named `key`. Events
    /// arrive on [`Self::notifications`].
    pub async fn subscribe_keyed(
        &self,
        key: &str,
        filters: Vec<Filter>,
    ) -> Result<SubscriptionId, Error> {
        let mut keyed = self.keyed.lock().await;
        if let Some((id, current)) = keyed.get(key) {
            if *current == filters {
                return Ok(id.clone());
            }
        }
        if let Some((previous, _)) = keyed.remove(key) {
            if let Err(e) = self.client.unsubscribe(&previous).await {
                tracing::warn!("closing subscription {key}: {e}");
            }
        }
        let output = self.client.subscribe(filters.clone()).await?;
        let id = output.value;
        keyed.insert(key.to_owned(), (id.clone(), filters));
        Ok(id)
    }

    pub async fn unsubscribe_keyed(&self, key: &str) {
        if let Some((id, _)) = self.keyed.lock().await.remove(key) {
            if let Err(e) = self.client.unsubscribe(&id).await {
                tracing::warn!("closing subscription {key}: {e}");
            }
        }
    }

    /// Number of keyed subscriptions; a leak shows up here, not as relay errors.
    pub async fn subscription_count(&self) -> usize {
        self.keyed.lock().await.len()
    }

    /// One-shot query across all relays, deduplicated by event id, with
    /// replaceable and addressable events collapsed to their newest copy.
    pub async fn fetch(&self, filters: Vec<Filter>) -> Result<Vec<Event>, Error> {
        let events = self.client.fetch_events(filters).timeout(FETCH_TIMEOUT).await?;
        Ok(latest_per_address(events))
    }

    pub fn notifications(
        &self,
    ) -> std::pin::Pin<Box<dyn futures::Stream<Item = ClientNotification> + Send>> {
        self.client.notifications()
    }

    pub async fn shutdown(&self) {
        self.client.shutdown().await;
    }
}

/// The address a replaceable or addressable event replaces under, or `None`
/// for regular events.
fn address(event: &Event) -> Option<(Kind, PublicKey, String)> {
    if event.kind.is_replaceable() {
        Some((event.kind, event.pubkey, String::new()))
    } else if event.kind.is_addressable() {
        Some((event.kind, event.pubkey, event.tags.identifier().unwrap_or_default().to_owned()))
    } else {
        None
    }
}

/// NIP-01: the newer `created_at` wins; on a tie, the lowest id wins.
fn supersedes(candidate: &Event, current: &Event) -> bool {
    (candidate.created_at, std::cmp::Reverse(candidate.id))
        > (current.created_at, std::cmp::Reverse(current.id))
}

pub fn latest_per_address(events: impl IntoIterator<Item = Event>) -> Vec<Event> {
    let mut latest: HashMap<(Kind, PublicKey, String), Event> = HashMap::new();
    let mut regular = Vec::new();
    for event in events {
        match address(&event) {
            Some(addr) => match latest.get(&addr) {
                Some(current) if !supersedes(&event, current) => {}
                _ => {
                    latest.insert(addr, event);
                }
            },
            None => regular.push(event),
        }
    }
    regular.extend(latest.into_values());
    regular.sort_by_key(|e| e.created_at);
    regular
}

/// Guards live state against stale copies: remembers the newest event seen per
/// address and rejects anything older. Regular events always pass.
#[derive(Default)]
pub struct FreshnessGuard {
    seen: HashMap<(Kind, PublicKey, String), (Timestamp, EventId)>,
}

impl FreshnessGuard {
    /// True if `event` should be applied; records it as the newest if so.
    pub fn accept(&mut self, event: &Event) -> bool {
        let Some(addr) = address(event) else { return true };
        let key = (event.created_at, std::cmp::Reverse(event.id));
        match self.seen.get(&addr) {
            Some(&(at, id)) if key <= (at, std::cmp::Reverse(id)) => false,
            _ => {
                self.seen.insert(addr, (event.created_at, event.id));
                true
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{dtag, kinds};

    fn server_state(keys: &Keys, at: u64, name: &str) -> Event {
        EventBuilder::new(Kind::Custom(kinds::SERVER_METADATA), name)
            .tag(Tag::identifier(dtag::metadata("inferno-abc")))
            .custom_created_at(Timestamp::from(at))
            .finalize(keys)
            .unwrap()
    }

    #[test]
    fn stale_copy_never_wins() {
        let keys = Keys::generate();
        let old = server_state(&keys, 100, "old");
        let new = server_state(&keys, 200, "new");
        let kept = latest_per_address([new.clone(), old.clone()]);
        assert_eq!(kept, vec![new.clone()]);

        let mut guard = FreshnessGuard::default();
        assert!(guard.accept(&new));
        assert!(!guard.accept(&old));
        assert!(!guard.accept(&new), "the same copy again is not news");
    }

    #[test]
    fn regular_events_all_pass() {
        let keys = Keys::generate();
        let a = EventBuilder::new(Kind::Custom(9), "a").finalize(&keys).unwrap();
        let b = EventBuilder::new(Kind::Custom(9), "b").finalize(&keys).unwrap();
        assert_eq!(latest_per_address([a.clone(), b.clone()]).len(), 2);
        let mut guard = FreshnessGuard::default();
        assert!(guard.accept(&a) && guard.accept(&a));
    }

    #[test]
    fn urls_normalize_to_one_spelling() {
        assert_eq!(normalize_url("wss://relay.damus.io/").as_deref(), Some("wss://relay.damus.io"));
        assert_eq!(normalize_url(" WSS://Relay.Damus.io ").as_deref(), Some("wss://relay.damus.io"));
        assert_eq!(normalize_url("wss://x.example/path/").as_deref(), Some("wss://x.example/path/"));
        assert_eq!(normalize_url("https://not.a.relay"), None);
        assert_eq!(normalize_url("nonsense"), None);
    }

    #[tokio::test]
    async fn keyed_subscribe_replaces_instead_of_stacking() {
        let relay = MockRelay::run().await.unwrap();
        let pool = RelayPool::new(Keys::generate());
        pool.add_relays([relay.url().await.to_string()]).await.unwrap();
        pool.connect().await;

        let filter = |k: u16| vec![Filter::new().kind(Kind::Custom(k))];
        let first = pool.subscribe_keyed("server-sync", filter(kinds::SERVER_METADATA)).await.unwrap();
        let same = pool.subscribe_keyed("server-sync", filter(kinds::SERVER_METADATA)).await.unwrap();
        assert_eq!(first, same, "identical filters send no new REQ");
        let second = pool.subscribe_keyed("server-sync", filter(kinds::SERVER_ROLES)).await.unwrap();
        assert_ne!(first, second);
        assert_eq!(pool.subscription_count().await, 1);
        assert_eq!(pool.client().subscriptions().await.len(), 1);
    }

    /// Rate-limits the first `n` writes, like a busy public relay.
    #[derive(Debug)]
    struct LimitFirst(std::sync::atomic::AtomicUsize);

    impl WritePolicy for LimitFirst {
        fn admit_event<'a>(
            &'a self,
            _event: &'a Event,
            _addr: &'a std::net::SocketAddr,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = WritePolicyResult> + Send + 'a>> {
            let left = self.0.fetch_update(
                std::sync::atomic::Ordering::SeqCst,
                std::sync::atomic::Ordering::SeqCst,
                |n| n.checked_sub(1),
            );
            Box::pin(async move {
                match left {
                    Ok(_) => WritePolicyResult::reject(MachineReadablePrefix::RateLimited, "slow down"),
                    Err(_) => WritePolicyResult::Accept,
                }
            })
        }
    }

    #[tokio::test]
    async fn rate_limited_publishes_are_retried_with_backoff() {
        let relay = LocalRelay::builder().write_policy(LimitFirst(2.into())).build();
        relay.run().await.unwrap();
        let keys = Keys::generate();
        let pool = RelayPool::new(keys.clone());
        pool.add_relays([relay.url().await.to_string()]).await.unwrap();
        pool.connect().await;

        let started = std::time::Instant::now();
        let report = pool.publish(&server_state(&keys, 100, "x")).await.unwrap();
        assert!(report.any_accepted(), "{report:?}");
        assert!(report.rejected.is_empty());
        // Two refusals: waited 1s then 2s, not hammered.
        assert!(started.elapsed() >= Duration::from_secs(3));
    }

    #[tokio::test]
    async fn publish_then_fetch_returns_the_newest_copy() {
        let relay = MockRelay::run().await.unwrap();
        let keys = Keys::generate();
        let pool = RelayPool::new(keys.clone());
        pool.add_relays([relay.url().await.to_string()]).await.unwrap();
        pool.connect().await;

        let report = pool.publish(&server_state(&keys, 100, "old")).await.unwrap();
        assert!(report.any_accepted());
        pool.publish(&server_state(&keys, 200, "new")).await.unwrap();

        let events = pool
            .fetch(vec![Filter::new().kind(Kind::Custom(kinds::SERVER_METADATA))])
            .await
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].content, "new");
    }
}
