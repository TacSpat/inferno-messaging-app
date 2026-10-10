//! Getting events out, and keeping them out there.
//!
//! - The outbox: an event no relay takes (we're offline, the relays are
//!   down, they rate-limit us) waits in the cache and is sent again with
//!   backoff, after a restart too. Relays that failed for a passing reason
//!   (not "blocked:", "invalid:" …) while others took the event get it
//!   again too, so every relay of ours ends up with it. Nothing is lost
//!   because a send failed once.
//! - Healing: relays drop events (pruning, a wiped relay, one that missed
//!   them while down). After start and every few hours, each relay is asked
//!   which of the events we stand behind it still holds: every joined
//!   server's current state and our own profile, relay list and settings.
//!   Whatever one lacks is sent to that relay again, as signed by its
//!   author, so a server rebuilds itself from any member's copy.

use std::collections::HashSet;
use std::sync::{Arc, Weak};
use std::time::Duration;

use nostr_sdk::prelude::*;

use super::{Result, Session, Update};
use crate::relay::{is_permanent, PublishReport};

/// Waits between tries: quick at first (a blip), then patient.
const BACKOFF: [u64; 7] = [5, 15, 30, 60, 300, 900, 1800];
/// After this long an event is given up on (and the log says so).
const GIVE_UP_SECS: u64 = 7 * 24 * 3600;
/// Healing: the first pass once start-up syncing has settled, then again.
const FIRST_HEAL: Duration = Duration::from_secs(45);
const HEAL_EVERY: Duration = Duration::from_secs(6 * 3600);
/// Ids asked for in one query; repairs sent to a relay per pass (spaced,
/// so a repair never trips a relay's rate limit).
const HEAL_BATCH: usize = 400;
const HEAL_MAX_PER_RELAY: usize = 200;
const HEAL_SPACING: Duration = Duration::from_millis(150);

fn now() -> u64 {
    Timestamp::now().as_secs()
}

fn wait(attempts: u32) -> u64 {
    BACKOFF[(attempts as usize).min(BACKOFF.len() - 1)]
}

/// Events that are only worth sending now: expiring voice state (it's
/// refreshed anyway), live control messages (voice RPC, typing).
fn worth_keeping(event: &Event) -> bool {
    let expiring = event.tags.iter().any(|t| t.as_slice().first().map(String::as_str) == Some("expiration"));
    let live = event.kind == Kind::Custom(crate::kinds::TYPING) || event.kind == Kind::Custom(crate::kinds::VOICE_STATE);
    !expiring && !live
}

/// From a publish report: the relays worth trying again (they failed for
/// a passing reason).
fn retryable(report: &PublishReport) -> Vec<String> {
    report.rejected.iter().filter(|(_, why)| !is_permanent(why)).map(|(u, _)| u.to_string()).collect()
}

impl Session {
    /// Sends `event` to our relays. Whatever doesn't land is queued: the
    /// whole event if no relay took it, else for the relays that failed for
    /// a passing reason. Never fails for want of relays: the event is ours
    /// and will go out. `shows_as`: the id the UI knows it by (a DM's
    /// message rather than its gift wrap), so it can say "Sending…".
    pub(super) async fn send_out(&self, event: &Event, shows_as: Option<&str>) -> Result<PublishReport> {
        let report = match self.pool.publish(event).await {
            Ok(r) => r,
            // Not connected at all: everything waits.
            Err(e) => {
                tracing::info!("queueing {}: {e}", event.id);
                PublishReport::default()
            }
        };
        if !worth_keeping(event) {
            return Ok(report);
        }
        let shows = shows_as.map(str::to_owned).unwrap_or_else(|| event.id.to_hex());
        if !report.any_accepted() {
            // Refused for good everywhere: nothing to wait for.
            let refused = !report.rejected.is_empty() && report.rejected.iter().all(|(_, why)| is_permanent(why));
            if refused {
                tracing::warn!("refused {}: {:?}", event.id, report.rejected);
                return Ok(report);
            }
            self.store.queue_event(event, &shows, &[], now() + wait(0))?;
            let _ = self.updates.send(Update::Outbox);
            self.outbox_wake.notify_one();
        } else {
            let behind = retryable(&report);
            if !behind.is_empty() {
                // Landed somewhere: the others catch up quietly.
                self.store.queue_event(event, &shows, &behind, now() + wait(1))?;
            }
        }
        Ok(report)
    }

    /// The ids (as the UI knows them) of what's waiting to be sent.
    pub fn queued(&self) -> HashSet<String> {
        self.store.queued_ids().map(|v| v.into_iter().collect()).unwrap_or_default()
    }

    /// Sends what's waiting now (a relay came back, or the user asked).
    pub fn send_queued_now(&self) {
        let _ = self.store.hurry_queue();
        self.outbox_wake.notify_one();
    }

    /// One pass over what's due. True if anything changed for the UI.
    async fn flush_outbox(&self) -> Result<bool> {
        let due = self.store.due_events(now())?;
        let mut changed = false;
        for q in due {
            let id = q.event.id;
            // Deleted, or replaced by a newer copy since: not worth sending.
            let superseded = self.store.is_deleted(&id)? || self.newer_copy(&q.event)?;
            let too_old = now().saturating_sub(q.event.created_at.as_secs()) > GIVE_UP_SECS;
            if superseded || too_old {
                if too_old {
                    tracing::warn!("giving up on {id} after {} tries", q.attempts);
                }
                self.store.unqueue_event(&id)?;
                changed = true;
                continue;
            }
            let report = if q.relays.is_empty() {
                self.pool.publish(&q.event).await.unwrap_or_default()
            } else {
                let urls: Vec<RelayUrl> = q.relays.iter().filter_map(|u| RelayUrl::parse(u).ok()).collect();
                self.pool.publish_to(&q.event, &urls).await.unwrap_or_default()
            };
            // Waiting for any relay: done once one took it. Waiting for
            // particular relays: done once none is left to retry.
            let left = if q.relays.is_empty() { Vec::new() } else { retryable(&report) };
            let done = if q.relays.is_empty() { report.any_accepted() } else { left.is_empty() };
            if done {
                self.store.unqueue_event(&id)?;
                // Landed: the relays that failed this time catch up later.
                let behind = retryable(&report);
                if q.relays.is_empty() && !behind.is_empty() {
                    let shows = id.to_hex();
                    self.store.queue_event(&q.event, &shows, &behind, now() + wait(1))?;
                }
                changed = true;
            } else if !report.rejected.is_empty() && report.rejected.iter().all(|(_, why)| is_permanent(why)) {
                tracing::warn!("refused {id}: {:?}", report.rejected);
                self.store.unqueue_event(&id)?;
                changed = true;
            } else {
                self.store.retry_event(&id, &left, now() + wait(q.attempts + 1))?;
            }
        }
        Ok(changed)
    }

    /// A newer copy of this replaceable event exists (ours, since sent).
    fn newer_copy(&self, event: &Event) -> Result<bool> {
        let d = if event.kind.is_addressable() {
            event.tags.identifier().unwrap_or_default().to_owned()
        } else if event.kind.is_replaceable() {
            String::new()
        } else {
            return Ok(false);
        };
        Ok(self.store.get_addressable(event.kind, &event.pubkey, &d)?.is_some_and(|cur| cur.created_at > event.created_at))
    }

    /// Everything we keep alive on our relays: every joined server's
    /// current state, and our own profile, relay lists and settings.
    fn worth_healing(&self) -> Result<Vec<Event>> {
        let mut out = Vec::new();
        for gid in self.servers()? {
            out.extend(self.store.server_events(&gid)?);
        }
        let me = self.keys.public_key();
        for (kind, d) in [
            (Kind::Metadata, ""),
            (Kind::RelayList, ""),
            (Kind::InboxRelays, ""),
            (Kind::Custom(crate::kinds::APP_CONFIG), crate::sync::config::SERVERS_D),
            (Kind::Custom(crate::kinds::APP_CONFIG), crate::sync::config::CONFIG_D),
        ] {
            out.extend(self.store.get_addressable(kind, &me, d)?);
        }
        Ok(out)
    }

    /// One healing pass: each relay is asked which of our events it holds,
    /// and sent the ones it lacks. Returns how many were sent again.
    pub async fn heal(&self) -> Result<usize> {
        let events = self.worth_healing()?;
        if events.is_empty() {
            return Ok(0);
        }
        let mut repaired = 0;
        for relay in self.pool.write_relays().await {
            let mut missing = Vec::new();
            for chunk in events.chunks(HEAL_BATCH) {
                let held = match self.pool.held_by(&relay, chunk.iter().map(|e| e.id).collect()).await {
                    Ok(h) => h,
                    // Unreachable now: it's healed on a later pass.
                    Err(_) => break,
                };
                missing.extend(chunk.iter().filter(|e| !held.contains(&e.id)));
            }
            for event in missing.into_iter().take(HEAL_MAX_PER_RELAY) {
                let report = self.pool.publish_to(event, std::slice::from_ref(&relay)).await.unwrap_or_default();
                if report.any_accepted() {
                    repaired += 1;
                }
                tokio::time::sleep(HEAL_SPACING).await;
            }
        }
        if repaired > 0 {
            tracing::info!("healed {repaired} events on our relays");
        }
        Ok(repaired)
    }

    /// The outbox's sender and the healer, for the session's life.
    pub(super) fn spawn_outbox(self: &Arc<Self>) {
        let me: Weak<Self> = Arc::downgrade(self);
        let wake = self.outbox_wake.clone();
        tokio::spawn(async move {
            loop {
                // Due ones go out every few seconds, or at once when woken.
                let _ = tokio::time::timeout(Duration::from_secs(5), wake.notified()).await;
                let Some(s) = me.upgrade() else { break };
                match s.flush_outbox().await {
                    Ok(true) => {
                        let _ = s.updates.send(Update::Outbox);
                    }
                    Ok(false) => {}
                    Err(e) => tracing::warn!("outbox: {e}"),
                }
            }
        });
        let me = Arc::downgrade(self);
        tokio::spawn(async move {
            tokio::time::sleep(FIRST_HEAL).await;
            loop {
                let Some(s) = me.upgrade() else { break };
                if let Err(e) = s.heal().await {
                    tracing::warn!("healing: {e}");
                }
                drop(s);
                tokio::time::sleep(HEAL_EVERY).await;
            }
        });
    }
}
