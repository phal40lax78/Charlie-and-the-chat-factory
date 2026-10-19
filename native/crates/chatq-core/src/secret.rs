//! Secrets as [Unprotect-ChatqSecret](src/alerts.ps1) opens them: DPAPI on
//! Windows, plain text elsewhere (SPEC 2.8). Checked live, since DPAPI keys
//! are per user: tests/vectors/live.ps1 and `chatqd vector dpapi`.

use crate::json;
use serde_json::Value;
use zeroize::Zeroizing;

/// SecureString's cap in UTF-16 units: [Unprotect-ChatqSecret](src/alerts.ps1)
/// gives $null for a longer text, as its SecureString cannot hold it.
const SECURE_STRING_MAX: usize = 65_536;

/// [Unprotect-ChatqSecret](src/alerts.ps1): the text a `{value, protected}`
/// object holds, zeroed on drop, or None where it gives $null: no object, a
/// falsy `value`, or a protected one that does not open here ([open_hex]).
/// Names match case-blind, `value` is read as `[string]` and `protected` as
/// `if` reads it, so the string "false" counts as protected.
/// Deferred: DEFERRED.md "A list where chatq writes an object"
pub fn unprotect(secret: Option<&Value>) -> Option<Zeroizing<String>> {
    // `-not $Secret` adds nothing: only an object has a value here (an
    // array's member enumeration is not followed)
    let value = json::get(secret, "value");
    if !json::truthy(value) {
        return None;
    }
    let text = Zeroizing::new(json::to_ps_string(value));
    if json::truthy(json::get(secret, "protected")) {
        open_hex(&text)
    } else {
        Some(text)
    }
}

/// The protected half of [Unprotect-ChatqSecret](src/alerts.ps1):
/// `ConvertTo-SecureString`'s hex, `ConvertFrom-SecureString`'s output, opened
/// to its UTF-16LE text, zeroed on drop. On Windows that is the DPAPI blob,
/// opened as `ProtectedData.Unprotect(blob, null, CurrentUser)`; off Windows
/// pwsh has no DPAPI and its hex is the text's own bytes. None on any failure.
pub fn open_hex(hex: &str) -> Option<Zeroizing<String>> {
    let blob = parse_hex(hex)?;
    let plain = dpapi(&blob)?;
    text_of(&plain)
}

/// `SecureStringHelper.Unprotect`'s reading: pairs of hex digits in either
/// case, each `byte.Parse(pair, AllowHexSpecifier)`, so no sign, space or
/// odd digit; empty fails, as `ConvertTo-SecureString` refuses it.
fn parse_hex(hex: &str) -> Option<Vec<u8>> {
    let b = hex.as_bytes();
    if b.is_empty() || !b.len().is_multiple_of(2) {
        return None;
    }
    let (pairs, _) = b.as_chunks::<2>();
    pairs
        .iter()
        .map(|&[hi, lo]| Some((nibble(hi)? << 4) | nibble(lo)?))
        .collect()
}

fn nibble(c: u8) -> Option<u8> {
    // a byte of a non-ASCII character is no digit here, as .NET's are ASCII
    char::from(c).to_digit(16).map(|d| d as u8)
}

#[cfg(windows)]
fn dpapi(blob: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    win::unprotect(blob)
}

/// pwsh off Windows: SecureStringHelper's UNIX branch takes the bytes as
/// they are.
#[cfg(not(windows))]
fn dpapi(blob: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    Some(Zeroizing::new(blob.to_vec()))
}

/// `SecureStringHelper.New`, then `PtrToStringBSTR`: UTF-16LE units, so an odd
/// byte count fails ("not encrypted with this key"), as does a text past
/// [SECURE_STRING_MAX]. NULs stay; a lone surrogate, which a .NET string keeps
/// and a Rust one cannot, becomes U+FFFD.
fn text_of(plain: &[u8]) -> Option<Zeroizing<String>> {
    let n = plain.len() / 2;
    if !plain.len().is_multiple_of(2) || n > SECURE_STRING_MAX {
        return None;
    }
    // reserved whole first, so no reallocation leaves a copy behind: a unit
    // makes at most 3 bytes of UTF-8
    let mut text = Zeroizing::new(String::with_capacity(n * 3));
    let (pairs, _) = plain.as_chunks::<2>();
    let units = pairs.iter().map(|&p| u16::from_le_bytes(p));
    text.extend(char::decode_utf16(units).map(|c| c.unwrap_or(char::REPLACEMENT_CHARACTER)));
    Some(text)
}

/// CryptUnprotectData, the one unsafe code in this crate outside fsx.rs.
#[cfg(windows)]
#[allow(unsafe_code)]
mod win {
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptUnprotectData,
    };
    use zeroize::{Zeroize, Zeroizing};

    /// The DPAPI step of [Unprotect-ChatqSecret](src/alerts.ps1)'s
    /// `ConvertTo-SecureString`: `ProtectedData.Unprotect(blob, null,
    /// CurrentUser)` as .NET makes the call: no UI, an empty entropy blob for
    /// null, and the result copied out, wiped and freed. A null result, which
    /// .NET turns into an OutOfMemoryException, is None as a failed call is.
    pub fn unprotect(blob: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let input = CRYPT_INTEGER_BLOB {
            cbData: u32::try_from(blob.len()).ok()?,
            pbData: blob.as_ptr().cast_mut(),
        };
        let entropy = CRYPT_INTEGER_BLOB::default();
        let mut out = CRYPT_INTEGER_BLOB::default();
        // SAFETY: input describes blob, which outlives the call and is only
        // read; entropy and out are valid blobs; the description, reserved
        // and prompt arguments are null, as allowed.
        let done = unsafe {
            CryptUnprotectData(
                &input,
                None,
                Some(&raw const entropy),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if out.pbData.is_null() {
            return None;
        }
        // SAFETY: pbData holds the cbData bytes CryptUnprotectData
        // LocalAlloc'd for its caller, copied, wiped and freed here once.
        let plain = unsafe {
            let bytes = std::slice::from_raw_parts_mut(out.pbData, out.cbData as usize);
            let copy = Zeroizing::new(bytes.to_vec());
            bytes.zeroize();
            LocalFree(Some(HLOCAL(out.pbData.cast())));
            copy
        };
        done.ok().map(|()| plain)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn utf16le(s: &str) -> Vec<u8> {
        s.encode_utf16().flat_map(u16::to_le_bytes).collect()
    }

    fn open(v: &Value) -> Option<String> {
        unprotect(Some(v)).map(|t| t.as_str().to_owned())
    }

    fn text(plain: &[u8]) -> Option<String> {
        text_of(plain).map(|t| t.as_str().to_owned())
    }

    #[test]
    fn hex_is_read_as_convertto_securestring_reads_it() {
        assert_eq!(parse_hex("00ff10Ab"), Some(vec![0x00, 0xff, 0x10, 0xab]));
        assert_eq!(parse_hex("ABCDEF"), Some(vec![0xab, 0xcd, 0xef]));
        // empty, odd, a space, a sign, a prefix, non-hex, non-ASCII digits
        for bad in [
            "",
            "abc",
            " 0",
            "0 ",
            "+1",
            "0x",
            "zz",
            "g0",
            "\u{660}\u{661}",
            "\u{ff10}0",
        ] {
            assert_eq!(parse_hex(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn plaintext_is_utf16le_within_securestring_limits() {
        for s in [
            "",
            "abc",
            "\u{d55c}\u{ae00}",
            "\u{1f600}",
            "caf\u{e9}",
            "a\0b",
            "\u{feff}x",
        ] {
            assert_eq!(text(&utf16le(s)).as_deref(), Some(s), "{s:?}");
        }
        // odd bytes: SecureStringHelper.New's "not encrypted with this key"
        assert_eq!(text(&[0x61, 0x00, 0x62]), None);
        // a lone surrogate, kept by .NET, cannot be kept here
        assert_eq!(
            text(&[0x61, 0x00, 0x00, 0xd8, 0x62, 0x00]).as_deref(),
            Some("a\u{fffd}b")
        );
        // SecureString holds 65,536 units and refuses the next
        let full = utf16le(&"a".repeat(SECURE_STRING_MAX));
        assert_eq!(text(&full).map(|t| t.len()), Some(SECURE_STRING_MAX));
        assert_eq!(text(&utf16le(&"a".repeat(SECURE_STRING_MAX + 1))), None);
    }

    #[test]
    fn plain_values_come_back_as_strings() {
        for (v, want) in [
            (json!({"value": "x y", "protected": false}), "x y"),
            (json!({"value": "k"}), "k"),
            (json!({"Value": "k", "PROTECTED": false}), "k"),
            (json!({"value": 12, "protected": 0}), "12"),
            (json!({"value": ["a", "b"], "protected": null}), "a b"),
        ] {
            assert_eq!(open(&v).as_deref(), Some(want), "{v}");
        }
    }

    #[test]
    fn nothing_to_open_is_none() {
        assert!(unprotect(None).is_none());
        for v in [
            json!(null),
            json!("abc"),
            json!(5),
            json!({}),
            json!({"value": ""}),
            json!({"value": 0, "protected": 0}),
            json!({"value": false}),
            json!({"value": [], "protected": false}),
            json!({"value": null, "protected": true}),
        ] {
            assert_eq!(open(&v), None, "{v}");
        }
    }

    #[test]
    fn a_protected_value_that_will_not_parse_is_none() {
        // a string "false" is truthy, so these take the protected path
        for v in [
            json!({"value": "zz", "protected": true}),
            json!({"value": "abc", "protected": "false"}),
            json!({"value": " 00", "protected": 1}),
            // one byte: no DPAPI blob, and no UTF-16 text either
            json!({"value": "00", "protected": true}),
        ] {
            assert_eq!(open(&v), None, "{v}");
        }
    }

    #[cfg(windows)]
    #[test]
    fn a_blob_dpapi_refuses_is_none() {
        // the DPAPI header alone, then a whole blob's worth of zeros
        assert_eq!(open_hex("01000000d08c9ddf0115d1118c7a00c04fc297eb"), None);
        assert_eq!(open_hex(&"00".repeat(230)), None);
    }
}
