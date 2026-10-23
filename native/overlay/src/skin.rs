// Skin packs (docs/skin-pack.md): the mascot's faces, lines and voice as
// data, in <data folder>/skins/<id>/ - the folder chatq-overlay.exe is given
// (main.rs), beside the Brain's brain/. This is the loader alone, section
// 6's first piece: scan, validate against section 3's rules, parse. The
// atlas animator, the mood switch and the line picker build on it; nothing
// in the panel calls it yet. The built-in default, skins/default/, is
// compiled in, so the exe runs with an empty data folder.
// native/vectors/skin-manifest.json pins the rules with synthetic packs,
// written by hand (no PowerShell loads a skin); the tests below run it.
#![cfg_attr(not(test), allow(dead_code))]

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde_json::{Map, Value};

use crate::selflog;

/// The format this engine knows, major and minor.
pub const FORMAT: (u64, u64) = (1, 0);
/// The built-in skin's id.
pub const DEFAULT: &str = "default";
/// One atlas's budget: the sheet's sides, its file, its decoded RGBA and
/// its frames (docs/skin-pack.md, moods/<mood>.json).
pub const MAX_SHEET_PX: u64 = 4096;
pub const MAX_PNG_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_DECODED_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_FRAMES: u64 = 120;
/// The filled-line cap where skin.json sets none.
const MAX_CHARS: u32 = 95;

/// skins/default/ as the exe carries it: every file the loader reads.
const BUILTIN: &[(&str, &[u8])] = &[
    (
        "skin.json",
        include_bytes!("../../../skins/default/skin.json"),
    ),
    (
        "lines.json",
        include_bytes!("../../../skins/default/lines.json"),
    ),
    (
        "moodmap.json",
        include_bytes!("../../../skins/default/moodmap.json"),
    ),
    (
        "moods/idle.json",
        include_bytes!("../../../skins/default/moods/idle.json"),
    ),
    (
        "moods/idle.png",
        include_bytes!("../../../skins/default/moods/idle.png"),
    ),
    (
        "moods/ready.json",
        include_bytes!("../../../skins/default/moods/ready.json"),
    ),
    (
        "moods/ready.png",
        include_bytes!("../../../skins/default/moods/ready.png"),
    ),
    (
        "moods/pleased.json",
        include_bytes!("../../../skins/default/moods/pleased.json"),
    ),
    (
        "moods/pleased.png",
        include_bytes!("../../../skins/default/moods/pleased.png"),
    ),
    (
        "moods/sad.json",
        include_bytes!("../../../skins/default/moods/sad.json"),
    ),
    (
        "moods/sad.png",
        include_bytes!("../../../skins/default/moods/sad.png"),
    ),
    (
        "moods/smug.json",
        include_bytes!("../../../skins/default/moods/smug.json"),
    ),
    (
        "moods/smug.png",
        include_bytes!("../../../skins/default/moods/smug.png"),
    ),
    (
        "moods/angry.json",
        include_bytes!("../../../skins/default/moods/angry.json"),
    ),
    (
        "moods/angry.png",
        include_bytes!("../../../skins/default/moods/angry.png"),
    ),
    (
        "moods/scared.json",
        include_bytes!("../../../skins/default/moods/scared.json"),
    ),
    (
        "moods/scared.png",
        include_bytes!("../../../skins/default/moods/scared.png"),
    ),
];

/// The closed set of moods the engine knows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Mood {
    Idle,
    Ready,
    Pleased,
    Sad,
    Smug,
    Angry,
    Scared,
}

impl Mood {
    pub const ALL: [Mood; 7] = [
        Mood::Idle,
        Mood::Ready,
        Mood::Pleased,
        Mood::Sad,
        Mood::Smug,
        Mood::Angry,
        Mood::Scared,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Mood::Idle => "idle",
            Mood::Ready => "ready",
            Mood::Pleased => "pleased",
            Mood::Sad => "sad",
            Mood::Smug => "smug",
            Mood::Angry => "angry",
            Mood::Scared => "scared",
        }
    }

    pub fn parse(s: &str) -> Option<Mood> {
        Mood::ALL.into_iter().find(|m| m.as_str() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Play {
    Loop,
    Pingpong,
}

/// skin.json's mascot: display px, atlas px per display px, and the point
/// that sits on the panel's mascot slot.
#[derive(Clone, Debug, PartialEq)]
pub struct Mascot {
    pub w: u32,
    pub h: u32,
    pub scale: u32,
    pub anchor: [i64; 2],
}

/// The tray's still: a frame of a mood's atlas, cut to [x, y, w, h] in
/// frame px.
#[derive(Clone, Debug, PartialEq)]
pub struct Tray {
    pub mood: Mood,
    pub frame: u32,
    pub crop: [u32; 4],
}

#[derive(Clone, Debug, PartialEq)]
pub struct Manifest {
    /// major, minor
    pub format: (u64, u64),
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    /// the box header's name, as written; [Skin::voice] is the one said
    pub voice: String,
    pub tags: Vec<String>,
    pub mascot: Mascot,
    pub colours: BTreeMap<String, String>,
    pub tray: Option<Tray>,
    /// the known moods listed, in the file's order
    pub moods: Vec<Mood>,
    pub fallback: BTreeMap<Mood, Mood>,
    pub modes: Vec<String>,
    pub max_chars: u32,
}

/// moods/<mood>.json, held to its sheet.
#[derive(Clone, Debug, PartialEq)]
pub struct AtlasMeta {
    pub frames: u32,
    pub fps: u32,
    /// one frame, atlas px
    pub w: u32,
    pub h: u32,
    pub cols: u32,
    /// frames over cols, rounded up: the last row may be short
    pub rows: u32,
    pub play: Play,
}

impl AtlasMeta {
    /// The sheet, cols x w by rows x h.
    pub fn sheet(&self) -> (u32, u32) {
        (self.cols * self.w, self.rows * self.h)
    }

    /// Frame `i`'s clip in the sheet, [x, y, w, h], row-major.
    pub fn clip(&self, i: u32) -> [u32; 4] {
        [
            (i % self.cols) * self.w,
            (i / self.cols) * self.h,
            self.w,
            self.h,
        ]
    }
}

/// Where an atlas's PNG is: in the exe, or a file of a pack. Read only when
/// its mood comes on show.
#[derive(Clone, Debug, PartialEq)]
pub enum Png {
    Builtin(&'static [u8]),
    File(PathBuf),
}

impl Png {
    pub fn bytes(&self) -> std::io::Result<Cow<'static, [u8]>> {
        match self {
            Png::Builtin(b) => Ok(Cow::Borrowed(b)),
            Png::File(p) => std::fs::read(p).map(Cow::Owned),
        }
    }

    fn len(&self) -> std::io::Result<u64> {
        match self {
            Png::Builtin(b) => Ok(b.len() as u64),
            Png::File(p) => std::fs::metadata(p).map(|m| m.len()),
        }
    }

    /// Its first 24 bytes, the signature and IHDR's size, or fewer.
    fn head(&self) -> std::io::Result<Vec<u8>> {
        match self {
            Png::Builtin(b) => Ok(b[..b.len().min(24)].to_vec()),
            Png::File(p) => {
                let mut head = Vec::with_capacity(24);
                std::fs::File::open(p)?.take(24).read_to_end(&mut head)?;
                Ok(head)
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Atlas {
    pub meta: AtlasMeta,
    pub png: Png,
}

/// One of moodmap.json's phrases: `match` substrings, then `regex`
/// patterns (Rust regex syntax, compiled by the mood switch).
#[derive(Clone, Debug, PartialEq)]
pub struct Phrase {
    pub mood: Mood,
    pub matches: Vec<String>,
    pub regex: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Moodmap {
    pub sections: BTreeMap<String, Mood>,
    pub locked: Vec<String>,
    pub phrases: Vec<Phrase>,
}

/// lines.json: the pack's, its `status` laid over the default skin's, or
/// the default skin's own where the pack's is missing or broken.
#[derive(Clone, Debug, PartialEq)]
pub struct Bank {
    v: Value,
    /// the default skin's lines stand in for the pack's
    pub default: bool,
}

impl Bank {
    pub fn value(&self) -> &Value {
        &self.v
    }

    /// A section by its dotted path ("conversations.habit.roast"); None
    /// where the bank has none.
    pub fn get(&self, path: &str) -> Option<&Value> {
        path.split('.').try_fold(&self.v, |v, k| v.get(k))
    }

    /// The event whose `id` is `id`.
    pub fn event(&self, id: &str) -> Option<&Value> {
        self.v
            .get("events")?
            .as_array()?
            .iter()
            .find(|e| e.get("id").and_then(Value::as_str) == Some(id))
    }

    /// The status lines, which never go missing: the default skin's under
    /// the pack's.
    pub fn status(&self) -> &Value {
        &self.v["status"]
    }
}

/// Why a pack does not load: the file, from the pack's folder, and the rule.
#[derive(Clone, Debug, PartialEq)]
pub struct SkinError {
    pub file: String,
    pub rule: String,
}

impl fmt::Display for SkinError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}: {}", self.file, self.rule)
    }
}

fn err(file: &str, rule: impl Into<String>) -> SkinError {
    SkinError {
        file: file.to_string(),
        rule: rule.into(),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Skin {
    pub manifest: Manifest,
    pub moodmap: Moodmap,
    pub bank: Bank,
    /// the moods whose atlas passed, each its own
    atlases: BTreeMap<Mood, Atlas>,
    voice: String,
    /// the pack's folder; None for the built-in
    pub dir: Option<PathBuf>,
    /// what [load_or_default] logs for this load, one line each
    pub notes: Vec<String>,
}

impl Default for Skin {
    /// The built-in skin, from the exe's own bytes.
    fn default() -> Skin {
        static SKIN: OnceLock<Skin> = OnceLock::new();
        SKIN.get_or_init(|| {
            read_pack(&Root::Builtin, DEFAULT).unwrap_or_else(|e| panic!("the built-in skin: {e}"))
        })
        .clone()
    }
}

impl Skin {
    pub fn id(&self) -> &str {
        &self.manifest.id
    }

    /// The name the box header shows: the default skin's where its lines
    /// stand in.
    pub fn voice(&self) -> &str {
        &self.voice
    }

    /// The mood's own atlas, if the pack has one that passed.
    pub fn atlas(&self, mood: Mood) -> Option<&Atlas> {
        self.atlases.get(&mood)
    }

    /// The moods with an atlas, in [Mood::ALL]'s order.
    pub fn moods(&self) -> impl Iterator<Item = Mood> + '_ {
        self.atlases.keys().copied()
    }

    /// The face a mood wears, as the prototype's faceOf: its own atlas,
    /// else its fallback's, else ready's, which every pack has.
    pub fn face(&self, mood: Mood) -> Mood {
        if self.atlases.contains_key(&mood) {
            return mood;
        }
        match self.manifest.fallback.get(&mood) {
            Some(f) if self.atlases.contains_key(f) => *f,
            _ => Mood::Ready,
        }
    }

    /// The atlas a mood plays: its face's.
    pub fn atlas_for(&self, mood: Mood) -> &Atlas {
        &self.atlases[&self.face(mood)]
    }
}

/// A Skin menu entry.
#[derive(Clone, Debug, PartialEq)]
pub struct Pack {
    pub id: String,
    /// the manifest's name; the folder's for a broken pack
    pub name: String,
    pub version: String,
    /// why it does not load: greyed, this its tooltip
    pub broken: Option<SkinError>,
}

/// The Skin menu's list: Default first, then every folder in
/// <data>/skins/ by name, a broken one with its reason. No skins/ folder
/// is no packs.
pub fn scan(data: &Path) -> Vec<Pack> {
    let builtin = Skin::default();
    let mut out = vec![Pack {
        id: DEFAULT.to_string(),
        name: builtin.manifest.name,
        version: builtin.manifest.version,
        broken: None,
    }];
    let Ok(dir) = std::fs::read_dir(data.join("skins")) else {
        return out;
    };
    let mut packs: Vec<Pack> = dir
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|id| !id.starts_with('.'))
        .map(|id| match load_dir(&data.join("skins").join(&id), &id) {
            Ok(s) => Pack {
                id,
                name: s.manifest.name,
                version: s.manifest.version,
                broken: None,
            },
            Err(e) => Pack {
                name: id.clone(),
                id,
                version: String::new(),
                broken: Some(e),
            },
        })
        .collect();
    packs.sort_by(|a, b| (a.name.to_lowercase(), &a.id).cmp(&(b.name.to_lowercase(), &b.id)));
    out.extend(packs);
    out
}

/// The skin `id`: the built-in for `default`, else <data>/skins/<id>/.
pub fn load(data: &Path, id: &str) -> Result<Skin, SkinError> {
    if id == DEFAULT {
        return Ok(Skin::default());
    }
    if !valid_id(id) {
        return Err(err(&format!("skins/{id}"), "not a skin id ([a-z0-9-]+)"));
    }
    load_dir(&data.join("skins").join(id), id)
}

/// [load], or the built-in when it fails; either way its notes go to the
/// self log, the failure as `skin <id>: <reason>; using default`.
pub fn load_or_default(data: &Path, id: &str) -> Skin {
    let skin = load(data, id).unwrap_or_else(|e| Skin {
        notes: vec![format!("skin {id}: {e}; using default")],
        ..Skin::default()
    });
    for n in &skin.notes {
        selflog::line(n);
    }
    skin
}

fn load_dir(dir: &Path, folder: &str) -> Result<Skin, SkinError> {
    if !dir.is_dir() {
        return Err(err(&format!("skins/{folder}"), "not found"));
    }
    let mut skin = read_pack(&Root::Dir(dir), folder)?;
    skin.dir = Some(dir.to_path_buf());
    Ok(skin)
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Where a pack's files are read from.
enum Root<'a> {
    Dir(&'a Path),
    Builtin,
}

impl Root<'_> {
    /// A file's bytes; None where it is not there.
    fn bytes(&self, rel: &str) -> Result<Option<Cow<'static, [u8]>>, String> {
        match self {
            Root::Builtin => Ok(builtin_file(rel).map(Cow::Borrowed)),
            Root::Dir(d) => match std::fs::read(d.join(rel)) {
                Ok(b) => Ok(Some(Cow::Owned(b))),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(format!("cannot be read: {e}")),
            },
        }
    }

    fn png(&self, rel: &str) -> Option<Png> {
        match self {
            Root::Builtin => builtin_file(rel).map(Png::Builtin),
            Root::Dir(d) => Some(d.join(rel)).filter(|p| p.is_file()).map(Png::File),
        }
    }
}

fn builtin_file(rel: &str) -> Option<&'static [u8]> {
    BUILTIN.iter().find(|(n, _)| *n == rel).map(|(_, b)| *b)
}

/// A JSON object, a UTF-8 BOM allowed; the rule it breaks otherwise.
fn object(bytes: &[u8]) -> Result<Map<String, Value>, String> {
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    match serde_json::from_slice(bytes) {
        Ok(Value::Object(m)) => Ok(m),
        Ok(_) => Err("is not a JSON object".into()),
        Err(e) => Err(format!("does not parse: {e}")),
    }
}

/// `m[key]` as a whole number, above 0 unless `zero`.
fn number(m: &Map<String, Value>, key: &str, zero: bool) -> Option<u32> {
    let n = m.get(key)?.as_u64()?;
    (zero || n > 0).then_some(u32::try_from(n).ok()?)
}

fn whole(m: &Map<String, Value>, key: &str, file: &str, path: &str) -> Result<u32, SkinError> {
    number(m, key, false).ok_or_else(|| err(file, format!("{path} must be a whole number above 0")))
}

fn text(m: &Map<String, Value>, key: &str, file: &str) -> Result<String, SkinError> {
    match m.get(key).and_then(Value::as_str) {
        Some(s) if !s.is_empty() => Ok(s.to_string()),
        _ => Err(err(file, format!("{key} must be a non-empty string"))),
    }
}

fn strings(v: Option<&Value>) -> Option<Vec<String>> {
    v?.as_array()?
        .iter()
        .map(|x| x.as_str().map(str::to_string))
        .collect()
}

/// `b` laid over `a`, object by object, as the prototype's `deep`.
fn deep(a: &Value, b: Option<&Value>) -> Value {
    match (a, b) {
        (_, None) => a.clone(),
        (Value::Object(x), Some(Value::Object(y))) => {
            let mut o = x.clone();
            for (k, v) in y {
                let merged = deep(x.get(k).unwrap_or(&Value::Null), Some(v));
                o.insert(k.clone(), merged);
            }
            Value::Object(o)
        }
        (_, Some(b)) => b.clone(),
    }
}

const SKIN: &str = "skin.json";
const MOODMAP: &str = "moodmap.json";
const LINES: &str = "lines.json";

/// Every rule of docs/skin-pack.md section 3, in the order a writer meets
/// them: skin.json, each listed mood's atlas, the tray against its atlas,
/// moodmap.json, lines.json. An unknown mood id or a newer format minor is
/// skipped; a mood other than idle and ready whose atlas breaks a rule is
/// dropped and wears its fallback; lines.json broken gives the default
/// skin's lines. Each of those is one note.
fn read_pack(root: &Root, folder: &str) -> Result<Skin, SkinError> {
    let builtin = matches!(root, Root::Builtin);
    let bytes = root
        .bytes(SKIN)
        .map_err(|e| err(SKIN, e))?
        .ok_or_else(|| err(SKIN, "missing"))?;
    let m = object(&bytes).map_err(|e| err(SKIN, e))?;
    let mut notes = Vec::new();
    let mut unknown = BTreeSet::new();

    let format = match m.get("format") {
        Some(Value::Number(n)) => n.as_u64().map(|x| (x, 0)),
        Some(Value::String(s)) => s
            .split_once('.')
            .and_then(|(a, b)| Some((a.parse().ok()?, b.parse().ok()?))),
        _ => None,
    }
    .ok_or_else(|| err(SKIN, "format must be 1 or \"1.<minor>\""))?;
    if format.0 != FORMAT.0 {
        return Err(err(
            SKIN,
            format!("format {} is not {}", format.0, FORMAT.0),
        ));
    }

    let id = m.get("id").and_then(Value::as_str).unwrap_or_default();
    if !valid_id(id) {
        return Err(err(SKIN, "id must be [a-z0-9-]+"));
    }
    if id != folder {
        return Err(err(
            SKIN,
            format!("id {id} is not the folder's name, {folder}"),
        ));
    }
    if !builtin && id == DEFAULT {
        return Err(err(SKIN, "id default is the built-in skin's"));
    }
    let id = id.to_string();
    if format.1 > FORMAT.1 {
        notes.push(format!(
            "skin {id}: format {}.{} is newer than {}.{}; what it adds is skipped",
            format.0, format.1, FORMAT.0, FORMAT.1
        ));
    }
    let name = text(&m, "name", SKIN)?;
    let voice = text(&m, "voice", SKIN)?;

    let Some(Value::Object(ma)) = m.get("mascot") else {
        return Err(err(SKIN, "mascot must be an object"));
    };
    let (w, h) = (
        whole(ma, "w", SKIN, "mascot.w")?,
        whole(ma, "h", SKIN, "mascot.h")?,
    );
    let scale = whole(ma, "scale", SKIN, "mascot.scale")?;
    let anchor = match ma.get("anchor") {
        None => [i64::from(w / 2), i64::from(h)],
        Some(a) => {
            let v = a
                .as_array()
                .and_then(|a| a.iter().map(Value::as_i64).collect::<Option<Vec<i64>>>());
            match v.as_deref() {
                Some(&[x, y]) => [x, y],
                _ => return Err(err(SKIN, "mascot.anchor must be [x, y]")),
            }
        }
    };
    let mascot = Mascot {
        w,
        h,
        scale,
        anchor,
    };

    let list = strings(m.get("moods")).ok_or_else(|| err(SKIN, "moods must be a list of names"))?;
    let mut moods = Vec::new();
    for s in &list {
        match Mood::parse(s) {
            Some(md) if !moods.contains(&md) => moods.push(md),
            Some(_) => {}
            None => {
                unknown.insert(s.clone());
            }
        }
    }
    if !moods.contains(&Mood::Idle) || !moods.contains(&Mood::Ready) {
        return Err(err(SKIN, "moods must list idle and ready"));
    }

    let mut fallback = BTreeMap::new();
    if let Some(f) = m.get("fallback") {
        let f = f
            .as_object()
            .ok_or_else(|| err(SKIN, "fallback must be an object"))?;
        for (k, t) in f {
            let t = t
                .as_str()
                .ok_or_else(|| err(SKIN, format!("fallback.{k} must be a mood")))?;
            let (Some(km), Some(tm)) = (Mood::parse(k), Mood::parse(t)) else {
                for s in [k.as_str(), t] {
                    if Mood::parse(s).is_none() {
                        unknown.insert(s.to_string());
                    }
                }
                continue;
            };
            if km == Mood::Ready {
                return Err(err(SKIN, "fallback.ready: ready never falls back"));
            }
            if !moods.contains(&tm) {
                return Err(err(SKIN, format!("fallback.{k}: {t} is not a listed mood")));
            }
            fallback.insert(km, tm);
        }
    }

    let tray = match m.get("tray") {
        None => None,
        Some(Value::Object(t)) => {
            let mood = t.get("mood").and_then(Value::as_str).unwrap_or("ready");
            let frame = number(t, "frame", true);
            let crop = t.get("crop").and_then(Value::as_array).and_then(|a| {
                let v: Option<Vec<u32>> = a
                    .iter()
                    .map(|x| x.as_u64().and_then(|n| u32::try_from(n).ok()))
                    .collect();
                v.filter(|v| v.len() == 4 && v[2] > 0 && v[3] > 0)
            });
            let crop =
                crop.ok_or_else(|| err(SKIN, "tray.crop must be [x, y, w, h], w and h above 0"))?;
            let frame = match t.get("frame") {
                None => 0,
                Some(_) => frame.ok_or_else(|| err(SKIN, "tray.frame must be a whole number"))?,
            };
            match Mood::parse(mood) {
                None => {
                    unknown.insert(mood.to_string());
                    None
                }
                Some(md) if !moods.contains(&md) => {
                    return Err(err(SKIN, format!("tray.mood: {mood} is not a listed mood")));
                }
                Some(md) => Some(Tray {
                    mood: md,
                    frame,
                    crop: [crop[0], crop[1], crop[2], crop[3]],
                }),
            }
        }
        Some(_) => return Err(err(SKIN, "tray must be an object")),
    };

    let modes = match m.get("modes") {
        None => vec!["killer".to_string()],
        Some(v) => strings(Some(v))
            .filter(|v| !v.is_empty())
            .ok_or_else(|| err(SKIN, "modes must be a list of names"))?,
    };
    let max_chars = match m.get("maxChars") {
        None => MAX_CHARS,
        Some(_) => whole(&m, "maxChars", SKIN, "maxChars")?,
    };
    let manifest = Manifest {
        format,
        id: id.clone(),
        name,
        version: m
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        author: m
            .get("author")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        voice: voice.clone(),
        tags: strings(m.get("tags")).unwrap_or_default(),
        mascot,
        colours: m
            .get("colours")
            .and_then(Value::as_object)
            .map(|c| {
                c.iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                    .collect()
            })
            .unwrap_or_default(),
        tray,
        moods,
        fallback,
        modes,
        max_chars,
    };

    let mut atlases = BTreeMap::new();
    let mut dropped = Vec::new();
    for &md in &manifest.moods {
        match atlas(root, md, &manifest.mascot) {
            Ok(a) => {
                atlases.insert(md, a);
            }
            Err(e) if md == Mood::Idle || md == Mood::Ready => return Err(e),
            Err(e) => dropped.push((md, e)),
        }
    }

    if let Some(t) = &manifest.tray
        && let Some(a) = atlases.get(&t.mood)
    {
        let mood = t.mood.as_str();
        if t.frame >= a.meta.frames {
            return Err(err(
                SKIN,
                format!(
                    "tray.frame: {} is past {mood}'s {} frames",
                    t.frame, a.meta.frames
                ),
            ));
        }
        let [x, y, cw, ch] = t.crop.map(u64::from);
        if x + cw > u64::from(a.meta.w) || y + ch > u64::from(a.meta.h) {
            return Err(err(
                SKIN,
                format!(
                    "tray.crop must lie inside the {}x{} frame",
                    a.meta.w, a.meta.h
                ),
            ));
        }
    }

    let moodmap = moodmap(root, &mut unknown)?;

    if !unknown.is_empty() {
        let list: Vec<&str> = unknown.iter().map(String::as_str).collect();
        notes.push(format!(
            "skin {id}: unknown moods skipped: {}",
            list.join(", ")
        ));
    }
    let mut skin = Skin {
        manifest,
        moodmap,
        bank: Bank {
            v: Value::Null,
            default: false,
        },
        atlases,
        voice,
        dir: None,
        notes,
    };
    for (md, e) in dropped {
        let face = skin.face(md).as_str();
        skin.notes
            .push(format!("skin {id}: {e}; {} wears {face}", md.as_str()));
    }

    let own = root
        .bytes(LINES)
        .and_then(|b| b.map(|b| lines(&b)).transpose());
    match (builtin, own) {
        (true, Ok(Some(v))) => skin.bank.v = v,
        (true, Ok(None)) => return Err(err(LINES, "missing")),
        (true, Err(e)) => return Err(err(LINES, e)),
        (false, Ok(Some(mut v))) => {
            let base = Skin::default().bank.v;
            v["status"] = deep(&base["status"], v.get("status"));
            skin.bank.v = v;
        }
        (false, own) => {
            let base = Skin::default();
            skin.bank = Bank {
                v: base.bank.v,
                default: true,
            };
            skin.voice = base.voice;
            if let Err(e) = own {
                skin.notes
                    .push(format!("skin {id}: {LINES}: {e}; using the default lines"));
            }
        }
    }
    Ok(skin)
}

/// moods/<mood>.json and .png, held to the mascot and the budget.
fn atlas(root: &Root, mood: Mood, mascot: &Mascot) -> Result<Atlas, SkinError> {
    let jf = format!("moods/{}.json", mood.as_str());
    let pf = format!("moods/{}.png", mood.as_str());
    let j = root
        .bytes(&jf)
        .map_err(|e| err(&jf, e))?
        .ok_or_else(|| err(&jf, "missing"))?;
    let j = object(&j).map_err(|e| err(&jf, e))?;
    let frames = whole(&j, "frames", &jf, "frames")?;
    let fps = whole(&j, "fps", &jf, "fps")?;
    let (w, h) = (whole(&j, "w", &jf, "w")?, whole(&j, "h", &jf, "h")?);
    let cols = whole(&j, "cols", &jf, "cols")?;
    let play = match j.get("play").map(|p| p.as_str()) {
        None | Some(Some("loop")) => Play::Loop,
        Some(Some("pingpong")) => Play::Pingpong,
        Some(_) => return Err(err(&jf, "play must be loop or pingpong")),
    };
    if u64::from(frames) > MAX_FRAMES {
        return Err(err(&jf, format!("{frames} frames, over {MAX_FRAMES}")));
    }
    for (side, px, of) in [("w", w, mascot.w), ("h", h, mascot.h)] {
        if px % mascot.scale != 0 || px / mascot.scale != of {
            return Err(err(
                &jf,
                format!(
                    "{side} / scale must be mascot.{side}: {px} / {} is not {of}",
                    mascot.scale
                ),
            ));
        }
    }
    let rows = frames.div_ceil(cols);

    let png = root.png(&pf).ok_or_else(|| err(&pf, "missing"))?;
    let len = png
        .len()
        .map_err(|e| err(&pf, format!("cannot be read: {e}")))?;
    if len > MAX_PNG_BYTES {
        return Err(err(
            &pf,
            format!("{len} bytes on disk, over {MAX_PNG_BYTES}"),
        ));
    }
    let head = png
        .head()
        .map_err(|e| err(&pf, format!("cannot be read: {e}")))?;
    let (sw, sh) = png_size(&head).ok_or_else(|| err(&pf, "not a PNG"))?;
    if sw > MAX_SHEET_PX || sh > MAX_SHEET_PX {
        return Err(err(
            &pf,
            format!("{sw}x{sh}, over {MAX_SHEET_PX}x{MAX_SHEET_PX}"),
        ));
    }
    if sw * sh * 4 > MAX_DECODED_BYTES {
        return Err(err(
            &pf,
            format!(
                "{sw}x{sh} is {} bytes decoded, over {MAX_DECODED_BYTES}",
                sw * sh * 4
            ),
        ));
    }
    let (ew, eh) = (
        u64::from(cols) * u64::from(w),
        u64::from(rows) * u64::from(h),
    );
    if (sw, sh) != (ew, eh) {
        return Err(err(
            &pf,
            format!("{sw}x{sh} is not {cols} x {w} by {rows} x {h} ({ew}x{eh})"),
        ));
    }
    Ok(Atlas {
        meta: AtlasMeta {
            frames,
            fps,
            w,
            h,
            cols,
            rows,
            play,
        },
        png,
    })
}

/// A PNG's width and height from its signature and IHDR; the pixels are
/// the animator's to decode.
fn png_size(head: &[u8]) -> Option<(u64, u64)> {
    if head.len() < 24 || head[..8] != *b"\x89PNG\r\n\x1a\n" || head[12..16] != *b"IHDR" {
        return None;
    }
    let be = |i: usize| u64::from(u32::from_be_bytes(head[i..i + 4].try_into().unwrap()));
    Some((be(16), be(20))).filter(|&(w, h)| w > 0 && h > 0)
}

/// moodmap.json, or an empty one where the pack has none.
fn moodmap(root: &Root, unknown: &mut BTreeSet<String>) -> Result<Moodmap, SkinError> {
    let Some(bytes) = root.bytes(MOODMAP).map_err(|e| err(MOODMAP, e))? else {
        return Ok(Moodmap::default());
    };
    let m = object(&bytes).map_err(|e| err(MOODMAP, e))?;
    let mut out = Moodmap::default();
    if let Some(s) = m.get("sections") {
        let s = s
            .as_object()
            .ok_or_else(|| err(MOODMAP, "sections must be an object"))?;
        for (k, v) in s {
            let v = v
                .as_str()
                .ok_or_else(|| err(MOODMAP, format!("sections.{k} must be a mood")))?;
            match Mood::parse(v) {
                Some(md) => {
                    out.sections.insert(k.clone(), md);
                }
                None => {
                    unknown.insert(v.to_string());
                }
            }
        }
    }
    if let Some(l) = m.get("locked") {
        out.locked = strings(Some(l))
            .ok_or_else(|| err(MOODMAP, "locked must be a list of section names"))?;
    }
    if let Some(p) = m.get("phrases") {
        let p = p
            .as_array()
            .ok_or_else(|| err(MOODMAP, "phrases must be a list"))?;
        for (i, ph) in p.iter().enumerate() {
            let mood = ph
                .get("mood")
                .and_then(Value::as_str)
                .ok_or_else(|| err(MOODMAP, format!("phrases[{i}].mood must be a mood")))?;
            let list = |k: &str| match ph.get(k) {
                None => Ok(Vec::new()),
                v => strings(v).ok_or_else(|| {
                    err(
                        MOODMAP,
                        format!("phrases[{i}].{k} must be a list of strings"),
                    )
                }),
            };
            let (matches, regex) = (list("match")?, list("regex")?);
            match Mood::parse(mood) {
                Some(mood) => out.phrases.push(Phrase {
                    mood,
                    matches,
                    regex,
                }),
                None => {
                    unknown.insert(mood.to_string());
                }
            }
        }
    }
    Ok(out)
}

/// lines.json, held to the rules the engine keys on: an object, its
/// `events` a list, every event with an `id`. `s` and every other key are
/// the writer's.
fn lines(bytes: &[u8]) -> Result<Value, String> {
    let m = object(bytes)?;
    if let Some(ev) = m.get("events") {
        let ev = ev.as_array().ok_or("events must be a list")?;
        for (i, e) in ev.iter().enumerate() {
            if !e
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|s| !s.is_empty())
            {
                return Err(format!("events[{i}] has no id"));
            }
        }
    }
    Ok(Value::Object(m))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A folder of its own for one test, beside the test exe (as
    /// selflog.rs's), emptied first.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("data")
            .join("skin-test")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A blank w x h PNG, 1 bit grey: a real sheet's header at a few
    /// hundred bytes.
    fn blank_png(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut e = png::Encoder::new(&mut out, w, h);
            e.set_color(png::ColorType::Grayscale);
            e.set_depth(png::BitDepth::One);
            let mut wr = e.write_header().unwrap();
            wr.write_image_data(&vec![0; w.div_ceil(8) as usize * h as usize])
                .unwrap();
            wr.finish().unwrap();
        }
        out
    }

    /// A vector's file as bytes: {"png": [w, h]} a blank sheet, {"bytes": n}
    /// n zeros, {"text": t} t itself, anything else its JSON.
    fn expand(v: &Value) -> Vec<u8> {
        if let Some(p) = v.get("png") {
            let n = |i: usize| p[i].as_u64().unwrap() as u32;
            return blank_png(n(0), n(1));
        }
        if let Some(n) = v.get("bytes").and_then(Value::as_u64) {
            return vec![0; n as usize];
        }
        if let Some(t) = v.get("text").and_then(Value::as_str) {
            return t.as_bytes().to_vec();
        }
        serde_json::to_vec_pretty(v).unwrap()
    }

    /// A pack's files written into <root>/skins/<folder>/.
    fn write_pack(root: &Path, folder: &str, files: &BTreeMap<String, Value>) -> PathBuf {
        let dir = root.join("skins").join(folder);
        for (rel, v) in files {
            let p = dir.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, expand(v)).unwrap();
        }
        dir
    }

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/skin-manifest.json");
        let text = std::fs::read_to_string(path).expect("native/vectors/skin-manifest.json");
        serde_json::from_str(&text).unwrap()
    }

    /// A case's pack: the file's base, `edit` laid on its JSON files key by
    /// key (null drops a key), `alsoMoods` copies of ready's atlas, `files`
    /// whole, then `drop` removed.
    fn case_files(base: &Value, input: &Value) -> BTreeMap<String, Value> {
        let mut files: BTreeMap<String, Value> = base
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (f, keys) in input["edit"].as_object().into_iter().flatten() {
            let o = files.get_mut(f).unwrap().as_object_mut().unwrap();
            for (k, v) in keys.as_object().unwrap() {
                if v.is_null() {
                    o.remove(k);
                } else {
                    o.insert(k.clone(), v.clone());
                }
            }
        }
        for md in input["alsoMoods"].as_array().into_iter().flatten() {
            let md = md.as_str().unwrap();
            for ext in ["json", "png"] {
                let v = files[&format!("moods/ready.{ext}")].clone();
                files.insert(format!("moods/{md}.{ext}"), v);
            }
        }
        for (f, v) in input["files"].as_object().into_iter().flatten() {
            files.insert(f.clone(), v.clone());
        }
        for f in input["drop"].as_array().into_iter().flatten() {
            files.remove(f.as_str().unwrap());
        }
        files
    }

    /// What a case's answer holds for a load.
    fn answer(got: &Result<Skin, SkinError>) -> Value {
        match got {
            Err(e) => serde_json::json!({ "ok": false, "error": e.to_string() }),
            Ok(s) => {
                let faces: Map<String, Value> = Mood::ALL
                    .iter()
                    .map(|m| (m.as_str().to_string(), s.face(*m).as_str().into()))
                    .collect();
                serde_json::json!({
                    "ok": true,
                    "id": s.id(),
                    "name": s.manifest.name,
                    "voice": s.voice(),
                    "moods": s.moods().map(Mood::as_str).collect::<Vec<_>>(),
                    "faces": faces,
                    "linesDefault": s.bank.default,
                    "notes": s.notes,
                })
            }
        }
    }

    /// Every case of skin-manifest.json: the synthetic pack written to a
    /// folder of its own and loaded as scan loads it, its answer the
    /// case's. All mismatches at once.
    #[test]
    fn every_manifest_vector_loads_as_its_answer() {
        let file = vectors();
        let cases = file["cases"].as_array().unwrap();
        assert!(cases.len() >= 30, "cases: {}", cases.len());
        let root = scratch("vectors");
        let mut bad = Vec::new();
        for (n, c) in cases.iter().enumerate() {
            let name = c["name"].as_str().unwrap();
            let input = &c["input"];
            let folder = input["folder"].as_str().unwrap_or("mini");
            let at = root.join(n.to_string());
            let dir = write_pack(&at, folder, &case_files(&file["base"], input));
            let got = answer(&load_dir(&dir, folder));
            if got != c["expect"] {
                bad.push(format!(
                    "'{name}':\n    want {}\n    got  {got}",
                    c["expect"]
                ));
            }
        }
        let _ = std::fs::remove_dir_all(&root);
        assert!(
            bad.is_empty(),
            "{} of {} differ\n{}",
            bad.len(),
            cases.len(),
            bad.join("\n")
        );
    }

    /// The built-in loads with no note, all seven moods its own, its lines
    /// its own: skins/default/ as make_default.py writes it.
    #[test]
    fn the_builtin_is_whole_and_quiet() {
        let s = Skin::default();
        assert_eq!(s.id(), "default");
        assert_eq!(s.voice(), "OVERLAY");
        assert!(s.notes.is_empty(), "{:?}", s.notes);
        assert!(!s.bank.default);
        assert_eq!(s.moods().collect::<Vec<_>>(), Mood::ALL);
        for m in Mood::ALL {
            assert_eq!(s.face(m), m);
            let a = s.atlas(m).unwrap();
            assert_eq!((a.meta.frames, a.meta.cols, a.meta.rows), (24, 6, 4));
            assert_eq!(a.meta.sheet(), (1920, 1024));
            assert!(matches!(a.png, Png::Builtin(_)));
            assert!(a.png.bytes().unwrap().starts_with(b"\x89PNG\r\n\x1a\n"));
        }
        assert_eq!(s.manifest.max_chars, 95);
        assert_eq!(
            s.bank.event("done").unwrap()["killer"][0],
            "{project} finished."
        );
        assert!(s.bank.get("conversations.habit.roast").is_none());
        assert!(s.bank.status()["opened"].is_string());
    }

    /// A folder with skin.json and idle and ready alone loads through
    /// scan and load: the default lines and voice, every other mood
    /// wearing ready (or idle, by its fallback), no note.
    #[test]
    fn a_minimal_pack_loads() {
        let data = scratch("minimal");
        let file = vectors();
        write_pack(&data, "mini", &case_files(&file["base"], &Value::Null));
        let s = load(&data, "mini").unwrap();
        assert!(s.notes.is_empty(), "{:?}", s.notes);
        assert_eq!(s.moods().collect::<Vec<_>>(), [Mood::Idle, Mood::Ready]);
        assert_eq!(s.face(Mood::Sad), Mood::Idle);
        assert_eq!(s.face(Mood::Angry), Mood::Ready);
        assert_eq!(
            s.atlas_for(Mood::Smug).meta,
            s.atlas(Mood::Ready).unwrap().meta
        );
        assert!(s.bank.default);
        assert_eq!(s.voice(), "OVERLAY");
        assert_eq!(
            s.dir.as_deref(),
            Some(data.join("skins").join("mini").as_path())
        );
        let list = scan(&data);
        let ids: Vec<&str> = list.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["default", "mini"]);
        assert!(list.iter().all(|p| p.broken.is_none()));
        let _ = std::fs::remove_dir_all(&data);
    }

    /// lines.json that does not parse: the pack's faces, the default
    /// lines and voice, and one note naming the file and the error.
    #[test]
    fn corrupt_lines_give_the_default_lines_and_one_note() {
        let data = scratch("corrupt-lines");
        let file = vectors();
        let input = serde_json::json!({
            "edit": { "skin.json": { "voice": "MINI" } },
            "files": { "lines.json": { "text": "{\"events\": [" } }
        });
        write_pack(&data, "mini", &case_files(&file["base"], &input));
        let s = load_or_default(&data, "mini");
        assert_eq!(s.id(), "mini");
        assert_eq!(s.notes.len(), 1, "{:?}", s.notes);
        assert!(
            s.notes[0].starts_with("skin mini: lines.json: does not parse: "),
            "{}",
            s.notes[0]
        );
        assert!(
            s.notes[0].ends_with("; using the default lines"),
            "{}",
            s.notes[0]
        );
        assert!(s.bank.default);
        assert_eq!(s.voice(), "OVERLAY");
        assert_eq!(s.manifest.voice, "MINI");
        assert_eq!(s.bank.value(), Skin::default().bank.value());
        assert_eq!(s.moods().collect::<Vec<_>>(), [Mood::Idle, Mood::Ready]);
        let _ = std::fs::remove_dir_all(&data);
    }

    /// 22 frames on a 5 x 5 grid: the last row short,
    /// the last frame at its start, the sheet 1600x1280 inside the budget.
    #[test]
    fn a_pack_with_frames_below_its_grid_loads() {
        let data = scratch("short-grid");
        let file = vectors();
        let input = serde_json::json!({
            "files": {
                "moods/ready.json": { "frames": 22, "fps": 12, "w": 320, "h": 256, "cols": 5, "play": "pingpong" },
                "moods/ready.png": { "png": [1600, 1280] }
            }
        });
        write_pack(&data, "mini", &case_files(&file["base"], &input));
        let s = load(&data, "mini").unwrap();
        let m = &s.atlas(Mood::Ready).unwrap().meta;
        assert_eq!(
            (m.frames, m.cols, m.rows, m.play),
            (22, 5, 5, Play::Pingpong)
        );
        assert_eq!(m.sheet(), (1600, 1280));
        assert_eq!(m.clip(21), [320, 1024, 320, 256]);
        assert_eq!(m.clip(4), [1280, 0, 320, 256]);
        let _ = std::fs::remove_dir_all(&data);
    }

    /// No skins/ folder at all: Default alone in the menu, and a saved id
    /// gives the built-in with one note.
    #[test]
    fn no_skins_folder_is_the_default_alone() {
        let data = scratch("no-skins");
        assert_eq!(
            scan(&data),
            [Pack {
                id: "default".into(),
                name: "Default".into(),
                version: "1.0.0".into(),
                broken: None
            }]
        );
        let s = load_or_default(&data, "gone");
        assert_eq!(s.id(), "default");
        assert_eq!(
            s.notes,
            ["skin gone: skins/gone: not found; using default"]
        );
        assert!(load_or_default(&data, "default").notes.is_empty());
        let _ = std::fs::remove_dir_all(&data);
    }

    /// Broken packs stay in the menu with their reason, sorted by name
    /// after Default; a dot folder is not a pack, and an id that would
    /// leave skins/ is refused before any path is made of it.
    #[test]
    fn scan_lists_broken_packs_with_their_reason() {
        let data = scratch("scan");
        let file = vectors();
        for (id, name) in [("zed", "Zed"), ("alpha", "alpha")] {
            let input = serde_json::json!({ "edit": { "skin.json": { "id": id, "name": name } } });
            write_pack(&data, id, &case_files(&file["base"], &input));
        }
        std::fs::create_dir_all(data.join("skins").join("empty")).unwrap();
        std::fs::create_dir_all(data.join("skins").join(".git")).unwrap();
        let list = scan(&data);
        let ids: Vec<&str> = list.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["default", "alpha", "empty", "zed"]);
        assert_eq!(
            list[2].broken.as_ref().unwrap().to_string(),
            "skin.json: missing"
        );
        assert_eq!(list[2].name, "empty");
        let e = load(&data, "../skins/alpha").unwrap_err();
        assert_eq!(
            e.to_string(),
            "skins/../skins/alpha: not a skin id ([a-z0-9-]+)"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// A pack's status lines laid over the default's: its own where it
    /// has them, the default's where it has none, so none goes missing.
    #[test]
    fn status_lines_fall_back_line_by_line() {
        let data = scratch("status");
        let file = vectors();
        let input = serde_json::json!({
            "files": { "lines.json": {
                "events": [{ "id": "done", "killer": ["Done."] }],
                "status": { "mood": "smug", "opened": "Opened it.", "lock": { "on": "Shut." } }
            } }
        });
        write_pack(&data, "mini", &case_files(&file["base"], &input));
        let s = load(&data, "mini").unwrap();
        let d = Skin::default();
        assert!(!s.bank.default);
        assert_eq!(s.bank.status()["mood"], "smug");
        assert_eq!(s.bank.status()["opened"], "Opened it.");
        assert_eq!(s.bank.status()["denied"], d.bank.status()["denied"]);
        assert_eq!(s.bank.status()["lock"]["on"], "Shut.");
        assert_eq!(
            s.bank.status()["lock"]["off"],
            d.bank.status()["lock"]["off"]
        );
        assert_eq!(s.bank.event("done").unwrap()["killer"][0], "Done.");
        assert!(s.bank.event("start").is_none());
        let _ = std::fs::remove_dir_all(&data);
    }
}
