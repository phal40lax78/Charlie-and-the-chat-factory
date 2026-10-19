//! native/vectors/argline.json: [arg_line_for] and [cmd_arg_refusal] on
//! tests/vectors/argline.ps1's corpus, each argument for an exe and a `.cmd`,
//! and [cmd_title] in the arguments Invoke-ChatqRun builds for a fresh chat.

mod common;

use chatq_core::argline::{arg_line_for, cmd_arg_refusal, cmd_title, is_cmd_exe};
use common::{Report, load};
use serde_json::{Value, json};

/// The fresh chat the generator queues: Claude, no mode, no permit.
const SESSION: &str = "00000000-0000-4000-8000-000000000001";

/// Text as the file writes it: a string, or its UTF-16 code units when it
/// holds a lone surrogate.
fn text(u: &[u16]) -> Value {
    match String::from_utf16(u) {
        Ok(s) => Value::String(s),
        Err(_) => json!(u),
    }
}

fn str_of<'a>(v: &'a Value, case: &str, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("'{case}': no {key}"))
}

#[test]
fn every_line_and_title_as_powershell_builds_it() {
    let mut r = Report::new("argline.json");
    for c in load("argline") {
        let exe = str_of(&c.input, &c.name, "exe");
        for fl in c.flavours() {
            let got = match str_of(&c.input, &c.name, "kind") {
                "line" => {
                    let args: Vec<String> = c.input["args"]
                        .as_array()
                        .unwrap_or_else(|| panic!("'{}': no args", c.name))
                        .iter()
                        .map(|a| a.as_str().expect("an argument").to_string())
                        .collect();
                    json!({
                        "refusal": cmd_arg_refusal(exe, &args).map(|u| text(&u)),
                        "line": arg_line_for(&args, exe, fl).ok(),
                    })
                }
                "title" => {
                    let title = str_of(&c.input, &c.name, "title");
                    let name = if is_cmd_exe(exe) {
                        cmd_title(title)
                    } else {
                        title.to_string()
                    };
                    let args: Vec<String> = [
                        "-p",
                        "--session-id",
                        SESSION,
                        "--name",
                        &name,
                        "--output-format",
                        "stream-json",
                        "--verbose",
                        "--permission-mode",
                        "default",
                        "--permission-prompts",
                        "none",
                    ]
                    .iter()
                    .map(|s| s.to_string())
                    .collect();
                    json!({"name": name, "line": arg_line_for(&args, exe, fl).ok(), "args": args})
                }
                k => panic!("'{}': kind {k}", c.name),
            };
            r.check(&c, fl, &got);
        }
    }
    r.finish();
}
