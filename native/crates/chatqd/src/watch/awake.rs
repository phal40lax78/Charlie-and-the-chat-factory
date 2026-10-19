//! [Set-ChatqKeepAwake](src/watcher.ps1): hold off system sleep for a wait
//! worth holding it for. The display may still turn off.

use crate::sys::Awake;

/// `None` until the first call, as `$script:ChatqAwake` starts unset, so the
/// first "off" still goes out; after that a repeat changes nothing.
#[derive(Default)]
pub struct KeepAwake {
    on: Option<bool>,
    os: Awake,
}

impl KeepAwake {
    pub fn set(&mut self, on: bool) {
        if self.on == Some(on) {
            return;
        }
        self.os.set(on);
        self.on = Some(on);
    }
}
