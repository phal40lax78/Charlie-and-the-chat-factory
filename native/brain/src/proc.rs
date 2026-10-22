//! The real llama-server child. Job-object / parent-pid cleanup is the
//! overlay's and `main`'s job (SPEC.md section 1); a child of this process
//! inherits the overlay's job object on Windows with no extra call.

use crate::llm::{self, Fail, Reply};
use crate::supervisor::Llm;
use serde_json::Value;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long a fresh llama-server gets to answer `GET /health` with 200.
pub const START_WAIT: Duration = Duration::from_secs(30);

struct Running {
    child: Child,
    base: String,
}

#[derive(Default)]
pub struct ProcLlama {
    run: Mutex<Option<Running>>,
}

impl ProcLlama {
    pub fn new() -> Self {
        Self::default()
    }

    fn base(&self) -> Option<String> {
        self.run.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|r| r.base.clone())
    }
}

fn free_port() -> Result<u16, String> {
    let l = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    Ok(l.local_addr().map_err(|e| e.to_string())?.port())
}

impl Llm for ProcLlama {
    fn start(&self, exe: &Path, args: &[String]) -> Result<(), String> {
        self.stop();
        let port = free_port()?;
        let mut cmd = Command::new(exe);
        cmd.args(["--host", "127.0.0.1", "--port", &port.to_string()])
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(dir) = exe.parent() {
            cmd.current_dir(dir); // its dlls sit beside it
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = cmd.spawn().map_err(|e| format!("spawn {}: {e}", exe.display()))?;
        let base = format!("http://127.0.0.1:{port}");
        let deadline = Instant::now() + START_WAIT;
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!("llama-server exited early: {status}"));
            }
            if llm::health(&base, Duration::from_millis(500)) {
                break;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("llama-server not healthy within {} s", START_WAIT.as_secs()));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        *self.run.lock().unwrap_or_else(|e| e.into_inner()) = Some(Running { child, base });
        Ok(())
    }

    fn alive(&self) -> bool {
        let mut g = self.run.lock().unwrap_or_else(|e| e.into_inner());
        g.as_mut().is_some_and(|r| matches!(r.child.try_wait(), Ok(None)))
    }

    fn stop(&self) {
        let taken = self.run.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(mut r) = taken {
            let _ = r.child.kill();
            let _ = r.child.wait();
        }
    }

    fn ask(&self, system: &str, user: &str, schema: &Value, timeout: Duration) -> Reply {
        match self.base() {
            Some(base) => llm::ask(&base, system, user, schema, timeout),
            None => Reply { status: None, input_tokens: 0, output_tokens: 0, result: Err(Fail::Other("llama-server is not running".into())) },
        }
    }
}

impl Drop for ProcLlama {
    fn drop(&mut self) {
        self.stop();
    }
}
