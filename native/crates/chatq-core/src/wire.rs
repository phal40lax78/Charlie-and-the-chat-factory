//! Inbound phone messages as [Test-ChatqReplyMessage](src/phone.ps1) triages
//! them, up to and including the MAC check, and the confirmation code
//! (SPEC 2.8, 3.7). chatqd never decrypts. Vectors:
//! native/vectors/wire.json, native/vectors/reply-triage.json.
//!
//! Then [Invoke-ChatqReplyPoll](src/phone.ps1) over a fetched batch that
//! holds nothing but junk: what it logs, the throttles and caches it keeps,
//! and what it saves (SPEC 3.7 step 4). A batch holding a candidate goes
//! whole to a `reply` step and is not touched here.

mod collation;

use crate::culture::Culture;
use crate::json;
use crate::time::{Flavour, Instant, Zone};
use base64::Engine as _;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use chrono::TimeDelta;
use hmac::{Hmac, KeyInit, Mac};
use serde_json::Value;
use sha2::Sha256;
use std::collections::BTreeMap;
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

/// base64url as [ConvertFrom-ChatqB64Url](src/phone.ps1) reads it once it is
/// padded: .NET's FromBase64String lets non-zero trailing bits by.
const B64URL: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_encode_padding(false)
        .with_decode_padding_mode(DecodePaddingMode::Indifferent)
        .with_decode_allow_trailing_bits(true),
);

/// [ConvertTo-ChatqB64Url](src/phone.ps1): base64url with the `=` trimmed.
pub fn b64url_encode(bytes: &[u8]) -> String {
    B64URL.encode(bytes)
}

/// [ConvertFrom-ChatqB64Url](src/phone.ps1): the bytes, or None for text
/// that is not base64url - a character outside `[A-Za-z0-9_-]`, padding
/// included, or a length of 4n+1. Its regex's `$` also lets one final line
/// feed through, but no text ending in one decodes, so it is refused here.
pub fn b64url_decode(text: &str) -> Option<Vec<u8>> {
    let alphabet = |b: u8| b.is_ascii_alphanumeric() || b == b'-' || b == b'_';
    if !text.bytes().all(alphabet) || text.len() % 4 == 1 {
        return None;
    }
    B64URL.decode(text).ok()
}

/// [Get-ChatqHmac](src/phone.ps1): HMAC-SHA256.
pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut m = Hmac::<Sha256>::new_from_slice(key).expect("HMAC takes a key of any length");
    m.update(data);
    m.finalize().into_bytes().into()
}

/// One message's keys, as [Get-ChatqLabelKeys](src/phone-down.ps1) makes
/// them (and [Get-ChatqReplyKeys](src/phone.ps1) for a reply's label).
/// Zeroed on drop.
pub struct LabelKeys {
    /// `.K`: `HMAC(D, UTF8(label + id))`
    pub k: [u8; 32],
    /// `.Enc`: `HMAC(k, "enc")`, the AES key, which chatqd never uses
    pub enc: [u8; 32],
    /// `.Mac`: `HMAC(k, "mac")`
    pub mac: [u8; 32],
}

impl Drop for LabelKeys {
    fn drop(&mut self) {
        self.k.zeroize();
        self.enc.zeroize();
        self.mac.zeroize();
    }
}

/// [Get-ChatqLabelKeys](src/phone-down.ps1): `k = HMAC(D, UTF8(label + id))`
/// from the phone's key D, then `enc = HMAC(k, "enc")`, `mac = HMAC(k, "mac")`.
pub fn label_keys(master: &[u8], label: &str, id: &str) -> LabelKeys {
    let mut keys = LabelKeys {
        k: hmac_sha256(master, format!("{label}{id}").as_bytes()),
        enc: [0; 32],
        mac: [0; 32],
    };
    keys.enc = hmac_sha256(&keys.k, b"enc");
    keys.mac = hmac_sha256(&keys.k, b"mac");
    keys
}

/// [Test-ChatqSameBytes](src/phone.ps1): equal, in constant time.
pub fn same_bytes(a: &[u8], b: &[u8]) -> bool {
    bool::from(a.ct_eq(b))
}

/// [Get-ChatqPairCode](src/phone.ps1): the confirmation code of the phone's
/// key D, the first 4 bytes of `HMAC(D, "chatq-confirm")` big-endian mod
/// 1000000, as six digits.
pub fn pair_code(d: &[u8]) -> String {
    let h = hmac_sha256(d, b"chatq-confirm");
    format!(
        "{:06}",
        u32::from_be_bytes([h[0], h[1], h[2], h[3]]) % 1_000_000
    )
}

/// [Get-ChatqPairCode](src/phone.ps1) `-Spaced`, as shown: "123 456".
pub fn pair_code_spaced(d: &[u8]) -> String {
    let s = pair_code(d);
    format!("{} {}", &s[..3], &s[3..])
}

/// The sealed messages that reach the reply topic, as
/// [Open-ChatqSealed](src/phone-down.ps1)'s inbound callers open them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sealed {
    /// `chatq1`, a reply to an alert: [Unprotect-ChatqReplyMessage](src/phone.ps1)
    Reply,
    /// `chatq3c`, the phone about no alert: [Unprotect-ChatqComposeMessage](src/phone-down.ps1)
    Compose,
}

impl Sealed {
    /// [Open-ChatqSealed](src/phone-down.ps1)'s `-Prefix`, the first part.
    pub fn prefix(self) -> &'static str {
        match self {
            Sealed::Reply => "chatq1",
            Sealed::Compose => "chatq3c",
        }
    }

    /// [Open-ChatqSealed](src/phone-down.ps1)'s `-Label`, the keys' label.
    pub fn label(self) -> &'static str {
        match self {
            Sealed::Reply => "chatq-alert:",
            Sealed::Compose => "chatq-phone:",
        }
    }

    /// [Open-ChatqSealed](src/phone-down.ps1)'s `-NotText`: the error of a
    /// message of another shape.
    pub fn not_text(self) -> &'static str {
        match self {
            Sealed::Reply => "not a chatq reply",
            Sealed::Compose => "not a chatq message from the phone",
        }
    }
}

/// How far [Open-ChatqSealed](src/phone-down.ps1) got with a message it
/// refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    /// `$R.Stage`: format, or mac once every other check passed
    pub stage: &'static str,
    /// `$R.Error`
    pub error: &'static str,
    /// `$R.Aid` or `$R.Cid`: set when the stage is mac
    pub id: Option<String>,
}

/// [Open-ChatqSealed](src/phone-down.ps1) up to its MAC check: the
/// message's id when the MAC checks out under `master`, the phone's key D -
/// the stage decrypt or ok of [Unprotect-ChatqReplyMessage](src/phone.ps1)
/// and [Unprotect-ChatqComposeMessage](src/phone-down.ps1), a candidate -
/// else how far it got. The prefix is compared as `-cne` compares it, by
/// the collation of `fl`'s PowerShell, not ordinally.
pub fn open_sealed(
    message: &str,
    master: Option<&[u8]>,
    kind: Sealed,
    fl: Flavour,
) -> Result<String, Refusal> {
    let format = |error| Refusal {
        stage: "format",
        error,
        id: None,
    };
    let p: Vec<&str> = message.trim().split('.').collect();
    if p.len() != 5 || !prefix_matches(p[0], kind.prefix(), fl) || !is_sealed_id(p[1]) {
        return Err(format(kind.not_text()));
    }
    let (Some(iv), Some(ct), Some(mac)) = (
        b64url_decode(p[2]),
        b64url_decode(p[3]),
        b64url_decode(p[4]),
    ) else {
        return Err(format("bad encoding"));
    };
    if iv.len() != 16 || ct.is_empty() || !ct.len().is_multiple_of(16) || mac.len() != 32 {
        return Err(format("bad encoding"));
    }
    let Some(master) = master.filter(|m| m.len() == 32) else {
        return Err(format("no phone paired"));
    };
    let keys = label_keys(master, kind.label(), p[1]);
    if !same_bytes(&hmac_sha256(&keys.mac, p[..4].join(".").as_bytes()), &mac) {
        return Err(Refusal {
            stage: "mac",
            error: "the MAC does not match",
            id: Some(p[1].to_string()),
        });
    }
    Ok(p[1].to_string())
}

/// `$part -cne $prefix` false: the same once the characters `fl`'s
/// collation gives no weight are dropped, where on pwsh 7 another script's
/// digit stands for the prefix's own (wire/collation.rs).
fn prefix_matches(part: &str, prefix: &str, fl: Flavour) -> bool {
    let mut want = prefix.chars();
    for c in part.chars().filter(|&c| !collation::ignorable(c, fl)) {
        match want.next() {
            Some(w) if c == w || collation::same_digit(c, w, fl) => {}
            _ => return false,
        }
    }
    want.next().is_none()
}

/// `-cmatch '^[a-z2-7]{10}$'`. .NET's `$` matches before a final line feed
/// too, so one is let by, and stays in the id, its keys and the log.
fn is_sealed_id(s: &str) -> bool {
    let s = s.strip_suffix('\n').unwrap_or(s);
    s.len() == 10 && s.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7'))
}

/// `-cmatch '^[A-Za-z0-9]{1,40}$'`, ntfy's message id: a final line feed is
/// let by, as above.
fn is_ntfy_id(s: &str) -> bool {
    let s = s.strip_suffix('\n').unwrap_or(s);
    (1..=40).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// What [Test-ChatqReplyMessage](src/phone.ps1) reads of
/// [Get-ChatqReplyConfig](src/phone.ps1)'s answer, and whether
/// [Get-ChatqPairKey](src/phone.ps1) opened the pairing's key. Built by
/// [ReplyConfig::triage](crate::replyconfig::ReplyConfig::triage).
pub struct TriageConfig {
    /// `Topic`: every Handled tag starts with it. Zeroed on drop
    pub topic: Zeroizing<String>,
    /// `Master`, the phone's key D as read, whatever its length; only 32
    /// bytes is paired. Zeroed on drop.
    pub master: Option<Zeroizing<Vec<u8>>>,
    /// `PairId`: the pairing waiting for the phone, set only until it
    /// expires
    pub pair_id: Option<String>,
    /// [Get-ChatqPairKey](src/phone.ps1) gave the pairing's private key, a
    /// text that is not empty
    pub pair_key: bool,
}

/// The topic and the phone's key left out.
impl std::fmt::Debug for TriageConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use crate::replyconfig::redacted;
        f.debug_struct("TriageConfig")
            .field("topic", &redacted(!self.topic.is_empty()))
            .field("master", &redacted(self.master.is_some()))
            .field("pair_id", &self.pair_id)
            .field("pair_key", &self.pair_key)
            .finish()
    }
}

/// What a message is once it passed triage: which step goes on with it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// `chatq1`, for [Receive-ChatqReply](src/phone.ps1)
    Reply,
    /// `chatq3c`, for [Receive-ChatqCompose](src/phone-board.ps1)
    Compose,
    /// `chatq2p`, for [Receive-ChatqPairing](src/phone.ps1)
    Pair,
}

/// [Test-ChatqReplyMessage](src/phone.ps1)'s answer, as far as chatqd goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// What anyone could have posted, refused at `stage` (format, mac or
    /// pairing) with `error`: PowerShell's own texts
    Junk {
        stage: &'static str,
        error: &'static str,
    },
    /// A message only the phone could have sent
    Candidate(Kind),
}

/// [Test-ChatqReplyMessage](src/phone.ps1), decrypting nothing. A message
/// that starts `chatq3c.` once white space is trimmed from its front is
/// opened as a compose message
/// ([Test-ChatqComposeMessage](src/phone-board.ps1)), one that starts
/// `chatq2p.` is a pairing answer, anything else is opened as a reply.
/// Either sealed kind past its MAC is a candidate, as it is to PowerShell
/// whatever its decryption makes of it. A pairing answer past
/// [Unprotect-ChatqPairMessage](src/phone.ps1)'s checks before RSA is a
/// candidate, whatever RSA would make of it.
pub fn triage(message: &str, rc: &TriageConfig, fl: Flavour) -> Verdict {
    let head = message.trim_start();
    let master = rc.master.as_deref().map(Vec::as_slice);
    let sealed = |kind, as_kind| match open_sealed(message, master, kind, fl) {
        Ok(_) => Verdict::Candidate(as_kind),
        Err(r) => Verdict::Junk {
            stage: r.stage,
            error: r.error,
        },
    };
    if head.starts_with("chatq3c.") {
        sealed(Sealed::Compose, Kind::Compose)
    } else if head.starts_with("chatq2p.") {
        pairing(message, rc)
    } else {
        sealed(Sealed::Reply, Kind::Reply)
    }
}

/// [Test-ChatqReplyMessage](src/phone.ps1)'s `chatq2p.` branch, through
/// [Unprotect-ChatqPairMessage](src/phone.ps1)'s checks before RSA. The id
/// is compared with `PairId` exactly, where PowerShell's `-cne` collates:
/// both are ten of `[a-z2-7]` unless config.json was edited by hand.
fn pairing(message: &str, rc: &TriageConfig) -> Verdict {
    let junk = |error| Verdict::Junk {
        stage: "pairing",
        error,
    };
    let pair_id = rc.pair_id.as_deref().filter(|s| !s.is_empty());
    if pair_id.is_some() && !rc.pair_key {
        return junk("the pairing key cannot be read here");
    }
    let p: Vec<&str> = message.trim().split('.').collect();
    if p.len() != 3 || p[0] != "chatq2p" || !is_sealed_id(p[1]) {
        return junk("not a pairing message");
    }
    if pair_id != Some(p[1]) {
        return junk("for no pairing in progress");
    }
    match b64url_decode(p[2]) {
        Some(ct) if (64..=1024).contains(&ct.len()) => Verdict::Candidate(Kind::Pair),
        _ => junk("bad encoding"),
    }
}

/// [Write-ChatqReplyJunk](src/phone.ps1)'s record of one stage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct JunkEntry {
    /// `At`: when the stage's line was last logged
    pub at: Instant,
    /// `Count`: how many went unlogged since
    pub count: u64,
}

/// [Invoke-ChatqReplyPoll](src/phone.ps1)'s `$script:ChatqReplyHandled`:
/// the `topic|id` tags of the messages this process has recorded. A
/// PowerShell hashtable, so case-blind: a tag is found whatever the case of
/// its id, and keeps the spelling it was first added with. (Ids are ASCII; a
/// Turkish culture's I, which PowerShell would not match with i, is not
/// followed.)
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Handled(BTreeMap<String, String>);

impl Handled {
    /// `.ContainsKey($tag)`
    pub fn contains(&self, tag: &str) -> bool {
        self.0.contains_key(&tag.to_ascii_lowercase())
    }

    /// `$script:ChatqReplyHandled[$tag] = $true`
    pub fn add(&mut self, tag: &str) {
        self.0
            .entry(tag.to_ascii_lowercase())
            .or_insert_with(|| tag.to_string());
    }

    /// Every tag as first added, in ordinal order.
    pub fn tags(&self) -> Vec<&str> {
        let mut t: Vec<&str> = self.0.values().map(String::as_str).collect();
        t.sort_unstable();
        t
    }
}

/// [Invoke-ChatqReplyPoll](src/phone.ps1)'s `$script:` caches, kept for the
/// process's life.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PollCaches {
    /// `ChatqReplyPolledAt`: the caller sets it as it fetches
    pub polled_at: Option<Instant>,
    /// `ChatqReplyErrAt`: a failed fetch last logged
    pub err_at: Option<Instant>,
    /// `ChatqReplyBadIdAt`: a message whose id is not ntfy's shape last
    /// logged
    pub bad_id_at: Option<Instant>,
    /// `ChatqReplySavedAt`: where polling got to last saved
    pub saved_at: Option<Instant>,
    /// `ChatqReplyJunkLog`, by stage
    pub junk_log: BTreeMap<String, JunkEntry>,
    /// `ChatqReplyHandled`
    pub handled: Handled,
}

impl PollCaches {
    /// [Invoke-ChatqReplyPoll](src/phone.ps1) once a [Save::LastId] is
    /// written: its tags are handled, and that save is the latest.
    pub fn saved(&mut self, tags: &[String], now: Instant) {
        for t in tags {
            self.handled.add(t);
        }
        self.saved_at = Some(now);
    }
}

/// What a fetch of the reply topic brought ([Get-ChatqReplyFeed](src/phone.ps1)).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Feed<'a> {
    /// The body: ntfy's poll, one JSON object per line
    Text(&'a str),
    /// The fetch failed, with this message
    Failed(&'a str),
}

/// What [Invoke-ChatqReplyPoll](src/phone.ps1) writes to replies.json, with
/// [Use-ChatqReplyState](src/phone.ps1), after a batch holding no candidate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Save {
    /// Nothing
    None,
    /// `lastId`, the batch's last junk or already handled id, and
    /// `lastPolledAt`. Once written, [PollCaches::saved] with `tags`; a
    /// failure is logged `could not save where polling got to: <why>`.
    LastId { id: String, tags: Vec<String> },
    /// `lastPolledAt` alone, at most every 5 minutes: `saved_at` has moved
    /// already, and a failure is not logged
    PolledAt,
}

/// What [Invoke-ChatqReplyPoll](src/phone.ps1) comes to over one fetched
/// batch, as far as chatqd takes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pass {
    /// A message passed triage: the batch goes whole to a `reply` step, and
    /// the caches are as they were
    Candidate,
    /// Junk only, or a failed fetch, and nothing acted on: the lines for
    /// replies.log, each made one line as [Write-ChatqReplyLog](src/phone.ps1)
    /// makes it (watcher.log gets each after "phone: "), and what to save
    Done { log: Vec<String>, save: Save },
}

/// What one line of the batch turned out to be, before anything is changed.
enum Seen {
    BadId,
    Handled(String),
    Junk {
        id: String,
        stage: &'static str,
        error: &'static str,
    },
}

/// [Invoke-ChatqReplyPoll](src/phone.ps1) from its fetch on, for a batch
/// with no candidate. The lines in order: what is not a message event is
/// skipped, an id not ntfy's shape is skipped and logged at most every 10
/// minutes, a tag already handled is passed over, and each junk message is
/// logged per [Write-ChatqReplyJunk](src/phone.ps1). A failed fetch is
/// logged at most every 10 minutes. Times are compared as PowerShell
/// subtracts two `Get-Date`s, by wall clock in `zone`, and a junk line's
/// "since" is that wall clock in `culture`. The caller sets `polled_at`
/// before it fetches, then writes the log and the save.
/// Deferred: DEFERRED.md "ntfy's lines read as strict JSON"
pub fn poll_batch(
    caches: &mut PollCaches,
    rc: &TriageConfig,
    feed: Feed,
    now: Instant,
    zone: Zone,
    culture: &Culture,
    fl: Flavour,
) -> Pass {
    let mut log = Vec::new();
    let text = match feed {
        Feed::Text(t) => t,
        Feed::Failed(why) => {
            if caches
                .err_at
                .is_none_or(|t| since(zone, t, now) >= TimeDelta::minutes(10))
            {
                caches.err_at = Some(now);
                log.push(one_line(&format!("poll failed: {why}")));
            }
            return Pass::Done {
                log,
                save: Save::None,
            };
        }
    };
    let mut seen = Vec::new();
    for line in text.split('\n') {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(m) = serde_json::from_str::<Value>(&json::fix_lone_surrogates(line)) else {
            continue;
        };
        if !is_message_event(json::get(Some(&m), "event"), fl) {
            continue;
        }
        let id = json::to_ps_string(json::get(Some(&m), "id"));
        if !is_ntfy_id(&id) {
            seen.push(Seen::BadId);
            continue;
        }
        if caches.handled.contains(&tag(&rc.topic, &id)) {
            seen.push(Seen::Handled(id));
            continue;
        }
        let message = json::to_ps_string(json::get(Some(&m), "message"));
        match triage(&message, rc, fl) {
            Verdict::Candidate(_) => return Pass::Candidate,
            Verdict::Junk { stage, error } => seen.push(Seen::Junk { id, stage, error }),
        }
    }
    let mut junk_id = None;
    let mut tags = Vec::new();
    for s in seen {
        match s {
            Seen::BadId => {
                if caches
                    .bad_id_at
                    .is_none_or(|t| since(zone, t, now) >= TimeDelta::minutes(10))
                {
                    caches.bad_id_at = Some(now);
                    log.push("a message whose id is not ntfy's shape - skipped".to_string());
                }
            }
            Seen::Handled(id) => junk_id = Some(id),
            Seen::Junk { id, stage, error } => {
                let what = if stage == "pairing" {
                    format!("pairing {id} refused - {error}")
                } else {
                    format!("reply {id} refused - {stage}: {error}")
                };
                log.extend(write_junk(
                    &mut caches.junk_log,
                    stage,
                    &what,
                    now,
                    zone,
                    culture,
                ));
                tags.push(tag(&rc.topic, &id));
                junk_id = Some(id);
            }
        }
    }
    let save = match junk_id {
        Some(id) => Save::LastId { id, tags },
        None if caches
            .saved_at
            .is_none_or(|t| since(zone, t, now) >= TimeDelta::minutes(5)) =>
        {
            caches.saved_at = Some(now);
            Save::PolledAt
        }
        None => Save::None,
    };
    Pass::Done { log, save }
}

/// [Write-ChatqReplyJunk](src/phone.ps1): a stage's line at most every 5
/// minutes, with how many went unlogged since the last. The line to log, or
/// None when it was only counted.
fn write_junk(
    junk_log: &mut BTreeMap<String, JunkEntry>,
    stage: &str,
    text: &str,
    now: Instant,
    zone: Zone,
    culture: &Culture,
) -> Option<String> {
    let more = match junk_log.get_mut(stage) {
        Some(j) if since(zone, j.at, now) < TimeDelta::minutes(5) => {
            j.count += 1;
            return None;
        }
        Some(j) if j.count > 0 => format!(
            " (and {} more at this stage since {})",
            j.count,
            culture.hh_mm(&zone.wall(j.at))
        ),
        _ => String::new(),
    };
    junk_log.insert(stage.to_string(), JunkEntry { at: now, count: 0 });
    Some(one_line(&format!("{text}{more}")))
}

/// `$m.event -ne 'message'` false. `-ne` compares strings case-blind by the
/// invariant culture's collation, and takes `true` for 'message' (the string
/// made a bool); a number, null or an object is never equal. On an array it
/// filters, and the `if` sees what is left: nothing, or one element that is
/// false to PowerShell, lets the line through.
fn is_message_event(v: Option<&Value>, fl: Flavour) -> bool {
    let equal = |e: &Value| match e {
        Value::String(s) => same_text(s, "message", fl),
        Value::Bool(b) => *b,
        _ => false,
    };
    match v {
        Some(Value::Array(a)) => match a.iter().filter(|e| !equal(e)).collect::<Vec<_>>()[..] {
            [] => true,
            [one] => !json::truthy(Some(one)),
            _ => false,
        },
        Some(e) => equal(e),
        None => false,
    }
}

/// `-eq` between strings: case-blind, and blind to what the collation of
/// `fl`'s PowerShell gives no weight (wire/collation.rs).
fn same_text(a: &str, b: &str, fl: Flavour) -> bool {
    let weighed = |s: &str| {
        s.chars()
            .filter(|&c| !collation::ignorable(c, fl))
            .collect::<String>()
    };
    json::ieq(&weighed(a), &weighed(b))
}

/// `"$($rc.Topic)|$id"`
fn tag(topic: &str, id: &str) -> String {
    format!("{topic}|{id}")
}

/// `(Get-Date) - $then` between two local DateTimes: their wall clocks'
/// difference, which a change of offset between them shifts.
fn since(zone: Zone, then: Instant, now: Instant) -> TimeDelta {
    zone.wall(now) - zone.wall(then)
}

/// [Write-ChatqReplyLog](src/phone.ps1)'s `-replace '[\r\n]+', ' '`: an
/// error with a line break must not pass for a second entry.
fn one_line(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut broke = false;
    for c in text.chars() {
        if c == '\r' || c == '\n' {
            if !broke {
                out.push(' ');
            }
            broke = true;
        } else {
            out.push(c);
            broke = false;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, FixedOffset, Utc};

    /// The phone's key D of the fixtures: bytes 0 to 31.
    fn d1() -> Vec<u8> {
        (0..32).collect()
    }

    /// A reply in Hangul sealed by docs/reply.html under D1, for alert
    /// abcdefghij.
    const REPLY: &str = "chatq1.abcdefghij.EBESExQVFhcYGRobHB0eHw.xO-98YQ9Jd0jup8AecpTNLpF6t1lVjfh6VYt_nzxToTwFcb-jwqNcwfCnnUrMOIgCCochJ2NIiTOuW1rgOaL4F5CWrNY_53Foj0EXSySFlp0r48x4c4hAL8Lcai17UnRP29qq4W_WZyIBWyNChgFeQ.7cEASaRYNcY9fLGFD5zPWPotBionoTREbszEDeVRUCU";

    /// A compose message sealed under D1, id klmnopqrst.
    const COMPOSE: &str = "chatq3c.klmnopqrst.EBESExQVFhcYGRobHB0eHw.-2S6B6Mp6rXFEyNrdN-ARDkAB8S64GlZd71qIehFFLLFcUDXvNa7KPK6tOcEHsCv3zKECK8XydsziQtNHVm3bsV2Jlvg1uVOhDlhfVIA3nv2Jv6Aspsx-dpDTRlYWNPn0uX_w6yL9z6HCdzUV6m2qyrI6paFAHXRQO2E1PC1sjQPBhKpkToySBvKWUAD76k0.28EXQkaAvHVcIg3ci1y97wmoZR5IvSWti_1on5kKuTM";

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    fn at(s: &str) -> Instant {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn paired() -> TriageConfig {
        TriageConfig {
            topic: Zeroizing::new("t".into()),
            master: Some(Zeroizing::new(d1())),
            pair_id: None,
            pair_key: false,
        }
    }

    fn line(id: &str, message: &str) -> String {
        serde_json::json!({"id": id, "event": "message", "message": message}).to_string()
    }

    #[test]
    fn b64url_as_dotnet_reads_it() {
        assert_eq!(b64url_encode(&[0xfb, 0xff]), "-_8");
        assert_eq!(b64url_decode(""), Some(vec![]));
        // trailing bits are let by: Q and R end alike
        assert_eq!(b64url_decode("AQ"), Some(vec![1]));
        assert_eq!(b64url_decode("AR"), Some(vec![1]));
        assert_eq!(b64url_decode("-_-_"), Some(vec![0xfb, 0xff, 0xbf]));
        for bad in [
            "A", "AAAAA", "AA==", "AA=", "+/", "AA AA", "AA\n", "\n", "AA\u{c0}",
        ] {
            assert_eq!(b64url_decode(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn keys_and_code() {
        let k = label_keys(&d1(), "chatq-alert:", "abcdefghij");
        assert_eq!(
            hex(&k.k),
            "6b8be8bbce142449b8a1516e20cbf70ac8ef321eb489670408ef1c0ffb6fb40a"
        );
        assert_eq!(
            hex(&k.mac),
            "e7f9eccb5227d79c20ebf2a390078b0d4834321940878766aa0d87128b5a39b2"
        );
        assert_eq!(pair_code(&d1()), "026316");
        assert_eq!(pair_code_spaced(&d1()), "026 316");
        let d2: Vec<u8> = (0..32u8)
            .map(|i| 0xf0u8.wrapping_sub(i.wrapping_mul(0x0f)))
            .collect();
        assert_eq!(hex(&d2)[..8], *"f0e1d2c3");
        assert!(same_bytes(&[1, 2], &[1, 2]));
        assert!(!same_bytes(&[1, 2], &[1, 3]));
        assert!(!same_bytes(&[1, 2], &[1, 2, 3]));
    }

    #[test]
    fn open_sealed_stages() {
        let d = d1();
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(
                open_sealed(REPLY, Some(&d), Sealed::Reply, fl).unwrap(),
                "abcdefghij"
            );
            assert_eq!(
                open_sealed(COMPOSE, Some(&d), Sealed::Compose, fl).unwrap(),
                "klmnopqrst"
            );
            let r = open_sealed(REPLY, None, Sealed::Reply, fl).unwrap_err();
            assert_eq!(
                (r.stage, r.error, r.id),
                ("format", "no phone paired", None)
            );
            let r = open_sealed(
                &REPLY.replace(".7cEASa", ".8cEASa"),
                Some(&d),
                Sealed::Reply,
                fl,
            )
            .unwrap_err();
            assert_eq!(
                (r.stage, r.error, r.id.as_deref()),
                ("mac", "the MAC does not match", Some("abcdefghij"))
            );
            let r = open_sealed(COMPOSE, Some(&d), Sealed::Reply, fl).unwrap_err();
            assert_eq!((r.stage, r.error), ("format", "not a chatq reply"));
            // U+FEFF weighs nothing to either: past the prefix, the MAC is over it
            let r =
                open_sealed(&format!("\u{feff}{REPLY}"), Some(&d), Sealed::Reply, fl).unwrap_err();
            assert_eq!(r.stage, "mac");
        }
        // what each edition ignores inside the prefix, and pwsh 7's other
        // digits in place of its 1
        for (prefix, desktop, core) in [
            ("chat\u{200b}q1", "format", "mac"),
            ("chat\u{0378}q1", "mac", "format"),
            ("chatq\u{0661}", "format", "mac"),
            ("chatq\u{ff11}", "format", "format"),
        ] {
            let m = REPLY.replacen("chatq1", prefix, 1);
            for (fl, want) in [(Flavour::Desktop, desktop), (Flavour::Core, core)] {
                let r = open_sealed(&m, Some(&d), Sealed::Reply, fl).unwrap_err();
                assert_eq!(r.stage, want, "{prefix:?} {fl:?}");
            }
        }
    }

    #[test]
    fn triage_dispatch() {
        let fl = Flavour::Core;
        let rc = paired();
        assert_eq!(triage(COMPOSE, &rc, fl), Verdict::Candidate(Kind::Compose));
        assert_eq!(
            triage(&format!(" \t{REPLY}\r\n"), &rc, fl),
            Verdict::Candidate(Kind::Reply)
        );
        let junk = |stage, error| Verdict::Junk { stage, error };
        assert_eq!(
            triage(" chatq3c.x", &rc, fl),
            junk("format", "not a chatq message from the phone")
        );
        // the dispatch is ordinal: pwsh 7's other 3 makes it a reply
        assert_eq!(
            triage(&COMPOSE.replacen('3', "\u{0663}", 1), &rc, fl),
            junk("format", "not a chatq reply")
        );
        assert_eq!(
            triage("chatq2p.x", &rc, fl),
            junk("pairing", "not a pairing message")
        );
        let ct = b64url_encode(&[1; 64]);
        let pair = format!("chatq2p.abcdefghij.{ct}");
        assert_eq!(
            triage(&pair, &rc, fl),
            junk("pairing", "for no pairing in progress")
        );
        let mut pending = paired();
        pending.pair_id = Some("abcdefghij".into());
        assert_eq!(
            triage(&pair, &pending, fl),
            junk("pairing", "the pairing key cannot be read here")
        );
        pending.pair_key = true;
        assert_eq!(triage(&pair, &pending, fl), Verdict::Candidate(Kind::Pair));
        let short = format!("chatq2p.abcdefghij.{}", b64url_encode(&[1; 63]));
        assert_eq!(
            triage(&short, &pending, fl),
            junk("pairing", "bad encoding")
        );
    }

    #[test]
    fn junk_is_logged_counted_and_saved() {
        let rc = paired();
        let zone = Zone::Fixed(FixedOffset::east_opt(9 * 3600).unwrap());
        let culture = Culture::invariant();
        let fl = Flavour::Desktop;
        let mut c = PollCaches::default();
        let t0 = at("2026-10-15T00:00:00Z");
        let feed = [line("m1", "hello"), "not json".into(), line("m2", "")].join("\n");
        let Pass::Done { log, save } =
            poll_batch(&mut c, &rc, Feed::Text(&feed), t0, zone, &culture, fl)
        else {
            panic!("junk is no candidate")
        };
        assert_eq!(log, ["reply m1 refused - format: not a chatq reply"]);
        assert_eq!(c.junk_log["format"], JunkEntry { at: t0, count: 1 });
        let Save::LastId { id, tags } = save else {
            panic!("{save:?}")
        };
        assert_eq!(
            (id.as_str(), tags.as_slice()),
            ("m2", ["t|m1".to_string(), "t|m2".to_string()].as_slice())
        );
        c.saved(&tags, t0);
        // a tag handled, whatever its id's case: lastId moves to it, unlogged
        let t1 = at("2026-10-15T00:04:00Z");
        let feed = line("M1", "hello");
        let pass = poll_batch(&mut c, &rc, Feed::Text(&feed), t1, zone, &culture, fl);
        let want = Save::LastId {
            id: "M1".into(),
            tags: vec![],
        };
        assert_eq!(
            pass,
            Pass::Done {
                log: vec![],
                save: want
            }
        );
        assert_eq!(c.handled.tags(), ["t|m1", "t|m2"]);
        // 5 minutes on, the stage's line again, with what went unlogged
        let t2 = at("2026-10-15T00:05:00Z");
        let feed = line("m3", "chatq1.x");
        let Pass::Done { log, .. } =
            poll_batch(&mut c, &rc, Feed::Text(&feed), t2, zone, &culture, fl)
        else {
            panic!("junk is no candidate")
        };
        assert_eq!(
            log,
            ["reply m3 refused - format: not a chatq reply (and 1 more at this stage since 09:00)"]
        );
        // nothing at all: lastPolledAt alone, at most every 5 minutes
        c.saved_at = Some(t2);
        let pass = poll_batch(
            &mut c,
            &rc,
            Feed::Text(""),
            at("2026-10-15T00:09:59Z"),
            zone,
            &culture,
            fl,
        );
        assert_eq!(
            pass,
            Pass::Done {
                log: vec![],
                save: Save::None
            }
        );
        let t3 = at("2026-10-15T00:10:00Z");
        let pass = poll_batch(&mut c, &rc, Feed::Text(""), t3, zone, &culture, fl);
        assert_eq!(
            pass,
            Pass::Done {
                log: vec![],
                save: Save::PolledAt
            }
        );
        assert_eq!(c.saved_at, Some(t3));
    }

    #[test]
    fn a_candidate_leaves_everything_to_the_step() {
        let rc = paired();
        let zone = Zone::Fixed(FixedOffset::east_opt(0).unwrap());
        let mut c = PollCaches::default();
        let feed = [
            line("m1", "hello"),
            line("m2", REPLY),
            "{\"id\":\"bad id\",\"event\":\"message\"}".into(),
        ]
        .join("\n");
        let now = at("2026-10-15T00:00:00Z");
        let pass = poll_batch(
            &mut c,
            &rc,
            Feed::Text(&feed),
            now,
            zone,
            &Culture::invariant(),
            Flavour::Core,
        );
        assert_eq!(pass, Pass::Candidate);
        assert_eq!(c, PollCaches::default());
    }

    #[test]
    fn events_and_ids_as_powershell_reads_them() {
        let fl = Flavour::Core;
        let ev = |j: &str| is_message_event(Some(&serde_json::from_str(j).unwrap()), fl);
        for j in [
            r#""MESSAGE""#,
            "true",
            "[]",
            r#"["message"]"#,
            r#"[""]"#,
            "[null]",
            "[0]",
            "[false]",
            "[true]",
            "[[]]",
            "\"mess\u{ad}age\"",
        ] {
            assert!(ev(j), "{j}");
        }
        for j in [
            r#""message ""#,
            "false",
            "0",
            "1",
            "null",
            "{}",
            r#"["x"]"#,
            r#"["message","x"]"#,
            "[1]",
        ] {
            assert!(!ev(j), "{j}");
        }
        assert!(is_ntfy_id("abc\n") && is_ntfy_id(&"a".repeat(40)));
        assert!(!is_ntfy_id("") && !is_ntfy_id(&"a".repeat(41)) && !is_ntfy_id("a.b"));
        assert_eq!(one_line("boom\r\nsecond\n\nthird\r"), "boom second third ");
    }

    #[test]
    fn a_failed_fetch_logs_every_10_minutes() {
        let rc = paired();
        let zone = Zone::Fixed(FixedOffset::east_opt(0).unwrap());
        let culture = Culture::invariant();
        let mut c = PollCaches::default();
        let mut poll = |t: &str, why: &str| match poll_batch(
            &mut c,
            &rc,
            Feed::Failed(why),
            at(t),
            zone,
            &culture,
            Flavour::Desktop,
        ) {
            Pass::Done {
                log,
                save: Save::None,
            } => log,
            p => panic!("{p:?}"),
        };
        assert_eq!(poll("2026-10-15T00:00:00Z", "a\r\nb"), ["poll failed: a b"]);
        assert!(poll("2026-10-15T00:09:59Z", "c").is_empty());
        assert_eq!(poll("2026-10-15T00:10:00Z", "d"), ["poll failed: d"]);
    }
}
