//! Dev tool: publishes NIP-94 GIF events to a relay, for testing the
//! picker's Nostr GIFs locally. Use a local relay only:
//!
//!     cargo run -p inferno-core --example seed_gifs -- ws://127.0.0.1:7777 \
//!         http://127.0.0.1:7790/g/cat.gif "a cat" http://127.0.0.1:7790/g/wave.gif "waving hello"

use nostr_sdk::prelude::*;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (relay, pairs) = args.split_first().ok_or("usage: seed_gifs RELAY URL TEXT [URL TEXT ...]")?;
    if !relay.starts_with("ws://127.0.0.1") && !relay.starts_with("ws://localhost") {
        return Err("seed_gifs only talks to a local relay".into());
    }
    let keys = Keys::generate();
    let client = Client::new();
    client.add_relay(relay).await?;
    client.connect().await;
    for pair in pairs.chunks(2) {
        let [url, text] = pair else { break };
        let event = EventBuilder::new(Kind::FileMetadata, text)
            .tags([Tag::parse(["url", url])?, Tag::parse(["m", "image/gif"])?, Tag::parse(["alt", text])?]);
        let out = client.send_event(&event.finalize(&keys)?).await?;
        println!("{url}: {:?}", out.success);
    }
    Ok(())
}
