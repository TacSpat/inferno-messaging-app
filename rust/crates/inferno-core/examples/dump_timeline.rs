use std::collections::HashSet;

use inferno_core::channel::{ChannelKeys, Timeline};
use inferno_core::nostr::prelude::*;
use inferno_core::store::Store;

fn main() {
    let path = std::env::args().nth(1).expect("db path");
    let store = Store::open(&path).unwrap();
    for gid in store.synced_servers().unwrap().members() {
        let state = store.load_server(gid).unwrap().unwrap();
        for ch in &state.structure.channels {
            let group = ch.group_id.clone().unwrap();
            let mut events = Vec::new();
            for k in [9u16, 9005, 9006, 7] {
                events.extend(store.events_by_tag(Kind::Custom(k), 'h', &group, 5000).unwrap());
            }
            println!("{gid} #{} events={}", ch.name, events.len());
            for m in Timeline::resolve(&state, ch, &events, &ChannelKeys::default(), &HashSet::new()) {
                println!("  {} edited={:?} {:?}", &m.id.to_hex()[..8], m.edited_at, m.content);
            }
        }
    }
}
