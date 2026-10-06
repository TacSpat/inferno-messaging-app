//! `cargo run -p inferno-devrelay [PORT]` — an in-memory relay on
//! 127.0.0.1 (default port 7777) so local runs and UI tests never touch the
//! public relays. Everything is lost when it stops.

use std::net::{IpAddr, Ipv4Addr};

use nostr_sdk::prelude::*;

#[tokio::main]
async fn main() {
    let port: u16 = std::env::args().nth(1).and_then(|p| p.parse().ok()).unwrap_or(7777);
    let relay = LocalRelay::builder()
        .addr(IpAddr::V4(Ipv4Addr::LOCALHOST))
        .port(port)
        // Local testing bursts a lot; don't rate-limit ourselves.
        .messages_per_minute(100_000)
        .queries_per_minute(100_000)
        .build();
    relay.run().await.expect("start relay");
    println!("inferno-devrelay listening on {}", relay.url().await);
    tokio::signal::ctrl_c().await.ok();
}
