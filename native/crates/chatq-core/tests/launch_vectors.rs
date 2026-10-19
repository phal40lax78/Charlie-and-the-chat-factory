//! native/vectors/launch.json, the engine decision's cases, run through
//! [decide]. tests/sections/native.ps1 runs the same cases through
//! Get-ChatqWatcherEngine, so the two launchers decide from one table.

use chatq_core::fsx::try_lock;
use chatq_core::launch::{Ask, Identity, Probes, binary_path, decide, verified};
use chatq_core::paths::Paths;
use chatq_core::time::stamp_utc;
use chrono::{Duration, Utc};
use serde_json::{Value, json};
use std::cell::Cell;
use std::fs;
use std::path::Path;

fn put(f: &Path, v: &Value) {
    fs::create_dir_all(f.parent().unwrap()).unwrap();
    fs::write(f, v.to_string()).unwrap();
}

fn pids(g: &Value, k: &str) -> Vec<u32> {
    g[k].as_array()
        .map(|a| {
            a.iter()
                .filter_map(Value::as_u64)
                .map(|n| n as u32)
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn every_case_decides_as_the_table_says() {
    let here = Path::new(env!("CARGO_MANIFEST_DIR"));
    let v: Value =
        serde_json::from_str(&fs::read_to_string(here.join("../../vectors/launch.json")).unwrap())
            .unwrap();
    let version = v["version"].as_str().unwrap();
    let cases = v["cases"].as_array().unwrap();
    assert!(cases.len() >= 30, "{} cases", cases.len());
    let mut bad = Vec::new();
    for (n, c) in cases.iter().enumerate() {
        let (g, e) = (&c["given"], &c["expect"]);
        let dir = here
            .join("../../target/test-data/core-vectors")
            .join(format!("v{}", n + 1));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("data")).unwrap();
        let p = Paths::new(dir.to_str().unwrap());
        let now = Utc::now();
        let ago = |secs: f64| stamp_utc(now - Duration::milliseconds((secs * 1000.0) as i64));

        if !g["config"].is_null() {
            put(&p.config(), &g["config"]);
        }
        let bin = if g["binary"].as_bool() == Some(true) {
            let b = dir.join("chatqd-under-test.exe");
            fs::write(&b, "not a real binary").unwrap();
            b
        } else {
            binary_path(&p, version, None)
        };
        if let Some(k) = g["verified"].as_str() {
            let id = Identity::of(&bin).unwrap();
            let size = if k == "stale" { id.size + 1 } else { id.size };
            put(
                &p.verified(),
                &json!({"passed": [{"path": id.path, "size": size, "mtime": id.mtime, "at": ago(60.0)}]}),
            );
        }
        if g["pending"].is_object() {
            let mut pj = json!({"pid": g["pending"]["pid"], "version": g["pending"]["version"]});
            if let Some(a) = g["pending"]["ageSeconds"].as_f64() {
                pj["at"] = json!(ago(a));
            }
            put(&p.pending(), &pj);
        }
        if g["last"].is_object() {
            let mut l = g["last"].clone();
            l["at"] = json!(ago(60.0));
            put(&p.last(), &l);
        }
        if g["pidFile"].as_bool() == Some(true) {
            fs::write(p.pid(), format!("{}\r\n", g["last"]["pid"])).unwrap();
        }
        let mut before = 0;
        if g["fuse"].is_object() {
            let st: Vec<Value> = g["fuse"]["strikes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| {
                    json!({"at": ago(s["hoursAgo"].as_f64().unwrap() * 3600.0), "why": s["why"], "pid": s["pid"]})
                })
                .collect();
            if g["fuse"]["version"] == version {
                before = st.len();
            }
            put(
                &p.fuse(),
                &json!({"version": g["fuse"]["version"], "strikes": st, "alerted": g["fuse"]["alerted"]}),
            );
        }

        let (live, alive) = (pids(g, "live"), pids(g, "alive"));
        let is_live = |n: u32| live.contains(&n);
        let is_alive = |n: u32| live.contains(&n) || alive.contains(&n);
        let probes = Probes {
            live_chatqd: &is_live,
            alive: &is_alive,
        };
        let ran = Cell::new(false);
        let fail = g["preflight"] == "fail";
        let mut pre = |_: &Path| {
            ran.set(true);
            if fail {
                Err("exit 2".to_string())
            } else {
                Ok(())
            }
        };
        let cfg = g["config"].clone();
        let lock = (g["lockHeld"].as_bool() == Some(true)).then(|| try_lock(&p.lock()).unwrap());
        let d = decide(
            &p,
            version,
            now,
            &probes,
            Ask {
                engine_env: g["engine"].as_str(),
                cfg: &cfg,
                native_os: true,
                bin: &bin,
                runnable: &|b: &Path| b.is_file(),
                preflight: &mut pre,
            },
        );
        drop(lock);

        let fuse: Value = fs::read_to_string(p.fuse())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        let whys: Vec<String> = if fuse["version"] == version {
            fuse["strikes"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|s| s["why"].as_str().unwrap_or("").to_string())
                        .collect()
                })
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let new: Vec<String> = whys.iter().skip(before).cloned().collect();
        let want: Vec<String> = e["strikes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap().to_string())
            .collect();
        let ver = Identity::of(&bin).is_some_and(|id| {
            let one = fs::read_to_string(p.verified())
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .and_then(|v| v["passed"].as_array().cloned())
                .unwrap_or_default()
                .iter()
                .filter(|x| {
                    x["path"]
                        .as_str()
                        .is_some_and(|s| s.eq_ignore_ascii_case(&id.path))
                })
                .count()
                == 1;
            verified(&p, &id) && one
        });
        let engine = if d.native.is_ok() { "native" } else { "ps" };
        let mut diff = Vec::new();
        if engine != e["engine"] {
            diff.push(format!("engine={engine} ({:?})", d.native));
        }
        if new != want {
            diff.push(format!("strikes={new:?}"));
        }
        if ran.get() != e["preflight"].as_bool().unwrap() {
            diff.push(format!("preflight={}", ran.get()));
        }
        if p.pending().exists() != e["pending"].as_bool().unwrap() {
            diff.push(format!("pending={}", p.pending().exists()));
        }
        if ver != e["verified"].as_bool().unwrap() {
            diff.push(format!("verified={ver}"));
        }
        if !diff.is_empty() {
            bad.push(format!(
                "'{}': {}",
                c["name"].as_str().unwrap(),
                diff.join(", ")
            ));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
