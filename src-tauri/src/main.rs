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

const PORT: u16 = 13100;
const HEALTH_TIMEOUT: Duration = Duration::from_secs(30);
const HEALTH_INTERVAL: Duration = Duration::from_millis(500);

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

fn main() {
    let data = data_dir();
    ensure_dirs(&data);
    let secret = get_or_create_secret(&data);

    // In dev mode, beforeDevCommand already started Rails — just wait for it.
    // In release mode, spawn the Tebako sidecar binary.
    let child = if cfg!(debug_assertions) {
        println!("Dev mode: waiting for Rails server (started by beforeDevCommand)...");
        None
    } else {
        let mut child = spawn_rails_server(&data, &secret);
        pipe_output(&mut child);
        println!("Waiting for Rails server on port {}...", PORT);
        Some(child)
    };

    if !wait_for_health() {
        eprintln!("Rails server failed to start within {}s", HEALTH_TIMEOUT.as_secs());
        if let Some(mut c) = child {
            kill_server(&mut c);
        }
        std::process::exit(1);
    }
    println!("Rails server is ready!");

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(ServerProcess(Mutex::new(child)))
        .setup(|app| {
            // Server is already running — make the window visible
            if let Some(window) = app.get_webview_window("main") {
                window.show()?;
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
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
