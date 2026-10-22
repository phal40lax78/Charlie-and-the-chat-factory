//! The panel's version is the loader's `$script:ChatVersion`, as chatqd's
//! is (native/crates/chatqd/build.rs, SPEC 4.6): the exe ships inside the
//! VSIX under bin/<version>/, and extension/build.js stages it only when
//! `chatq-overlay --version` names the loader's version. A copy of chatqd's
//! build script, because a build script cannot use the crate beside it.

use std::path::Path;

fn loader_version(text: &str) -> Option<String> {
    const HEAD: &str = "$script:ChatVersion = '";
    text.split(['\n', '\r']).find_map(|line| {
        let mut it = line.strip_prefix(HEAD)?;
        let mut parts = Vec::new();
        for k in 0..3 {
            let n = it.bytes().take_while(u8::is_ascii_digit).count();
            if n == 0 {
                return None;
            }
            parts.push(&it[..n]);
            it = it[n..].strip_prefix(if k < 2 { '.' } else { '\'' })?;
        }
        Some(parts.join("."))
    })
}

fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let loader = Path::new(&dir).join("../../Charlie-and-the-chat-factory.ps1");
    println!("cargo:rerun-if-changed={}", loader.display());
    let bytes =
        std::fs::read(&loader).unwrap_or_else(|e| panic!("cannot read {}: {e}", loader.display()));
    // latin1, as extension/setup.js reads it
    let text: String = bytes.iter().map(|&b| b as char).collect();
    let want = loader_version(&text).expect("the loader has no $script:ChatVersion line");
    let have = std::env::var("CARGO_PKG_VERSION").unwrap();
    assert!(
        want == have,
        "native/overlay/Cargo.toml says {have} but the loader's ChatVersion is {want}: bump them together"
    );

    // as chatqd's: a release exe that needs vcruntime140.dll is the wrong
    // one to ship, so a release build without +crt-static is refused
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let features = env("CARGO_CFG_TARGET_FEATURE");
    assert!(
        env("CARGO_CFG_TARGET_ENV") != "msvc"
            || env("PROFILE") != "release"
            || features.split(',').any(|f| f == "crt-static"),
        "a release build needs +crt-static: run it inside native/, or pass \
         --config native/.cargo/config.toml"
    );
}
