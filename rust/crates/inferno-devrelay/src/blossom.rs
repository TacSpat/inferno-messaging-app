//! A minimal in-memory Blossom server (BUD-01/02) for local testing:
//! `PUT /upload` with a kind 24242 authorization whose `x` tag matches the
//! body's sha256, and `GET /<sha256>[.ext]`. HTTP/1.1, one request per
//! connection.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use base64::Engine;
use nostr_sdk::prelude::*;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Uploads above this are refused (test images are small).
const MAX_BLOB: usize = 32 * 1024 * 1024;

type Blobs = Arc<Mutex<HashMap<String, (String, Vec<u8>)>>>;

pub async fn serve(port: u16) {
    let listener = TcpListener::bind(("127.0.0.1", port)).await.expect("bind blossom port");
    let blobs: Blobs = Arc::default();
    loop {
        let Ok((stream, _)) = listener.accept().await else { continue };
        let blobs = blobs.clone();
        tokio::spawn(async move {
            let _ = handle(stream, blobs, port).await;
        });
    }
}

async fn handle(mut stream: TcpStream, blobs: Blobs, port: u16) -> std::io::Result<()> {
    // Read the head.
    let mut buf = Vec::new();
    let head_end = loop {
        let mut chunk = [0u8; 4096];
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > 64 * 1024 {
            return respond(&mut stream, 431, "text/plain", b"head too large").await;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.lines();
    let mut first = lines.next().unwrap_or_default().split_whitespace();
    let (method, path) = (first.next().unwrap_or_default().to_owned(), first.next().unwrap_or_default().to_owned());
    let headers: HashMap<String, String> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_owned()))
        .collect();

    match (method.as_str(), path.as_str()) {
        ("PUT", "/upload") => {
            let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
            if len > MAX_BLOB {
                return respond(&mut stream, 413, "text/plain", b"too large").await;
            }
            let mut body = buf[head_end..].to_vec();
            while body.len() < len {
                let mut chunk = vec![0u8; (len - body.len()).min(64 * 1024)];
                let n = stream.read(&mut chunk).await?;
                if n == 0 {
                    break;
                }
                body.extend_from_slice(&chunk[..n]);
            }
            body.truncate(len);
            let sha: String = Sha256::digest(&body).iter().map(|b| format!("{b:02x}")).collect();
            if let Err(why) = authorized(headers.get("authorization").map(String::as_str), &sha) {
                return respond(&mut stream, 401, "text/plain", why.as_bytes()).await;
            }
            let mime = headers.get("content-type").cloned().unwrap_or_else(|| "application/octet-stream".into());
            let size = body.len();
            blobs.lock().unwrap().insert(sha.clone(), (mime.clone(), body));
            let url = format!("http://127.0.0.1:{port}/{sha}");
            let json = format!(r#"{{"url":"{url}","sha256":"{sha}","size":{size},"type":"{mime}","uploaded":{}}}"#, Timestamp::now().as_secs());
            respond(&mut stream, 200, "application/json", json.as_bytes()).await
        }
        ("GET" | "HEAD", p) => {
            let sha = p.trim_start_matches('/').split('.').next().unwrap_or_default().to_owned();
            let blob = blobs.lock().unwrap().get(&sha).cloned();
            match blob {
                Some((mime, bytes)) if method == "GET" => respond(&mut stream, 200, &mime, &bytes).await,
                Some((mime, _)) => respond(&mut stream, 200, &mime, b"").await,
                None => respond(&mut stream, 404, "text/plain", b"not found").await,
            }
        }
        _ => respond(&mut stream, 405, "text/plain", b"method not allowed").await,
    }
}

/// BUD-01: a signed kind 24242, `t=upload`, `x` = the body's hash, not expired.
fn authorized(header: Option<&str>, sha: &str) -> Result<(), String> {
    let b64 = header.and_then(|h| h.strip_prefix("Nostr ")).ok_or("missing Nostr authorization")?;
    let json = base64::engine::general_purpose::STANDARD.decode(b64.trim()).map_err(|e| e.to_string())?;
    let event = Event::from_json(json).map_err(|e| e.to_string())?;
    event.verify().map_err(|e| e.to_string())?;
    if event.kind != Kind::BlossomAuth {
        return Err("not a blossom authorization".into());
    }
    let tag = |k: &str| event.tags.iter().find(|t| t.as_slice().first().map(String::as_str) == Some(k)).and_then(|t| t.as_slice().get(1).cloned());
    if tag("t").as_deref() != Some("upload") || tag("x").as_deref() != Some(sha) {
        return Err("authorization is for another upload".into());
    }
    let expired = tag("expiration").and_then(|e| e.parse::<u64>().ok()).is_some_and(|e| e < Timestamp::now().as_secs());
    if expired {
        return Err("authorization expired".into());
    }
    Ok(())
}

async fn respond(stream: &mut TcpStream, status: u16, mime: &str, body: &[u8]) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        _ => "Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {mime}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.shutdown().await
}
