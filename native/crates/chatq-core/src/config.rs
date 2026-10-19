//! config.json, read as [Get-ChatqConfig](src/alerts.ps1) reads it: with no
//! lock - the atomic save keeps a reader from seeing half a file - and never
//! written by chatqd (SPEC 2.1).

use crate::time::Flavour;
use serde_json::{Map, Value};
use std::path::Path;

/// [Get-ChatqConfig](src/alerts.ps1): the parsed object as the PowerShell
/// `fl` reads it (pwsh 7 takes comments and trailing commas, 5.1 does not),
/// or an empty one for a missing or unreadable file. A top-level list is
/// unrolled as PS hands it on: by [Read-ChatqJson](src/queue.ps1)'s
/// `return` ([json::ps_return](crate::json::ps_return)), then once more by
/// Get-ChatqConfig's own `return $c`, so a list of one is its item.
/// Deferred: DEFERRED.md "A list where chatq writes an object"
pub fn read_config(path: &Path, fl: Flavour) -> Value {
    match crate::json::ps_return(crate::fsx::read_json(path, fl), fl) {
        Some(v) if crate::json::truthy(Some(&v)) => match v {
            Value::Array(mut a) if a.len() == 1 => a.pop().unwrap_or_default(),
            v => v,
        },
        _ => Value::Object(Map::new()),
    }
}
