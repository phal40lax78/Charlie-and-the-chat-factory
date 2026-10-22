//! `chatq-brain [--data <dir>] [--mock] [--port <n>]`
//!
//! Binds 127.0.0.1, writes `port` and `token` into the data dir, serves the
//! contract until killed. `--data` defaults to the folder the exe sits in
//! (`data/brain/`). `--mock` has no network: regex tasks run the regex layer,
//! model tasks answer from `vectors/mock-answers.json`. Otherwise
//! `brain.json` `"backend"` picks gemini (the default), anthropic or local;
//! an unknown one stops the start with a message.

use chatq_brain::config::{self, Layout};
use chatq_brain::engine::Engine;
use chatq_brain::server;
use std::path::PathBuf;

struct Args {
    data: PathBuf,
    mock: bool,
    port: u16,
}

fn parse_args() -> Result<Args, String> {
    let mut data = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."));
    let (mut mock, mut port) = (false, 0u16);
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--mock" => mock = true,
            "--data" => data = PathBuf::from(it.next().ok_or("--data needs a path")?),
            "--port" => port = it.next().ok_or("--port needs a number")?.parse().map_err(|_| "bad --port")?,
            other => return Err(format!("unknown argument {other}\nusage: chatq-brain [--data <dir>] [--mock] [--port <n>]")),
        }
    }
    Ok(Args { data, mock, port })
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    if let Err(e) = run(args) {
        eprintln!("chatq-brain: {e}");
        std::process::exit(1);
    }
}

fn run(args: Args) -> Result<(), String> {
    std::fs::create_dir_all(&args.data).map_err(|e| e.to_string())?;
    let layout = Layout::new(&args.data);
    let engine = if args.mock {
        Engine::mock(layout.clone())
    } else {
        Engine::from_config(layout.clone()).inspect_err(|e| config::diag(&layout, &format!("not started: {e}")))?
    };
    let token = config::new_token()?;
    let handle = server::start(engine.clone(), token.clone(), args.port)?;
    config::write_atomic(&layout.port_file(), handle.port.to_string().as_bytes()).map_err(|e| e.to_string())?;
    config::write_atomic(&layout.token_file(), token.as_bytes()).map_err(|e| e.to_string())?;
    config::diag(&layout, &format!("up on 127.0.0.1:{} ({})", handle.port, engine.backend()));
    println!("chatq-brain listening on 127.0.0.1:{}", handle.port);

    // Clean exit: stop a local llama-server, remove port and token.
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    let tx2 = tx.clone();
    ctrlc::set_handler(move || {
        let _ = tx2.send(());
    })
    .map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        // macOS has no job objects: leave when the overlay is gone.
        let parent = std::os::unix::process::parent_id();
        std::thread::spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_secs(5));
            if std::os::unix::process::parent_id() != parent {
                let _ = tx.send(());
                return;
            }
        });
    }
    #[cfg(not(unix))]
    drop(tx);
    // Once a second: the local backend's idle kill and crash check.
    while let Err(std::sync::mpsc::RecvTimeoutError::Timeout) = rx.recv_timeout(std::time::Duration::from_secs(1)) {
        engine.tick();
    }
    engine.shutdown();
    handle.shutdown();
    let _ = std::fs::remove_file(layout.port_file());
    let _ = std::fs::remove_file(layout.token_file());
    config::diag(&layout, "down");
    Ok(())
}
