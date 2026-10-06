use super::*;
use serde_json::json;

#[test]
fn a_stale_server_list_cannot_drop_a_newer_join() {
    let mut phone = ServerList::default();
    phone.set_at("inferno-a", true, 100);

    let mut desktop = phone.clone();
    desktop.set_at("inferno-b", true, 200);
    phone.set_at("inferno-a", false, 150);

    let mut merged = desktop.clone();
    merged.merge(&phone);
    let mut other_way = phone.clone();
    other_way.merge(&desktop);

    assert_eq!(merged, other_way, "merge order doesn't matter");
    assert_eq!(merged.members().collect::<Vec<_>>(), vec!["inferno-b"]);
}

#[test]
fn rejoining_after_leaving_wins_by_time() {
    let mut list = ServerList::default();
    list.set_at("inferno-a", true, 100);
    list.set_at("inferno-a", false, 200);
    list.set_at("inferno-a", true, 150);
    assert_eq!(list.members().count(), 0, "an older join learned elsewhere can't undo a newer leave");
    list.set_at("inferno-a", true, 300);
    assert_eq!(list.members().collect::<Vec<_>>(), vec!["inferno-a"]);
}

#[test]
fn a_local_leave_in_the_same_second_as_the_join_still_lands() {
    let mut list = ServerList::default();
    list.set("inferno-a", true, 100);
    list.set("inferno-a", false, 100);
    assert_eq!(list.members().count(), 0);
    assert_eq!(list.state["inferno-a"].at, 101);
}

#[test]
fn reads_flutters_server_list_and_writes_one_it_can_read() {
    let flutter = json!({ "servers": ["inferno-a", "inferno-b"] });
    let mut list = ServerList::from_json(&flutter, 500);
    assert_eq!(list.members().count(), 2);

    list.set_at("inferno-a", false, 600);
    let wire = list.to_json();
    assert_eq!(wire["servers"], json!(["inferno-b"]));
    assert_eq!(ServerList::from_json(&wire, 700), list, "our own form round-trips");
}

#[test]
fn config_merge_keeps_newest_settings_and_latest_reads() {
    let mut a = ConfigDoc::default();
    a.settings.insert("theme".into(), Setting { value: json!("frostfire"), at: 100 });
    a.read_markers.insert("chan-1".into(), 500);

    let mut b = ConfigDoc::default();
    b.settings.insert("theme".into(), Setting { value: json!("boron"), at: 200 });
    b.settings.insert("ptt".into(), Setting { value: json!(true), at: 50 });
    b.read_markers.insert("chan-1".into(), 300);
    b.read_markers.insert("dm-xyz".into(), 400);

    a.merge(&b);
    assert_eq!(a.settings["theme"].value, json!("boron"));
    assert_eq!(a.settings["ptt"].value, json!(true));
    assert_eq!(a.read_markers["chan-1"], 500, "read markers never move back");
    assert_eq!(a.read_markers["dm-xyz"], 400);
}

#[test]
fn config_is_encrypted_to_ourselves_only() {
    let me = Keys::generate();
    let event = seal(&me, CONFIG_D, &json!({ "secret": 1 }), 1_000).unwrap();
    assert_eq!(event.kind, Kind::Custom(kinds::APP_CONFIG));
    assert_eq!(event.tags.identifier().as_deref(), Some(CONFIG_D));
    assert!(!event.content.contains("secret"));
    assert_eq!(open(&me, &event), Some(json!({ "secret": 1 })));
    assert_eq!(open(&Keys::generate(), &event), None);
}

/// Two devices on one identity, one relay: what each adds survives the
/// other's publish, and a fresh third device sees everything.
#[tokio::test]
async fn two_devices_converge_through_a_relay() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let me = Keys::generate();

    let device = || async {
        let pool = RelayPool::new(me.clone());
        pool.add_relays([url.clone()]).await.unwrap();
        pool.connect().await;
        (pool, Store::open_in_memory().unwrap())
    };
    let (pool_a, store_a) = device().await;
    let (pool_b, store_b) = device().await;

    store_a.set_server_membership("inferno-a", true).unwrap();
    store_a.mark_read("chan-1", 500).unwrap();
    ConfigSync { keys: &me, pool: &pool_a, store: &store_a }.push().await.unwrap();

    // B never pulled, adds its own server and theme, then pushes. A naive
    // whole-document publish would erase A's server here.
    store_b.set_server_membership("inferno-b", true).unwrap();
    store_b.set_synced_setting("theme", json!("plasma")).unwrap();
    // Same second as A's publish: push must still date its copy later.
    ConfigSync { keys: &me, pool: &pool_b, store: &store_b }.push().await.unwrap();

    let (pool_c, store_c) = device().await;
    ConfigSync { keys: &me, pool: &pool_c, store: &store_c }.pull().await.unwrap();
    let mut servers: Vec<_> = store_c.synced_servers().unwrap().members().map(str::to_owned).collect();
    servers.sort();
    assert_eq!(servers, vec!["inferno-a", "inferno-b"]);
    assert_eq!(store_c.synced_setting("theme").unwrap(), Some(json!("plasma")));
    assert_eq!(store_c.last_read("chan-1").unwrap(), Some(500));
}
