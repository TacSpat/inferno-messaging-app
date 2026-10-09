//! Channel history, a page at a time.
//!
//! The live subscription only brings what's new from the session's start.
//! Older history comes in pages of `PAGE` messages, newest first, one
//! request at a time with a pause between (relays rate-limit):
//!
//! - what a channel on screen asks for (its placeholders came into view),
//! - then the newest page of each channel of the server being looked at,
//! - then, slowly, the newest page of every other channel.
//!
//! Each channel remembers the stretches of time it has whole (`Coverage`),
//! so a restart doesn't fetch them again, and the gaps between them are
//! where the timeline shows placeholders.

use std::collections::{HashMap, VecDeque};

use nostr_sdk::prelude::*;
use serde::{Deserialize, Serialize};

use super::{Result, Session, Update, CHANNEL_KINDS};
use crate::kinds;

/// Messages per page (below every relay's own cap on `limit`).
pub const PAGE: usize = 50;

/// `PAGE`, or `INFERNO_HISTORY_PAGE` (to watch paging on a short history).
fn page() -> usize {
    static N: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    *N.get_or_init(|| std::env::var("INFERNO_HISTORY_PAGE").ok().and_then(|v| v.parse().ok()).filter(|n| *n > 0).unwrap_or(PAGE))
}
/// The pause between pages: one asked for on screen, and a background one.
const ASKED_PAUSE: std::time::Duration = std::time::Duration::from_millis(400);
const BACKGROUND_PAUSE: std::time::Duration = std::time::Duration::from_millis(1500);
/// How often what the live subscription has covered is written down.
const HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(15);

/// The stretches of a channel's history we have whole: `(older, newer)`
/// timestamps, inclusive, oldest first, apart from each other. An `older`
/// of 0 is the channel's beginning.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Coverage {
    spans: Vec<(i64, i64)>,
}

impl Coverage {
    pub fn add(&mut self, older: i64, newer: i64) {
        if newer < older {
            return;
        }
        self.spans.push((older.max(0), newer));
        self.spans.sort_unstable();
        let mut merged: Vec<(i64, i64)> = Vec::with_capacity(self.spans.len());
        for (a, b) in self.spans.drain(..) {
            match merged.last_mut() {
                Some(last) if a <= last.1.saturating_add(1) => last.1 = last.1.max(b),
                _ => merged.push((a, b)),
            }
        }
        self.spans = merged;
    }

    /// Where history is missing, newest first: each is the `until` of the
    /// page that fills it from its newer side. `live` is where the live
    /// subscription began (it has everything from there on).
    pub fn gaps(&self, live: Option<i64>) -> Vec<i64> {
        let mut c = self.clone();
        match live {
            Some(since) => c.add(since, i64::MAX),
            None if c.spans.is_empty() => return vec![i64::MAX],
            None => {}
        }
        c.spans.iter().rev().filter(|(older, _)| *older > 0).map(|(older, _)| *older).collect()
    }

    /// Nothing is missing between `live` and what we already have: the
    /// channel's newest page isn't needed.
    fn joins_live(&self, live: i64) -> bool {
        self.spans.iter().any(|&(older, newer)| older < live && newer.saturating_add(1) >= live)
    }
}

/// Pages waiting, and what each channel has.
#[derive(Default)]
pub(super) struct History {
    coverage: HashMap<String, Coverage>,
    /// Group → where its live subscription began, this session.
    live: HashMap<String, i64>,
    /// (group, until): asked for on screen; the server being looked at;
    /// everything else.
    asked: VecDeque<(String, i64)>,
    soon: VecDeque<(String, i64)>,
    later: VecDeque<(String, i64)>,
    busy: Option<(String, i64)>,
}

impl History {
    fn queued(&self, job: &(String, i64)) -> bool {
        self.busy.as_ref() == Some(job) || self.asked.contains(job) || self.soon.contains(job) || self.later.contains(job)
    }

    fn next(&mut self) -> Option<((String, i64), bool)> {
        let asked = self.asked.pop_front().map(|j| (j, true));
        let job = asked.or_else(|| self.soon.pop_front().or_else(|| self.later.pop_front()).map(|j| (j, false)))?;
        self.busy = Some(job.0.clone());
        Some(job)
    }
}

fn key(group: &str) -> String {
    format!("history:{group}")
}

impl Session {
    /// A group's coverage, read from the store the first time. A channel
    /// cached before coverage was kept counts as whole from its oldest
    /// cached message to its newest.
    fn coverage_of(&self, h: &mut History, group: &str) -> Result<Coverage> {
        if let Some(c) = h.coverage.get(group) {
            return Ok(c.clone());
        }
        let c = match self.store.get_setting::<Coverage>(&key(group))? {
            Some(c) => c,
            None => {
                let groups = [group.to_owned()];
                let mut c = Coverage::default();
                let span = (
                    self.store.oldest_tagged(&[kinds::CHANNEL_MESSAGE], 'h', &groups)?,
                    self.store.newest_tagged(&[kinds::CHANNEL_MESSAGE], 'h', &groups)?,
                );
                if let (Some(older), Some(newer)) = span {
                    c.add(older, newer);
                }
                c
            }
        };
        h.coverage.insert(group.to_owned(), c.clone());
        Ok(c)
    }

    fn cover(&self, h: &mut History, group: &str, older: i64, newer: i64) -> Result<()> {
        let mut c = self.coverage_of(h, group)?;
        c.add(older, newer);
        self.store.set_setting(&key(group), &c)?;
        h.coverage.insert(group.to_owned(), c);
        Ok(())
    }

    fn group_of(&self, gid: &str, channel_id: &str) -> Result<Option<String>> {
        let state = self.server(gid)?;
        Ok(state.and_then(|s| s.channel(channel_id).and_then(|c| c.group_id.clone())))
    }

    /// Where a channel's history is missing, newest first (see
    /// `Coverage::gaps`): the timeline's placeholders go there.
    pub fn history_gaps(&self, gid: &str, channel_id: &str) -> Result<Vec<i64>> {
        let Some(group) = self.group_of(gid, channel_id)? else { return Ok(Vec::new()) };
        let mut h = self.history.lock().unwrap_or_else(|e| e.into_inner());
        let live = h.live.get(&group).copied();
        Ok(self.coverage_of(&mut h, &group)?.gaps(live))
    }

    /// The page of history up to `until` (a gap's), ahead of everything
    /// else: its placeholders are on screen.
    pub fn want_history(&self, gid: &str, channel_id: &str, until: i64) -> Result<()> {
        let Some(group) = self.group_of(gid, channel_id)? else { return Ok(()) };
        let job = (group, until);
        let mut h = self.history.lock().unwrap_or_else(|e| e.into_inner());
        if !h.queued(&job) {
            h.asked.push_back(job);
            self.history_wake.notify_one();
        }
        Ok(())
    }

    /// The server being looked at: its channels' newest pages come next.
    pub fn prefer_server(&self, gid: &str) -> Result<()> {
        let Some(state) = self.server(gid)? else { return Ok(()) };
        let groups: Vec<String> = state.structure.channels.iter().filter_map(|c| c.group_id.clone()).collect();
        let mut h = self.history.lock().unwrap_or_else(|e| e.into_inner());
        let (moved, kept): (Vec<_>, Vec<_>) = h.later.drain(..).partition(|(g, _)| groups.contains(g));
        h.later = kept.into();
        h.soon.extend(moved);
        self.history_wake.notify_one();
        Ok(())
    }

    /// The live subscription now covers `groups` from `since`: a group new
    /// to it this session gets its newest page queued, unless what we
    /// have already reaches `since`.
    pub(super) fn history_live(&self, groups: &[String], since: i64) -> Result<()> {
        let mut h = self.history.lock().unwrap_or_else(|e| e.into_inner());
        for g in groups {
            if h.live.contains_key(g) {
                continue;
            }
            h.live.insert(g.clone(), since);
            if !self.coverage_of(&mut h, g)?.joins_live(since) {
                let job = (g.clone(), since);
                if !h.queued(&job) {
                    h.later.push_back(job);
                }
            }
        }
        self.history_wake.notify_one();
        Ok(())
    }

    /// Fetches one page: messages up to `until`, and the deletes, pins and
    /// reactions around them, in one request.
    async fn fetch_page(&self, group: &str, until: i64) -> Result<()> {
        let h = SingleLetterTag::from_char('h').expect("h");
        let until_ts = Timestamp::from(until.clamp(0, i64::MAX) as u64);
        let messages = Filter::new()
            .kind(Kind::Custom(kinds::CHANNEL_MESSAGE))
            .custom_tags(h, [group.to_owned()])
            .until(until_ts)
            .limit(page());
        let others: Vec<Kind> = CHANNEL_KINDS.iter().filter(|k| **k != kinds::CHANNEL_MESSAGE).map(|k| Kind::Custom(*k)).collect();
        let around = Filter::new().kinds(others).custom_tags(h, [group.to_owned()]).until(until_ts).limit(page() * 3);
        let events = self.pool.fetch(vec![messages, around]).await?;
        let mut times: Vec<i64> = Vec::new();
        for e in &events {
            self.store.put_event(e)?;
            if e.kind.as_u16() == kinds::CHANNEL_MESSAGE {
                times.push(e.created_at.as_secs() as i64);
            }
        }
        // Several relays answer: what they all have whole reaches back to
        // the PAGE-th newest message of them all. Fewer: the beginning.
        times.sort_unstable_by(|a, b| b.cmp(a));
        let older = if times.len() < page() { 0 } else { times[page() - 1] };
        let mut hist = self.history.lock().unwrap_or_else(|e| e.into_inner());
        self.cover(&mut hist, group, older, until)?;
        Ok(())
    }

    /// Writes down what the live subscriptions have covered so far.
    fn history_heartbeat(&self) -> Result<()> {
        let now = Timestamp::now().as_secs() as i64;
        let mut h = self.history.lock().unwrap_or_else(|e| e.into_inner());
        let live: Vec<(String, i64)> = h.live.iter().map(|(g, s)| (g.clone(), *s)).collect();
        for (g, since) in live {
            self.cover(&mut h, &g, since, now)?;
        }
        Ok(())
    }

    /// The task that fetches pages, one at a time.
    pub(super) fn spawn_history(self: &std::sync::Arc<Self>) {
        let (me, wake) = (std::sync::Arc::downgrade(self), self.history_wake.clone());
        tokio::spawn(async move {
            let mut beat = tokio::time::interval(HEARTBEAT);
            beat.tick().await;
            loop {
                let job = match me.upgrade() {
                    Some(s) => s.history.lock().unwrap_or_else(|e| e.into_inner()).next(),
                    None => break,
                };
                let Some(((group, until), asked)) = job else {
                    tokio::select! {
                        _ = wake.notified() => {}
                        _ = beat.tick() => {
                            let Some(s) = me.upgrade() else { break };
                            if let Err(e) = s.history_heartbeat() {
                                tracing::warn!("history heartbeat: {e}");
                            }
                        }
                    }
                    continue;
                };
                let Some(s) = me.upgrade() else { break };
                if let Err(e) = s.fetch_page(&group, until).await {
                    tracing::warn!("history page for {group}: {e}");
                }
                s.history.lock().unwrap_or_else(|e| e.into_inner()).busy = None;
                let place = s.groups.lock().unwrap_or_else(|e| e.into_inner()).get(&group).cloned();
                if let Some((gid, channel_id)) = place {
                    let _ = s.updates.send(Update::Channel { gid, channel_id });
                }
                drop(s);
                tokio::time::sleep(if asked { ASKED_PAUSE } else { BACKGROUND_PAUSE }).await;
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_merge_and_leave_gaps() {
        let mut c = Coverage::default();
        c.add(100, 200);
        c.add(300, 400);
        c.add(201, 250);
        assert_eq!(c.spans, vec![(100, 250), (300, 400)]);
        // Live from 500: missing below it, below 300, and below 100.
        assert_eq!(c.gaps(Some(500)), vec![500, 300, 100]);
        c.add(380, 520);
        assert_eq!(c.gaps(Some(500)), vec![300, 100]);
        assert!(c.joins_live(500));
        c.add(0, 300);
        assert!(c.gaps(Some(500)).is_empty(), "everything back to the beginning");
        assert_eq!(Coverage::default().gaps(None), vec![i64::MAX]);
        assert_eq!(Coverage::default().gaps(Some(500)), vec![500]);
        assert!(!Coverage::default().joins_live(500));
    }
}
