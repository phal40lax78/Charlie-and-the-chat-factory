//! config.json's reply block as [Get-ChatqReplyConfig](src/phone.ps1) opens
//! it for the poll, and the pairing's private key as
//! [Get-ChatqPairKey](src/phone.ps1) opens it (SPEC 3.7). Only what the poll
//! and its triage read: the page, the phone's name, `PairedAt`, the mode cap
//! and the PC-to-phone settings stay PowerShell's. Vector:
//! native/vectors/reply-config.json.
//!
//! The topic, the phone's key and the pairing's key are secrets: held in
//! [Zeroizing], never logged, and left out of every `Debug`.

use crate::gates::unroll;
use crate::json;
use crate::replystate;
use crate::secret;
use crate::time::{Flavour, Instant, Zone, date_of_in};
use crate::wire::{self, TriageConfig};
use serde_json::Value;
use std::fmt;
use zeroize::Zeroizing;

/// `$script:ChatqReplyServer`: the ntfy server when reply.server is unset.
pub const DEFAULT_SERVER: &str = "https://ntfy.sh";

/// [Get-ChatqReplyConfig](src/phone.ps1)'s answer, as far as the poll goes.
pub struct ReplyConfig {
    /// `On`, worth polling: [ReplyConfig::wanted], a topic that opens to
    /// text, and [ReplyConfig::paired] or a pairing waiting for the phone
    pub on: bool,
    /// `Wanted`: `reply.on -eq $true`
    pub wanted: bool,
    /// `Paired`: the phone's key reads back as 32 bytes. A key DPAPI cannot
    /// open is not paired
    pub paired: bool,
    /// `Topic`, opened by [secret::unprotect]; None where
    /// [Unprotect-ChatqSecret](src/alerts.ps1) gives $null
    pub topic: Option<Zeroizing<String>>,
    /// `Key`, the phone's key D in base64url, opened as the topic is
    pub key: Option<Zeroizing<String>>,
    /// `Master`: the key decoded by [wire::b64url_decode], whatever its
    /// length
    pub master: Option<Zeroizing<Vec<u8>>>,
    /// `Server`: reply.server with every final `/` trimmed, else
    /// [DEFAULT_SERVER]
    pub server: String,
    /// `server` is [DEFAULT_SERVER] because config names none: the one a
    /// test's `$script:ChatqReplyServer` stands in for
    pub server_default: bool,
    /// `PairId`: the pairing waiting for the phone, until it expires
    pub pair_id: Option<String>,
    /// `PairUntil`: when that pairing expires
    pub pair_until: Option<Instant>,
    /// `Hours`, [replystate::reply_hours]; None where that is
    /// [replystate::Error::PsOnly]
    pub hours: Option<f64>,
    /// [Get-ChatqPairKey](src/phone.ps1) gives a text that is not empty
    pub pair_key: bool,
}

impl fmt::Debug for ReplyConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReplyConfig")
            .field("on", &self.on)
            .field("wanted", &self.wanted)
            .field("paired", &self.paired)
            .field("topic", &redacted(self.topic.is_some()))
            .field("key", &redacted(self.key.is_some()))
            .field("master", &redacted(self.master.is_some()))
            .field("server", &self.server)
            .field("server_default", &self.server_default)
            .field("pair_id", &self.pair_id)
            .field("pair_until", &self.pair_until)
            .field("hours", &self.hours)
            .field("pair_key", &self.pair_key)
            .finish()
    }
}

/// What a `Debug` shows of a secret: whether there is one.
pub(crate) fn redacted(set: bool) -> &'static str {
    if set { "<redacted>" } else { "None" }
}

/// `$Cfg.PSObject.Properties['reply'] -and $Cfg.reply`, then that value as
/// an `if` hands it on: a list of one is its item.
fn reply_block(cfg: &Value) -> Option<&Value> {
    unroll(json::get(Some(cfg), "reply").filter(|v| json::truthy(Some(v))))
}

/// [read_in] in this PC's zone.
pub fn read(cfg: &Value, now: Instant, fl: Flavour) -> ReplyConfig {
    read_in(cfg, now, fl, Zone::Local)
}

/// [Get-ChatqReplyConfig](src/phone.ps1) of `cfg`, config.json as
/// [config::read_config](crate::config::read_config) reads it, at `now`,
/// with a zoneless pairing expiry read in `zone` as pwsh 7 reads it. A field
/// counts only when it is there and not null (`$has`). Never fails: a
/// secret that will not open is None, as PowerShell's $null.
pub fn read_in(cfg: &Value, now: Instant, fl: Flavour, zone: Zone) -> ReplyConfig {
    let rp = reply_block(cfg);
    let has = |n: &str| json::get(rp, n).filter(|v| !v.is_null());
    let topic = has("topic").and_then(|v| secret::unprotect(Some(v)));
    let key = has("key").and_then(|v| secret::unprotect(Some(v)));
    // `if ($key)`: an empty text decodes to nothing
    let master = key
        .as_deref()
        .filter(|k| !k.is_empty())
        .and_then(|k| wire::b64url_decode(k))
        .map(Zeroizing::new);
    let (server, server_default) = match has("server") {
        Some(v) if json::truthy(Some(v)) => (
            json::to_ps_string(Some(v))
                .trim_end_matches('/')
                .to_string(),
            false,
        ),
        _ => (DEFAULT_SERVER.to_string(), true),
    };
    let wanted = has("on").is_some_and(|v| json::eq_true(Some(v)));
    let paired = master.as_ref().is_some_and(|m| m.len() == 32);
    let pairing = has("pairing");
    let id = json::get(pairing, "id").filter(|v| json::truthy(Some(v)));
    let (pair_id, pair_until) = match id {
        Some(id) => match date_of_in(json::get(pairing, "expires"), fl, zone) {
            Some(x) if x > now => (Some(json::to_ps_string(Some(id))), Some(x)),
            _ => (None, None),
        },
        None => (None, None),
    };
    let on =
        wanted && topic.as_ref().is_some_and(|t| !t.is_empty()) && (paired || pair_until.is_some());
    let pair_key = pair_key(cfg, pair_id.as_deref()).is_some_and(|k| !k.is_empty());
    ReplyConfig {
        on,
        wanted,
        paired,
        topic,
        key,
        master,
        server,
        server_default,
        pair_id,
        pair_until,
        hours: replystate::reply_hours(cfg).ok(),
        pair_key,
    }
}

/// [Get-ChatqPairKey](src/phone.ps1): the open pairing's private key (the
/// JSON its RSA answer is opened with), or None: no pairing open
/// (`pair_id`, [ReplyConfig::pair_id]), the pairing in `cfg` no longer the
/// one with that id - compared case-sensitively - or a key DPAPI cannot
/// open here.
pub fn pair_key(cfg: &Value, pair_id: Option<&str>) -> Option<Zeroizing<String>> {
    let pair_id = pair_id.filter(|s| !s.is_empty())?;
    let rp = unroll(json::get(Some(cfg), "reply"));
    let pairing = json::get(rp, "pairing");
    let key = json::get(pairing, "key");
    let same = json::to_ps_string(json::get(pairing, "id")) == pair_id;
    if !(json::truthy(rp) && json::truthy(pairing) && same && json::truthy(key)) {
        return None;
    }
    secret::unprotect(key)
}

impl ReplyConfig {
    /// The [TriageConfig] [wire::triage] and [wire::poll_batch] read: an
    /// unopened topic is empty, as [ReplyConfig::on] keeps such a config
    /// from polling.
    pub fn triage(&self) -> TriageConfig {
        TriageConfig {
            topic: self.topic.clone().unwrap_or_default(),
            master: self.master.clone(),
            pair_id: self.pair_id.clone(),
            pair_key: self.pair_key,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn now() -> Instant {
        crate::time::parse_stamp("2026-10-15T09:00:00.0000000Z", Flavour::Desktop).unwrap()
    }

    fn cfg_with(pair_key: Value) -> Value {
        json!({"reply": {
            "on": true,
            "topic": {"value": "secret-topic-x", "protected": false},
            "key": {"value": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "protected": false},
            "pairing": {"id": "abcdefghij", "expires": "2026-10-15T09:05:00.0000000Z", "key": pair_key},
        }})
    }

    #[test]
    fn debug_shows_no_secret() {
        let rc = read(
            &cfg_with(json!({"value": "secret-pair-key", "protected": false})),
            now(),
            Flavour::Desktop,
        );
        assert!(rc.on && rc.paired && rc.pair_key);
        for shown in [format!("{rc:?}"), format!("{:?}", rc.triage())] {
            for secret in ["secret-topic-x", "AAECAwQF", "secret-pair-key", "[0, 1, 2"] {
                assert!(!shown.contains(secret), "{secret} in {shown}");
            }
            assert!(shown.contains("<redacted>"), "{shown}");
        }
    }

    #[test]
    fn the_triage_config_is_the_reply_config() {
        let rc = read(&cfg_with(json!(null)), now(), Flavour::Desktop);
        let t = rc.triage();
        assert_eq!(t.topic.as_str(), "secret-topic-x");
        assert_eq!(t.master.as_deref().map(Vec::len), Some(32));
        assert_eq!(t.pair_id.as_deref(), Some("abcdefghij"));
        assert!(!t.pair_key);
        let none = read(&json!({}), now(), Flavour::Desktop).triage();
        assert!(none.topic.is_empty() && none.master.is_none() && none.pair_id.is_none());
    }

    #[test]
    fn the_pairing_key_follows_its_id_exactly() {
        let cfg = cfg_with(json!({"value": "k", "protected": false}));
        let key = |id| pair_key(&cfg, id).map(|k| k.as_str().to_owned());
        assert_eq!(key(Some("abcdefghij")).as_deref(), Some("k"));
        for other in [None, Some(""), Some("ABCDEFGHIJ"), Some("abcdefghi")] {
            assert_eq!(key(other), None, "{other:?}");
        }
    }
}
