//! The tool root R and its data folder D, and every file in them M0 touches
//! (SPEC 2.4, 4.5). Each name is the one the PS symbol in its comment joins.

use std::path::PathBuf;

/// `Join-Path`'s separator: what the PS side writes into its own paths, and
/// so into the launch command chatqd must reproduce (SPEC 2.7).
#[cfg(windows)]
pub const SEP: char = '\\';
#[cfg(not(windows))]
pub const SEP: char = '/';

/// The newline `Set-Content` and `Environment.NewLine` write.
#[cfg(windows)]
pub const NEWLINE: &str = "\r\n";
#[cfg(not(windows))]
pub const NEWLINE: &str = "\n";

/// The loader's file name, beside src/ in R.
pub const LOADER: &str = "Charlie-and-the-chat-factory.ps1";

/// `Join-Path $a $b`: one separator between them, none added after one
/// already there (a drive root, `D:\`).
pub fn join(a: &str, b: &str) -> String {
    if a.ends_with(['\\', '/']) {
        format!("{a}{b}")
    } else {
        format!("{a}{SEP}{b}")
    }
}

#[derive(Clone, Debug)]
pub struct Paths {
    /// `$script:ChatRoot`, exactly as the launcher passed it.
    pub root: String,
    /// `$script:ChatqData`
    pub data: String,
    /// `$script:ChatqLogDir`
    pub logs: String,
    /// `$script:ChatqQueueDir`
    pub queue: String,
    /// D/native (SPEC 4.5)
    pub native: String,
}

impl Paths {
    pub fn new(root: &str) -> Paths {
        let data = join(root, "data");
        Paths {
            root: root.to_string(),
            logs: join(&data, "logs"),
            queue: join(&data, "queue"),
            native: join(&data, "native"),
            data,
        }
    }

    fn d(&self, name: &str) -> PathBuf {
        PathBuf::from(join(&self.data, name))
    }

    /// `$script:ChatqLockPath`
    pub fn lock(&self) -> PathBuf {
        self.d("watcher.lock")
    }
    /// `$script:ChatqPidPath`
    pub fn pid(&self) -> PathBuf {
        self.d("watcher.pid")
    }
    /// `$script:ChatqStopPath`
    pub fn stop(&self) -> PathBuf {
        self.d("stop")
    }
    /// `$script:ChatqRestartPath`
    pub fn restart(&self) -> PathBuf {
        self.d("restart")
    }
    /// `$script:ChatqWakePath`
    pub fn wake(&self) -> PathBuf {
        self.d("wake")
    }
    /// `$script:ChatqStatePath`
    pub fn state(&self) -> PathBuf {
        self.d("state.json")
    }
    /// `$script:ChatqBoardPath`
    pub fn board(&self) -> PathBuf {
        self.d("queue.md")
    }
    /// `$script:ChatqConfigPath`
    pub fn config(&self) -> PathBuf {
        self.d("config.json")
    }
    /// `$script:ChatqReplyPath` ([src/phone.ps1](src/phone.ps1))
    pub fn replies(&self) -> PathBuf {
        self.d("replies.json")
    }
    /// `$script:ChatqHeldPath` ([src/phone-extras.ps1](src/phone-extras.ps1))
    pub fn held(&self) -> PathBuf {
        self.d("held.jsonl")
    }
    /// `$script:ChatqAutoPath` ([src/auto-continue.ps1](src/auto-continue.ps1))
    pub fn auto_state(&self) -> PathBuf {
        self.d("auto-continue.json")
    }
    /// `$script:ChatqPermitDir` ([src/permit.ps1](src/permit.ps1))
    pub fn permit_dir(&self) -> PathBuf {
        self.d("permit")
    }
    /// `$script:ChatqAskDir` ([src/ask.ps1](src/ask.ps1))
    pub fn ask_dir(&self) -> PathBuf {
        self.d("ask")
    }
    pub fn queue_dir(&self) -> PathBuf {
        PathBuf::from(&self.queue)
    }
    pub fn log_dir(&self) -> PathBuf {
        PathBuf::from(&self.logs)
    }
    pub fn native_dir(&self) -> PathBuf {
        PathBuf::from(&self.native)
    }
    pub fn native_file(&self, name: &str) -> PathBuf {
        PathBuf::from(join(&self.native, name))
    }
    /// D/native/pending.json: the last native launch not yet acked
    pub fn pending(&self) -> PathBuf {
        self.native_file("pending.json")
    }
    /// D/native/last.json: the lock holder's record
    pub fn last(&self) -> PathBuf {
        self.native_file("last.json")
    }
    /// D/native/verified.json: preflight passes
    pub fn verified(&self) -> PathBuf {
        self.native_file("verified.json")
    }
    /// D/native/fuse.json
    pub fn fuse(&self) -> PathBuf {
        self.native_file("fuse.json")
    }
    /// `D/native/step-<n>.in.json`: what helper step `n` is to do (SPEC 3.6)
    pub fn step_in(&self, n: u32) -> PathBuf {
        self.native_file(&format!("step-{n}.in.json"))
    }
    /// `D/native/step-<n>.out.json`: what helper step `n` answered
    pub fn step_out(&self, n: u32) -> PathBuf {
        self.native_file(&format!("step-{n}.out.json"))
    }
    /// D/native/handoff.json: W and its caches for the PS watcher (SPEC 4.4)
    pub fn handoff(&self) -> PathBuf {
        self.native_file("handoff.json")
    }
    /// R/src/native-step.ps1, the helper steps' entry (SPEC 3.6)
    pub fn native_step(&self) -> PathBuf {
        PathBuf::from(join(&join(&self.root, "src"), "native-step.ps1"))
    }
    /// R/Charlie-and-the-chat-factory.ps1, where `chatqd version` reads the
    /// loader's version
    pub fn loader(&self) -> PathBuf {
        PathBuf::from(join(&self.root, LOADER))
    }
    /// `$script:ChatqReplyLockPath` ([src/phone.ps1](src/phone.ps1))
    pub fn replies_lock(&self) -> PathBuf {
        self.d("replies.lock")
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn joins_as_join_path() {
        assert_eq!(join(r"D:\tool", "data"), r"D:\tool\data");
        assert_eq!(join(r"D:\", "data"), r"D:\data");
        let p = Paths::new(r"C:\Users\me\chatq");
        assert_eq!(p.logs, r"C:\Users\me\chatq\data\logs");
        assert_eq!(
            p.step_in(3),
            PathBuf::from(r"C:\Users\me\chatq\data\native\step-3.in.json")
        );
        assert_eq!(
            p.native_step(),
            PathBuf::from(r"C:\Users\me\chatq\src\native-step.ps1")
        );
    }
}
