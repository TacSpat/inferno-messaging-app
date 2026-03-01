// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use rand::Rng;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::Manager;
use tauri::webview::WebviewWindowBuilder;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_updater::UpdaterExt;

const PORT: u16 = 13100;
const HEALTH_TIMEOUT: Duration = Duration::from_secs(30);
const HEALTH_INTERVAL: Duration = Duration::from_millis(500);

const SPLASH_HTML: &str = include_str!("splash.html");

struct ServerProcess(Mutex<Option<Child>>);

fn data_dir() -> PathBuf {
    dirs::data_dir()
        .expect("could not determine platform data directory")
        .join("inferno")
}

fn ensure_dirs(base: &PathBuf) {
    for sub in &["storage/db", "tmp/pids", "tmp/cache", "log"] {
        fs::create_dir_all(base.join(sub)).ok();
    }
}

fn get_or_create_secret(base: &PathBuf) -> String {
    let path = base.join("secret_key_base");
    if let Ok(secret) = fs::read_to_string(&path) {
        let secret = secret.trim().to_string();
        if !secret.is_empty() {
            return secret;
        }
    }
    let secret: String = rand::thread_rng()
        .sample_iter(&rand::distributions::Alphanumeric)
        .take(128)
        .map(char::from)
        .collect();
    fs::write(&path, &secret).expect("failed to write secret_key_base");
    secret
}

fn spawn_rails_server(data: &PathBuf, secret: &str) -> Child {
    let mut cmd = if !cfg!(debug_assertions) {
        // Release mode: use the Tebako sidecar binary
        let binary = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .unwrap_or_default()
            .join("inferno-server");
        Command::new(binary)
    } else {
        // Dev mode: run Rails directly via bundle exec
        let mut c = Command::new("bundle");
        c.args(["exec", "rails", "server", "-p", &PORT.to_string(), "-b", "127.0.0.1"]);
        c
    };

    cmd.env("INFERNO_DATA_DIR", data.to_str().unwrap())
        .env("RAILS_ENV", "production")
        .env("PORT", PORT.to_string())
        .env("SECRET_KEY_BASE", secret)
        .env("SOLID_QUEUE_IN_PUMA", "true")
        .env("RAILS_LOG_TO_STDOUT", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // In dev mode, set working directory to the Rails project root
    if cfg!(debug_assertions) {
        if let Ok(manifest) = std::env::var("CARGO_MANIFEST_DIR") {
            let rails_root = PathBuf::from(&manifest).parent().unwrap().to_path_buf();
            cmd.current_dir(&rails_root);
        }
    }

    let child = cmd.spawn().expect("failed to start Rails server");
    child
}

fn pipe_output(child: &mut Child) {
    // Pipe stdout in a background thread
    if let Some(stdout) = child.stdout.take() {
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                println!("[rails] {}", line);
            }
        });
    }
    // Pipe stderr in a background thread
    if let Some(stderr) = child.stderr.take() {
        std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                eprintln!("[rails] {}", line);
            }
        });
    }
}

fn wait_for_health() -> bool {
    let url = format!("http://127.0.0.1:{}/up", PORT);
    let start = Instant::now();
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();

    while start.elapsed() < HEALTH_TIMEOUT {
        if let Ok(resp) = client.get(&url).send() {
            if resp.status().is_success() {
                return true;
            }
        }
        std::thread::sleep(HEALTH_INTERVAL);
    }
    false
}

fn kill_server(child: &mut Child) {
    #[cfg(unix)]
    {
        // Send SIGTERM first for graceful shutdown
        unsafe {
            libc::kill(child.id() as i32, libc::SIGTERM);
        }
        // Wait up to 5 seconds for graceful exit
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(5) {
            if let Ok(Some(_)) = child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    // Force kill if still alive
    let _ = child.kill();
    let _ = child.wait();
}

async fn check_for_updates(app: tauri::AppHandle) {
    let updater = match app.updater() {
        Ok(u) => u,
        Err(e) => {
            eprintln!("[updater] failed to create updater: {e}");
            return;
        }
    };

    let update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => {
            println!("[updater] no update available");
            return;
        }
        Err(e) => {
            eprintln!("[updater] check failed: {e}");
            return;
        }
    };

    println!(
        "[updater] update available: {} -> {}",
        update.current_version, update.version
    );

    // Ask user before downloading
    let (tx, rx) = std::sync::mpsc::channel();
    let version = update.version.clone();
    app.dialog()
        .message(format!(
            "A new version ({}) is available. Update and restart now?",
            version
        ))
        .title("Update Available")
        .buttons(tauri_plugin_dialog::MessageDialogButtons::OkCancelCustom(
            "Update".into(),
            "Later".into(),
        ))
        .show(move |confirmed| {
            let _ = tx.send(confirmed);
        });

    let confirmed = rx.recv().unwrap_or(false);
    if !confirmed {
        println!("[updater] user declined update");
        return;
    }

    if let Err(e) = update.download_and_install(|_, _| {}, || {}).await {
        eprintln!("[updater] install failed: {e}");
        return;
    }

    println!("[updater] update installed, restarting...");
    app.restart();
}

fn main() {
    let data = data_dir();
    ensure_dirs(&data);
    let secret = get_or_create_secret(&data);

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .register_uri_scheme_protocol("splash", |_ctx, _request| {
            let body = SPLASH_HTML.as_bytes().to_vec();
            tauri::http::Response::builder()
                .status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(body)
                .unwrap()
        })
        .manage(ServerProcess(Mutex::new(None)))
        .setup(move |app| {
            // Create the main window programmatically so we can enable
            // WebRTC and MediaStream on WebKitGTK (not enabled by default).
            let main_win = WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::External("about:blank".parse().unwrap()),
            )
            .title("Inferno")
            .inner_size(1280.0, 800.0)
            .min_inner_size(940.0, 560.0)
            .visible(false)
            .user_agent("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
            .build()?;

            // Enable WebRTC and MediaStream on Linux (WebKitGTK).
            // NOTE: RTCPeerConnection requires WebKitGTK compiled with
            // -DENABLE_WEB_RTC=ON. Ubuntu's stock package lacks this.
            #[cfg(target_os = "linux")]
            {
                use webkit2gtk::{SettingsExt, WebViewExt};
                use webkit2gtk::glib::ObjectExt;
                main_win.with_webview(|webview| {
                    let wv = webview.inner();
                    if let Some(settings) = WebViewExt::settings(&wv) {
                        SettingsExt::set_enable_media_stream(&settings, true);
                        SettingsExt::set_enable_webrtc(&settings, true);
                        SettingsExt::set_enable_media(&settings, true);
                        SettingsExt::set_enable_media_capabilities(&settings, true);
                    }
                    // Auto-allow media/WebRTC permission requests (mic, camera)
                    // so the user isn't silently denied by WebKitGTK defaults.
                    wv.connect("permission-request", false, |values| {
                        if let Ok(req) = values[1].get::<webkit2gtk::UserMediaPermissionRequest>() {
                            webkit2gtk::PermissionRequestExt::allow(&req);
                        }
                        Some(true.into())
                    });
                })?;
            }

            // Create the splash window
            let splash_win = WebviewWindowBuilder::new(
                app,
                "splash",
                tauri::WebviewUrl::CustomProtocol("splash://localhost".parse().unwrap()),
            )
            .title("Inferno")
            .inner_size(400.0, 300.0)
            .resizable(false)
            .decorations(false)
            .center()
            .visible(true)
            .build()?;

            let app_handle = app.handle().clone();
            let data = data.clone();
            let secret = secret.clone();

            std::thread::spawn(move || {
                // In release mode, spawn the Rails sidecar
                // In dev mode, beforeDevCommand already started it
                if !cfg!(debug_assertions) {
                    let _ = splash_win.eval("updateStatus('Starting server...')");
                    let mut child = spawn_rails_server(&data, &secret);
                    pipe_output(&mut child);
                    println!("Spawned Rails server on port {}", PORT);

                    // Store child in managed state
                    if let Some(state) = app_handle.try_state::<ServerProcess>() {
                        if let Ok(mut guard) = state.0.lock() {
                            *guard = Some(child);
                        }
                    }
                } else {
                    println!("Dev mode: waiting for Rails server (started by beforeDevCommand)...");
                }

                let _ = splash_win.eval("updateStatus('Waiting for server...')");
                println!("Waiting for Rails server on port {}...", PORT);

                if !wait_for_health() {
                    eprintln!(
                        "Rails server failed to start within {}s",
                        HEALTH_TIMEOUT.as_secs()
                    );
                    let _ = splash_win.eval("updateStatus('Server failed to start')");
                    std::thread::sleep(Duration::from_secs(2));
                    // Kill server if we spawned one
                    if let Some(state) = app_handle.try_state::<ServerProcess>() {
                        if let Ok(mut guard) = state.0.lock() {
                            if let Some(ref mut child) = *guard {
                                kill_server(child);
                            }
                            *guard = None;
                        }
                    }
                    std::process::exit(1);
                }

                println!("Rails server is ready!");
                let _ = splash_win.eval("updateStatus('Ready!')");
                std::thread::sleep(Duration::from_millis(500));

                // Navigate main window to Rails and show it
                let url = format!("http://127.0.0.1:{}", PORT);
                if let Some(main_win) = app_handle.get_webview_window("main") {
                    let _ = main_win.navigate(url.parse().unwrap());
                    // Brief delay to let the page load before showing
                    std::thread::sleep(Duration::from_millis(300));
                    let _ = main_win.show();
                }

                // Close the splash window
                let _ = splash_win.close();

                // Check for updates after the app is fully loaded
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    check_for_updates(handle).await;
                });
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
                // Only shut down the server when the main window is destroyed
                if window.label() != "main" {
                    return;
                }
                let app = window.app_handle();
                if let Some(state) = app.try_state::<ServerProcess>() {
                    if let Ok(mut guard) = state.0.lock() {
                        if let Some(ref mut child) = *guard {
                            println!("Shutting down Rails server...");
                            kill_server(child);
                        }
                        *guard = None;
                    }
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
