//! Channel and category ordering, as Rails lays out the sidebar
//! (`layouts/application.html.erb`): the root holds uncategorized channels
//! and categories interleaved by position; each category holds its channels
//! by position. Moves renumber positions 0..n within the container touched,
//! so positions stay dense and every client sorts the same way.

use super::wire::Structure;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RootItem {
    Channel(String),
    Category(String),
}

/// Top-level sidebar order. Ties keep categories after channels, then id
/// order, so the result never depends on input order.
pub fn root_items(s: &Structure) -> Vec<RootItem> {
    let mut items: Vec<(i64, u8, String, RootItem)> = s
        .channels
        .iter()
        .filter(|c| c.category.is_none() && s.hearth_of(&c.id).is_none())
        .map(|c| (c.position, 0, c.id.clone(), RootItem::Channel(c.id.clone())))
        .chain(s.categories.iter().map(|c| (c.position, 1, c.id.clone(), RootItem::Category(c.id.clone()))))
        .collect();
    items.sort_by(|a, b| (a.0, a.1, &a.2).cmp(&(b.0, b.1, &b.2)));
    items.into_iter().map(|i| i.3).collect()
}

/// Channel ids in `category`, in order.
pub fn in_category(s: &Structure, category: &str) -> Vec<String> {
    let mut chans: Vec<_> = s.channels.iter().filter(|c| c.category.as_deref() == Some(category) && s.hearth_of(&c.id).is_none()).collect();
    chans.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    chans.into_iter().map(|c| c.id.clone()).collect()
}

/// The embers directly under hearth `id`, in order.
pub fn embers(s: &Structure, id: &str) -> Vec<String> {
    let mut chans: Vec<_> = s.channels.iter().filter(|c| s.hearth_of(&c.id) == Some(id)).collect();
    chans.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
    chans.into_iter().map(|c| c.id.clone()).collect()
}

/// A channel row as the sidebar draws it under its hearths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nested {
    pub id: String,
    /// 0 at the top; 1 and 2 for embers.
    pub depth: usize,
    /// Last among its hearth's embers (the connector ends here).
    pub last: bool,
    /// Per level above it, whether that level's line continues past this
    /// row (the ancestor there has later siblings).
    pub guides: Vec<bool>,
}

/// `id` followed by its embers, depth first, as Rails nests them.
pub fn with_embers(s: &Structure, id: &str) -> Vec<Nested> {
    fn go(s: &Structure, id: &str, depth: usize, last: bool, guides: Vec<bool>, out: &mut Vec<Nested>) {
        out.push(Nested { id: id.to_owned(), depth, last, guides: guides.clone() });
        if depth + 1 >= Structure::MAX_NESTING + 1 {
            return;
        }
        let kids = embers(s, id);
        let mut next = guides;
        if depth > 0 {
            next.push(!last);
        }
        for (i, k) in kids.iter().enumerate() {
            go(s, k, depth + 1, i + 1 == kids.len(), next.clone(), out);
        }
    }
    let mut out = Vec::new();
    go(s, id, 0, true, Vec::new(), &mut out);
    out
}

fn renumber_root(s: &mut Structure, order: &[RootItem]) {
    for (pos, item) in order.iter().enumerate() {
        match item {
            RootItem::Channel(id) => {
                if let Some(c) = s.channels.iter_mut().find(|c| &c.id == id) {
                    c.position = pos as i64;
                }
            }
            RootItem::Category(id) => {
                if let Some(c) = s.categories.iter_mut().find(|c| &c.id == id) {
                    c.position = pos as i64;
                }
            }
        }
    }
}

fn renumber_category(s: &mut Structure, order: &[String]) {
    for (pos, id) in order.iter().enumerate() {
        if let Some(c) = s.channels.iter_mut().find(|c| &c.id == id) {
            c.position = pos as i64;
        }
    }
}

/// Moves channel `id` into `category` (`None` = the root) at `index` within
/// that container (clamped). Both the old and new containers are renumbered.
pub fn move_channel(s: &mut Structure, id: &str, category: Option<&str>, index: usize) -> bool {
    let Some(from) = s.channels.iter().find(|c| c.id == id).map(|c| c.category.clone()) else { return false };
    if let Some(cat) = category {
        if !s.categories.iter().any(|c| c.id == cat) {
            return false;
        }
    }
    // Take it out of where it was.
    match &from {
        None => {
            let order: Vec<_> = root_items(s).into_iter().filter(|i| *i != RootItem::Channel(id.into())).collect();
            renumber_root(s, &order);
        }
        Some(cat) => {
            let order: Vec<_> = in_category(s, cat).into_iter().filter(|c| c != id).collect();
            renumber_category(s, &order);
        }
    }
    // Put it where it goes.
    if let Some(c) = s.channels.iter_mut().find(|c| c.id == id) {
        c.category = category.map(str::to_owned);
    }
    match category {
        None => {
            let mut order: Vec<_> = root_items(s).into_iter().filter(|i| *i != RootItem::Channel(id.into())).collect();
            order.insert(index.min(order.len()), RootItem::Channel(id.into()));
            renumber_root(s, &order);
        }
        Some(cat) => {
            let mut order: Vec<_> = in_category(s, cat).into_iter().filter(|c| c != id).collect();
            order.insert(index.min(order.len()), id.to_owned());
            renumber_category(s, &order);
        }
    }
    true
}

/// Moves category `id` to `index` among the root items.
pub fn move_category(s: &mut Structure, id: &str, index: usize) -> bool {
    if !s.categories.iter().any(|c| c.id == id) {
        return false;
    }
    let mut order: Vec<_> = root_items(s).into_iter().filter(|i| *i != RootItem::Category(id.into())).collect();
    order.insert(index.min(order.len()), RootItem::Category(id.into()));
    renumber_root(s, &order);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::wire::{Category, Channel};

    fn chan(id: &str, cat: Option<&str>, pos: i64) -> Channel {
        Channel {
            id: id.into(),
            name: id.into(),
            kind: "text".into(),
            position: pos,
            category: cat.map(str::to_owned),
            topic: String::new(),
            nsfw: false,
            group_id: None,
            permission_overrides: Default::default(),
            encrypted: false,
            channel_pubkey: None,
            sidechat: None,
            parent: None,
            voice_bitrate: 64_000,
            voice_user_limit: 0,
            video_enabled: false,
            post_only: false,
        }
    }

    fn voice(id: &str, parent: Option<&str>, pos: i64) -> Channel {
        Channel { kind: "voice".into(), parent: parent.map(str::to_owned), ..chan(id, Some("cat"), pos) }
    }

    #[test]
    fn embers_nest_under_their_hearth() {
        let mut s = sample();
        s.channels.push(voice("hearth", None, 2));
        s.channels.push(voice("e1", Some("hearth"), 0));
        s.channels.push(voice("e2", Some("hearth"), 1));
        s.channels.push(voice("deep", Some("e1"), 0));
        assert_eq!(in_category(&s, "cat"), ["a", "b", "hearth"], "embers aren't top-level");
        let rows = with_embers(&s, "hearth");
        let ids: Vec<_> = rows.iter().map(|r| (r.id.as_str(), r.depth, r.last)).collect();
        assert_eq!(ids, [("hearth", 0, true), ("e1", 1, false), ("deep", 2, true), ("e2", 1, true)]);
        assert_eq!(rows[2].guides, vec![true], "e1 has a later sibling, so its line runs past deep");

        // Rails' rules: voice hearths only, no loops, three levels at most.
        assert!(s.check_hearth("a", "b").is_err(), "text hearth");
        assert!(s.check_hearth("hearth", "e1").is_err(), "loop");
        assert!(s.check_hearth("e2", "deep").is_err(), "a fourth level");
        assert!(s.check_hearth("e2", "e1").is_ok());

        // A broken parent from elsewhere: shown at the top instead of lost.
        s.channels.push(voice("orphan", Some("gone"), 3));
        assert!(in_category(&s, "cat").contains(&"orphan".to_string()));
    }

    fn sample() -> Structure {
        Structure {
            categories: vec![Category { id: "cat".into(), name: "Text".into(), position: 1 }],
            channels: vec![chan("general", None, 0), chan("a", Some("cat"), 0), chan("b", Some("cat"), 1), chan("rules", None, 2)],
        }
    }

    #[test]
    fn root_interleaves_channels_and_categories() {
        assert_eq!(
            root_items(&sample()),
            vec![RootItem::Channel("general".into()), RootItem::Category("cat".into()), RootItem::Channel("rules".into())]
        );
        assert_eq!(in_category(&sample(), "cat"), vec!["a", "b"]);
    }

    #[test]
    fn reorder_within_a_category() {
        let mut s = sample();
        assert!(move_channel(&mut s, "b", Some("cat"), 0));
        assert_eq!(in_category(&s, "cat"), vec!["b", "a"]);
    }

    #[test]
    fn move_between_root_and_category() {
        let mut s = sample();
        move_channel(&mut s, "general", Some("cat"), 1);
        assert_eq!(in_category(&s, "cat"), vec!["a", "general", "b"]);
        assert_eq!(root_items(&s), vec![RootItem::Category("cat".into()), RootItem::Channel("rules".into())]);

        move_channel(&mut s, "a", None, 99);
        assert_eq!(in_category(&s, "cat"), vec!["general", "b"]);
        assert_eq!(root_items(&s).last(), Some(&RootItem::Channel("a".into())));
    }

    #[test]
    fn move_a_category_and_refuse_unknowns() {
        let mut s = sample();
        assert!(move_category(&mut s, "cat", 0));
        assert_eq!(root_items(&s)[0], RootItem::Category("cat".into()));
        assert!(!move_channel(&mut s, "nope", None, 0));
        assert!(!move_channel(&mut s, "a", Some("nope"), 0));
    }
}
