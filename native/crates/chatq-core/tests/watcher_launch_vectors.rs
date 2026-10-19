//! native/vectors/watcher-launch.json: the PowerShell watcher's launch as
//! Get-ChatqWatcherLaunch builds it, [ps_watcher_command_sep] with Windows'
//! `\` on every system and [ps_watcher_args] around it.

mod common;

use chatq_core::launch::{ps_watcher_args, ps_watcher_command_sep};
use common::{Report, load};
use serde_json::json;

#[test]
fn every_launch_as_powershell_builds_it() {
    let mut r = Report::new("watcher-launch.json");
    for c in load("watcher-launch") {
        let i = &c.input;
        let s = |k: &str| {
            i[k].as_str()
                .unwrap_or_else(|| panic!("'{}': no {k}", c.name))
        };
        let cmd = ps_watcher_command_sep(
            s("script"),
            s("logDir"),
            i["claude"].as_str(),
            i["codex"].as_str(),
            '\\',
        );
        let got = json!({"exe": s("psExe"), "args": ps_watcher_args(&cmd), "command": cmd});
        for fl in c.flavours() {
            r.check(&c, fl, &got);
        }
    }
    r.finish();
}
