# Vendored crates

Crates from crates.io, copied unchanged from the registry's extracted
`.crate` and then patched as below. `native/overlay/Cargo.toml` points
at each through `[patch.crates-io]`. To move to a new upstream release:
copy the new version over the folder, re-apply the patch, and bump the
version the `[dependencies]` line asks for.

## tray-icon 0.26.1

Licence: MIT OR Apache-2.0, as upstream (`LICENSE-MIT`,
`LICENSE-APACHE`).

The patch, marked `chatq patch` in the source:

- `TrayIcon::window_uid` (`src/lib.rs`), Windows only: the uID the icon
  is registered under on `window_handle()`, from the Windows
  `TrayIcon::internal_id` (`src/platform_impl/windows/mod.rs`). tray-icon
  has no balloon call; the overlay sends `NIF_INFO` itself on that
  window and uID. Without the getter the spike asked Explorer for each
  uID from 1 to 16 (`tray::find_uid` in `native/spikes/overlay`),
  DEFERRED.md "tray-icon's private balloon id".

`.cargo-ok` (a registry marker) is left out; `Cargo.lock` is ignored by
cargo for a path dependency.
