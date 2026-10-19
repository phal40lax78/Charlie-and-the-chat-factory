//! SPEC 4.6: chatqd's version is the loader's `$script:ChatVersion`, so a
//! build refuses to finish when the two differ. The parse is the one in
//! chatq-core's `launch::loader_version`, repeated here because a build
//! script cannot use the crate it builds beside.

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
    let loader = Path::new(&dir).join("../../../Charlie-and-the-chat-factory.ps1");
    println!("cargo:rerun-if-changed={}", loader.display());
    let bytes =
        std::fs::read(&loader).unwrap_or_else(|e| panic!("cannot read {}: {e}", loader.display()));
    // latin1, as extension/setup.js reads it
    let text: String = bytes.iter().map(|&b| b as char).collect();
    let want = loader_version(&text).expect("the loader has no $script:ChatVersion line");
    let have = std::env::var("CARGO_PKG_VERSION").unwrap();
    assert!(
        want == have,
        "native/Cargo.toml says {have} but the loader's ChatVersion is {want}: bump them together"
    );

    // SPEC 3.3: a release exe that needs vcruntime140.dll is the wrong one to
    // stage. Cargo reads native/.cargo/config.toml from the current folder,
    // not from --manifest-path, so a release build started elsewhere would
    // quietly miss +crt-static; it is refused instead. Debug builds (test,
    // clippy) may link either way.
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
