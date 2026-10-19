//! native/vectors/wire.json through chatq_core::wire: each inbound label's
//! keys, b64url both ways, the confirmation code, and the sealed check up to
//! the MAC, against what PowerShell made of each (and docs/reply.html, which
//! the vectors already hold equal to it). chatqd never decrypts, so where
//! PowerShell got past the MAC (stage decrypt or ok) the check here is that
//! wire.rs did too, with the same id.

mod common;

use chatq_core::wire::{
    Sealed, b64url_decode, b64url_encode, label_keys, open_sealed, pair_code, pair_code_spaced,
};
use common::{Report, hex, load};
use serde_json::{Value, json};

fn to_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str()
        .unwrap_or_else(|| panic!("{k} is no string in {v}"))
}

/// The sealed kind a case's label names.
fn kind_of(label: &str) -> Sealed {
    match label {
        "chatq-alert:" => Sealed::Reply,
        "chatq-phone:" => Sealed::Compose,
        _ => panic!("no such label: {label}"),
    }
}

/// PowerShell got past the MAC: what chatqd calls a candidate.
fn past_the_mac(opened: &Value, id: &str) -> bool {
    matches!(opened["stage"].as_str(), Some("decrypt" | "ok")) && opened["id"] == id
}

#[test]
fn wire_vectors() {
    let mut r = Report::new("wire.json");
    for case in load("wire") {
        let i = &case.input;
        for fl in case.flavours() {
            match text(i, "op") {
                "keys" => {
                    let k = label_keys(&hex(text(i, "master")), text(i, "label"), text(i, "id"));
                    let got =
                        json!({"k": to_hex(&k.k), "enc": to_hex(&k.enc), "mac": to_hex(&k.mac)});
                    r.check(&case, fl, &got);
                }
                "code" => {
                    let d = hex(text(i, "d"));
                    let got = json!({"code": pair_code(&d), "spaced": pair_code_spaced(&d)});
                    r.check(&case, fl, &got);
                }
                "b64" => r.check(&case, fl, &json!(b64url_encode(&hex(text(i, "hex"))))),
                "unb64" => {
                    let got = b64url_decode(text(i, "text")).map(|b| to_hex(&b));
                    r.check(&case, fl, &json!(got));
                }
                "seal" => {
                    // what PowerShell sealed: its shape, and its MAC checked
                    // under the key it was sealed with
                    let want = case.expect(fl);
                    let kind = kind_of(text(i, "label"));
                    let id = text(i, "id");
                    let message = text(want, "message");
                    let p: Vec<&str> = message.split('.').collect();
                    let shape = p.len() == 5
                        && p[0] == kind.prefix()
                        && p[1] == id
                        && p[2] == b64url_encode(&hex(text(i, "iv")));
                    let master = b64url_decode(text(i, "key")).expect("the key is base64url");
                    let got = open_sealed(message, Some(&master), kind, fl);
                    if shape && past_the_mac(&want["opened"], id) && got.as_deref() == Ok(id) {
                        r.pass();
                    } else {
                        r.fail(
                            &case,
                            fl,
                            format!("shape {shape}, opened {got:?}, PowerShell {want}"),
                        );
                    }
                }
                "open" => {
                    let master = i["master"].as_str().map(hex);
                    let message = i["message"].as_str().unwrap_or("");
                    let kind = kind_of(text(i, "label"));
                    match open_sealed(message, master.as_deref(), kind, fl) {
                        Err(e) => {
                            let got = json!({"stage": e.stage, "error": e.error, "id": e.id});
                            r.check(&case, fl, &got);
                        }
                        Ok(id) => {
                            let want = case.expect(fl);
                            if past_the_mac(want, &id) {
                                r.pass();
                            } else {
                                r.fail(
                                    &case,
                                    fl,
                                    format!("past the MAC as {id:?}, PowerShell {want}"),
                                );
                            }
                        }
                    }
                }
                op => panic!("no such op: {op}"),
            }
        }
    }
    r.finish();
}
