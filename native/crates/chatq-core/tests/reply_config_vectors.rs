//! native/vectors/reply-config.json (tests/vectors/reply-config.ps1): the
//! reply block through [chatq_core::replyconfig] as the poll reads it, from
//! a config.json in a data/ of the case's own, at the case's clock, in a
//! zone of a fixed offset. A `{seal: <text>}` secret is sealed here before
//! the file is written - by DPAPI for this user on Windows, as
//! Protect-ChatqSecret seals one there - so no blob is in the vector.

mod common;

use chatq_core::config::read_config;
use chatq_core::paths::Paths;
use chatq_core::replyconfig;
use chatq_core::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
use chrono::FixedOffset;
use common::{Case, Report};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::Path;

fn zone_of(input: &Value) -> Zone {
    let m = input["utcOffsetMinutes"]
        .as_i64()
        .expect("a case has utcOffsetMinutes");
    Zone::Fixed(FixedOffset::east_opt(m as i32 * 60).expect("an offset"))
}

fn at(v: &Value, fl: Flavour, zone: Zone) -> Instant {
    let s = v.as_str().unwrap_or_else(|| panic!("a stamp, not {v}"));
    parse_stamp_in(s, fl, zone).unwrap_or_else(|| panic!("a stamp, not {s}"))
}

/// Lowercase hex, as ConvertFrom-SecureString and ConvertTo-NvHex write it.
fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `ProtectedData.Protect(bytes, null, CurrentUser)`, as
/// ConvertFrom-SecureString seals a SecureString's UTF-16LE text.
#[cfg(windows)]
#[allow(unsafe_code)]
fn protect(bytes: &[u8]) -> Vec<u8> {
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData,
    };
    use windows::core::PCWSTR;
    let input = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(bytes.len()).expect("a small text"),
        pbData: bytes.as_ptr().cast_mut(),
    };
    let mut out = CRYPT_INTEGER_BLOB::default();
    // SAFETY: input describes bytes, which outlive the call and are only
    // read; out is a valid blob; the other arguments are null, as allowed.
    unsafe {
        CryptProtectData(
            &input,
            PCWSTR::null(),
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        )
    }
    .expect("DPAPI seals for this user");
    // SAFETY: pbData holds the cbData bytes CryptProtectData LocalAlloc'd
    // for its caller, copied and freed here once.
    unsafe {
        let blob = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        LocalFree(Some(HLOCAL(out.pbData.cast())));
        blob
    }
}

/// Off Windows there is no DPAPI: the protected hex is the text's own bytes,
/// as chatq_core::secret reads it there.
#[cfg(not(windows))]
fn protect(bytes: &[u8]) -> Vec<u8> {
    bytes.to_vec()
}

/// The config with every `{seal: <text>}` sealed as Protect-ChatqSecret
/// seals it: `{value: <hex>, protected: true}`.
fn sealed(v: &Value) -> Value {
    match v {
        Value::Object(m) if m.len() == 1 && m.contains_key("seal") => {
            let text = m["seal"].as_str().expect("a seal is a text");
            let utf16: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
            json!({"value": to_hex(&protect(&utf16)), "protected": true})
        }
        Value::Object(m) => Value::Object(
            m.iter()
                .map(|(k, x)| (k.clone(), sealed(x)))
                .collect::<Map<_, _>>(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(sealed).collect()),
        x => x.clone(),
    }
}

/// The case's own data/, empty, as tests/vectors/common.ps1's Enter-NvData
/// names it.
fn data_of(name: &str) -> Paths {
    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/test-data/reply_config_vectors")
        .join(safe);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("data")).expect("a scratch data/");
    Paths::new(root.to_str().expect("a UTF-8 path"))
}

fn answer(case: &Case, fl: Flavour) -> Value {
    let input = &case.input;
    let zone = zone_of(input);
    let now = at(&input["now"], fl, zone);
    let p = data_of(&case.name);
    let text = match (input.get("config"), input.get("configText")) {
        (Some(c), _) => sealed(c).to_string(),
        (None, Some(t)) => t.as_str().expect("configText is a text").to_string(),
        (None, None) => panic!("a case has config or configText"),
    };
    fs::write(p.config(), text).expect("config.json");
    let cfg = read_config(&p.config(), fl);
    let rc = replyconfig::read_in(&cfg, now, fl, zone);
    let pair_key = replyconfig::pair_key(&cfg, rc.pair_id.as_deref());
    // the triage reads the same config
    let t = rc.triage();
    assert_eq!(
        t.pair_key,
        pair_key.as_ref().is_some_and(|k| !k.is_empty()),
        "{}: the triage's pair_key",
        case.name
    );
    assert_eq!(t.pair_id, rc.pair_id, "{}: the triage's pair_id", case.name);
    json!({
        "on": rc.on,
        "wanted": rc.wanted,
        "paired": rc.paired,
        "topic": rc.topic.as_ref().map(|s| s.as_str()),
        "key": rc.key.as_ref().map(|s| s.as_str()),
        "master": rc.master.as_ref().map(|m| to_hex(m)),
        "server": rc.server,
        "pairId": rc.pair_id,
        "pairUntil": rc.pair_until.map(stamp_utc),
        "hours": rc.hours,
        "pairKey": pair_key.as_ref().map(|k| k.as_str()),
    })
}

#[test]
fn reply_config() {
    let mut r = Report::new("reply-config");
    for case in common::load("reply-config") {
        for fl in case.flavours() {
            let got = answer(&case, fl);
            r.check(&case, fl, &got);
        }
    }
    r.finish();
}
