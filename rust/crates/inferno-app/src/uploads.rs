//! Blossom uploads from the app: the backend signs (it holds the keys), the
//! bytes go out through Makepad's HTTP, one server after another until one
//! takes them.

use std::collections::HashMap;

use makepad_widgets::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Avatar,
    Banner,
    ServerIcon,
    ServerBanner,
    /// Uploaded as picked, not cropped.
    Emoji,
    Sticker,
}

impl Purpose {
    /// The editor shape for it.
    pub fn target(self) -> crate::crop::Target {
        use crate::crop::Target;
        match self {
            Purpose::Avatar => Target::Avatar,
            Purpose::Banner | Purpose::ServerBanner => Target::Banner,
            Purpose::ServerIcon | Purpose::Emoji | Purpose::Sticker => Target::Icon,
        }
    }

    /// For the server's pictures (notes go to the overview page).
    pub fn server(self) -> bool {
        matches!(self, Purpose::ServerIcon | Purpose::ServerBanner)
    }

    /// Custom emoji and stickers go up as they are.
    pub fn custom(self) -> bool {
        matches!(self, Purpose::Emoji | Purpose::Sticker)
    }
}

struct Job {
    purpose: Purpose,
    bytes: Vec<u8>,
    mime: &'static str,
    sha256: String,
    header: String,
    servers: Vec<String>,
    next: usize,
}

#[derive(Default)]
pub struct Uploads {
    next_id: u64,
    jobs: HashMap<u64, Job>,
    in_flight: HashMap<LiveId, u64>,
}

/// How an upload ended.
pub enum Done {
    Uploaded { purpose: Purpose, url: String },
    Failed { purpose: Purpose, error: String },
}

impl Uploads {
    /// Queues `bytes`; returns (id, sha256) for the backend to sign.
    pub fn start(&mut self, purpose: Purpose, bytes: Vec<u8>, mime: &'static str) -> (u64, String) {
        self.next_id += 1;
        let sha256 = inferno_core::blossom::sha256_hex(&bytes);
        let job = Job { purpose, bytes, mime, sha256: sha256.clone(), header: String::new(), servers: vec![], next: 0 };
        self.jobs.insert(self.next_id, job);
        (self.next_id, sha256)
    }

    /// The backend signed it: send to the first server.
    pub fn authorized(&mut self, cx: &mut Cx, id: u64, header: String, servers: Vec<String>) -> Option<Done> {
        let job = self.jobs.get_mut(&id)?;
        job.header = header;
        job.servers = servers;
        self.send(cx, id)
    }

    fn send(&mut self, cx: &mut Cx, id: u64) -> Option<Done> {
        let job = self.jobs.get_mut(&id)?;
        let Some(server) = job.servers.get(job.next).cloned() else {
            let job = self.jobs.remove(&id)?;
            return Some(Done::Failed { purpose: job.purpose, error: "No upload server took the file.".into() });
        };
        let mut req = HttpRequest::new(format!("{}/upload", server.trim_end_matches('/')), HttpMethod::PUT);
        req.set_header("Authorization".into(), job.header.clone());
        req.set_header("Content-Type".into(), job.mime.into());
        req.set_header("X-SHA-256".into(), job.sha256.clone());
        req.set_body(job.bytes.clone());
        let request_id = LiveId::unique();
        self.in_flight.insert(request_id, id);
        cx.http_request(request_id, req);
        None
    }

    /// Responses to our requests; anything else is left alone.
    pub fn handle_event(&mut self, cx: &mut Cx, event: &Event) -> Vec<Done> {
        let Event::NetworkResponses(responses) = event else { return vec![] };
        let mut done = Vec::new();
        for r in responses.iter() {
            let (request_id, ok_body) = match r {
                NetworkResponse::HttpResponse { request_id, response } => (
                    *request_id,
                    (200..300).contains(&response.status_code).then(|| response.body.as_deref().map(<[u8]>::to_vec).unwrap_or_default()),
                ),
                NetworkResponse::HttpError { request_id, .. } => (*request_id, None),
                _ => continue,
            };
            let Some(id) = self.in_flight.remove(&request_id) else { continue };
            let Some(job) = self.jobs.get_mut(&id) else { continue };
            match ok_body {
                Some(body) => {
                    let server = job.servers[job.next].clone();
                    let url = inferno_core::blossom::uploaded_url(&server, &job.sha256, &body);
                    let job = self.jobs.remove(&id).expect("present");
                    done.push(Done::Uploaded { purpose: job.purpose, url });
                }
                None => {
                    // That server said no (or wasn't there): the next one.
                    job.next += 1;
                    done.extend(self.send(cx, id));
                }
            }
        }
        done
    }
}
