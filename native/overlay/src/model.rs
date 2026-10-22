// The WPF overlay's rules, ported as they are so the Slint panel decides as
// it did: what a row's chip offers and when it shows, where the chip, the
// card and the bar of buttons go, how a drag of an edge counts rows, what a
// marker and the folded line say - each function named after the
// PowerShell one it ports (src/overlay-windows.ps1 unless said). Pure: the
// runtime (app.rs) and the drawing (scene.rs) call them.
//
// PowerShell's own ways are kept where they show: -eq and -in ignore case,
// [Math]::Round and [int] round half to even, a string's length is in UTF-16
// units, and a field is read as Get-ChatField reads it - any case.
// native/vectors/overlay-panel.json pins them (tests/vectors/overlay-panel.ps1);
// the tests below read it.

use crate::clock::{self, Wall};
use serde_json::{Value, json};

/// The middle dot the overlay joins its words with ($script:ChatqDot).
pub const DOT: &str = "\u{00B7}";
/// $script:ChatqEllipsis.
pub const ELLIPSIS: &str = "\u{2026}";

/// A field as Get-ChatField reads it: an object's property, in any case.
pub fn get<'a>(v: &'a Value, k: &str) -> Option<&'a Value> {
    let m = v.as_object()?;
    m.get(k).or_else(|| {
        m.iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(k))
            .map(|(_, x)| x)
    })
}

/// `[string]` of a field.
pub fn s(v: &Value, k: &str) -> String {
    clock::text(get(v, k))
}

/// `[int]` of a field: 0 for none; a number with a fraction rounds half
/// to even, a string reads as a number.
pub fn n(v: &Value, k: &str) -> i64 {
    match get(v, k) {
        Some(Value::Number(x)) => x
            .as_i64()
            .unwrap_or_else(|| x.as_f64().map_or(0, |f| f.round_ties_even() as i64)),
        Some(Value::String(t)) => t
            .trim()
            .parse::<f64>()
            .map_or(0, |f| f.round_ties_even() as i64),
        Some(Value::Bool(b)) => i64::from(*b),
        _ => 0,
    }
}

/// `[double]` of a field.
pub fn f(v: &Value, k: &str) -> f64 {
    match get(v, k) {
        Some(Value::Number(x)) => x.as_f64().unwrap_or(0.0),
        Some(Value::String(t)) => t.trim().parse().unwrap_or(0.0),
        Some(Value::Bool(b)) => f64::from(u8::from(*b)),
        _ => 0.0,
    }
}

/// Whether `if ($Row.x)` holds.
pub fn t(v: &Value, k: &str) -> bool {
    clock::truthy(get(v, k))
}

/// `@(field) | Where-Object { $_ }`: an array's items that hold, or a lone
/// value that does.
pub fn list<'a>(v: &'a Value, k: &str) -> Vec<&'a Value> {
    match get(v, k) {
        Some(Value::Array(a)) => a.iter().filter(|x| clock::truthy(Some(x))).collect(),
        Some(x) if clock::truthy(Some(x)) => vec![x],
        _ => Vec::new(),
    }
}

/// `-eq` between strings: any case.
pub fn eq(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b) || (!a.is_ascii() && a.to_lowercase() == b.to_lowercase())
}

/// `-in`.
pub fn is_in(a: &str, set: &[&str]) -> bool {
    set.iter().any(|b| eq(a, b))
}

fn units(s: &str) -> usize {
    s.encode_utf16().count()
}

fn round(x: f64) -> i64 {
    x.round_ties_even() as i64
}

/// `-replace '\s+', ' '`.
fn one_space(t: &str) -> String {
    let mut out = String::with_capacity(t.len());
    let mut gap = false;
    for c in t.chars() {
        if c.is_whitespace() {
            gap = true;
        } else {
            if gap {
                out.push(' ');
                gap = false;
            }
            out.push(c);
        }
    }
    if gap {
        out.push(' ');
    }
    out
}

/// Format-ChatTitle (src/core.ps1): one line, cut to -Width with '...'.
pub fn format_title(text: &str, width: usize) -> String {
    if text.is_empty() {
        return "(empty)".into();
    }
    let s = one_space(text);
    let t = s.trim();
    if units(t) > width {
        let cut: Vec<u16> = t.encode_utf16().take(width).collect();
        return format!("{}...", String::from_utf16_lossy(&cut).trim_end());
    }
    t.to_string()
}

/// Limit-ChatqText (src/phone-extras.ps1): at most -Max UTF-16 units,
/// never between an emoji's two halves.
pub fn limit_text(text: &str, max: i64, ellipsis: bool) -> String {
    let u: Vec<u16> = text.encode_utf16().collect();
    if u.len() as i64 <= max {
        return text.to_string();
    }
    let mut n = if ellipsis { max - 1 } else { max };
    if n > 0 && (0xD800..0xDC00).contains(&u[(n - 1) as usize]) {
        n -= 1;
    }
    let cut = String::from_utf16_lossy(&u[..n.max(0) as usize]);
    if ellipsis {
        format!("{}{ELLIPSIS}", cut.trim_end())
    } else {
        cut
    }
}

/// Format-ChatqAutoTitle (src/auto-continue.ps1).
pub fn auto_title(title: &str, max: i64) -> String {
    if units(title) as i64 <= max {
        return title.to_string();
    }
    limit_text(title, max - 1, false) + ELLIPSIS
}

/// Format-ChatRestartCause (src/host-work.ps1).
pub fn restart_cause(cause: &str) -> &'static str {
    if eq(cause, "oom") {
        "VS Code ran out of memory"
    } else if eq(cause, "crash") {
        "VS Code crashed"
    } else {
        "VS Code restarted"
    }
}

/// Format-ChatqAskHead (src/queue.ps1), from the snapshot's header.ask.
pub fn ask_head(ask: &Value, now_ms: i64, wall: Wall) -> String {
    let count = n(ask, "count");
    let r = n(ask, "restart");
    let at = clock::ask_at(clock::ms_of(get(ask, "resetsAt")), now_ms, wall);
    let limit = if at.is_empty() {
        "limit over".to_string()
    } else {
        format!("limit over at {at}")
    };
    if r <= 0 {
        return limit;
    }
    let went = restart_cause(&s(ask, "cause"));
    if r >= count {
        return went.into();
    }
    format!("{limit}, and {went}")
}

/// Format-ChatqAskCount (src/queue.ps1).
pub fn ask_count(ask: &Value) -> String {
    let count = n(ask, "count");
    let r = n(ask, "restart");
    let who = if r > 0 && r < count { "they" } else { "it" };
    format!(
        "{count} chat{} {who} cut off",
        if count != 1 { "s" } else { "" }
    )
}

/// Format-ChatqAskLeaveTip (src/queue.ps1).
pub fn ask_leave_tip(ask: &Value) -> &'static str {
    let count = n(ask, "count");
    let r = n(ask, "restart");
    if r <= 0 {
        return "Leave them as they are - their rows stay orange; Continue all in the console still continues them";
    }
    if r >= count {
        return "Leave them as they are - a chat a VS Code restart cut off is not offered again, and its row goes";
    }
    "Leave them as they are - the limit's keep their orange rows, which Continue all in the console still continues; those a VS Code restart cut off are not offered again, and their rows go"
}

/// Format-ChatOverlayReloadText (src/overlay-data.ps1).
pub fn reload_text(reload: &Value) -> String {
    let mut w = s(reload, "window");
    if w.is_empty() {
        w = "a VS Code window".into();
    }
    let say = s(reload, "say");
    if say.is_empty() {
        format!("{w} needs a reload")
    } else {
        format!("{w} needs a reload - {say}")
    }
}

/// One of the chip's actions (Get-ChatOverlayChipActions).
#[derive(Clone, Debug, PartialEq)]
pub struct Action {
    pub id: &'static str,
    pub label: String,
    pub tip: String,
    pub disabled: bool,
}

fn action(id: &'static str, label: &str, tip: String) -> Action {
    Action {
        id,
        label: label.into(),
        tip,
        disabled: false,
    }
}

fn is_guid(t: &str) -> bool {
    let b = t.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

/// Test-ChatOverlayRowOpenable: a Claude chat, by its id, in a folder.
pub fn row_openable(row: &Value) -> bool {
    row.is_object()
        && eq(&s(row, "provider"), "claude")
        && is_guid(&s(row, "sessionId"))
        && !s(row, "cwd").is_empty()
}

/// Test-ChatOverlayRowDeletable (src/overlay-host.ps1).
pub fn row_deletable(row: &Value) -> bool {
    if !eq(&s(row, "kind"), "session") {
        return true;
    }
    !is_in(&s(row, "status"), &["busy", "waiting"])
        && !is_in(&s(row, "where"), &["terminal", "run"])
}

/// Get-ChatOverlayChipActions: what the chip offers for a row, left to
/// right.
pub fn chip_actions(row: &Value) -> Vec<Action> {
    if !row.is_object() {
        return Vec::new();
    }
    let kind = s(row, "kind");
    if eq(&kind, "reload") {
        let mut w = s(row, "window");
        if w.is_empty() {
            w = "the VS Code window".into();
        }
        let anyway = eq(&s(row, "state"), "anyway");
        return vec![
            action(
                "reload-go",
                if anyway { "reload anyway" } else { "reload" },
                if anyway {
                    format!(
                        "Reload {w} now, as its Reload anyway does - a chat working there stops."
                    )
                } else {
                    format!("Reload {w} now, as its notice's Reload does.")
                },
            ),
            action(
                "reload-later",
                "later",
                format!("Take this off the overlay - the notice stays in {w}, to answer there."),
            ),
        ];
    }
    if eq(&kind, "ask") {
        let count = n(row, "count");
        let r = n(row, "restart");
        let titles: Vec<String> = list(row, "titles")
            .into_iter()
            .map(|x| clock::text(Some(x)))
            .collect();
        let go = if r <= 0 {
            format!(
                "Queue \"Continue from where you left off.\" for each of the {count} chats the limit cut off"
            )
        } else if r >= count {
            format!(
                "Queue a continue for each of the {count} chats a VS Code restart cut off, saying what it ended"
            )
        } else {
            format!(
                "Queue a continue for each of the {count} chats the limit or a VS Code restart cut off"
            )
        };
        return vec![
            action(
                "ask-go",
                &format!("continue {count}"),
                format!("{go}, to go one at a time: {}", titles.join(", ")),
            ),
            action(
                "ask-leave",
                "leave them",
                ask_leave_tip(&json!({ "count": count, "restart": r })).into(),
            ),
        ];
    }
    let mut out = Vec::new();
    let a = get(row, "auto").filter(|x| clock::truthy(Some(x)));
    let none = Value::Null;
    let av = a.unwrap_or(&none);
    let st = s(av, "state");
    let long = s(av, "long");
    let title = auto_title(&s(row, "title"), 40);
    let ov = a.is_some() && eq(&s(av, "cutWhy"), "overloaded");
    let lead = if long.is_empty() {
        String::new()
    } else {
        format!("{long}. ")
    };
    if a.is_some() && is_in(&st, &["armed", "due"]) {
        out.push(action(
            "dont",
            "don't continue",
            if ov {
                format!(
                    "{lead}Don't send \"continue\" to this chat for this 529. The next time it is cut off, it is continued again - chatq '{title}' -AutoContinue never stops that."
                )
            } else {
                format!(
                    "{lead}Don't send \"continue\" to this chat after this reset. The next time the limit cuts it off, it is continued again - chatq '{title}' -AutoContinue never stops that."
                )
            },
        ));
    } else if a.is_some()
        && is_in(
            &st,
            &[
                "off", "never", "declined", "failed", "stopped", "far", "late", "ready",
            ],
        )
    {
        out.push(action(
            "continue",
            "continue",
            format!(
                "{lead}Queue \"Continue from where you left off.\" for this chat - it goes when {}.",
                if ov { "Claude is back" } else { "the limit is over" }
            ),
        ));
    }
    if row_openable(row) {
        let job = get(row, "job").filter(|x| clock::truthy(Some(x)));
        if job.is_some_and(|j| eq(&s(j, "state"), "running")) {
            out.push(action(
                "open",
                "watch",
                "A queued prompt is running in this chat - watch it live in its VS Code window."
                    .into(),
            ));
        } else {
            out.push(action(
                "open",
                "open",
                "Open this chat as a tab in its VS Code window - or bring forward the tab already showing it."
                    .into(),
            ));
        }
        if row_deletable(row) {
            out.push(action(
                "delete",
                "delete",
                "Delete this chat for good, as chatrm does - click once more to be sure.".into(),
            ));
        } else {
            out.push(Action {
                disabled: true,
                ..action(
                    "delete",
                    "delete",
                    "Not while this chat works or waits on you, or while a terminal or a queued prompt has it open."
                        .into(),
                )
            });
        }
    }
    out
}

/// Test-ChatOverlayDeleteArmed: a click on delete is the second it asks
/// for - the first, on the same row, under `ms` ago.
pub fn delete_armed(
    armed_key: &str,
    armed_at: Option<i64>,
    key: &str,
    now_ms: i64,
    ms: i64,
) -> bool {
    !armed_key.is_empty() && eq(armed_key, key) && armed_at.is_some_and(|at| now_ms - at < ms)
}

/// Test-ChatOverlayChipPressCounts, with Get-ChatConsoleSince's wrap.
pub fn press_counts(shown_tick: Option<i64>, press_tick: i64, ms: i64) -> bool {
    let Some(shown) = shown_tick else {
        return false;
    };
    let mut d = press_tick - shown;
    if d < 0 {
        d += 4_294_967_296;
    }
    d >= ms && d < 2_147_483_648
}

/// Get-ChatOverlayChipTarget: which row the chip shows for, '' for none.
#[allow(clippy::too_many_arguments)]
pub fn chip_target(
    shown: &str,
    under: &str,
    rested_ms: f64,
    on_chip: bool,
    since_over_ms: f64,
    down: bool,
    blocked: bool,
    spent: &str,
    delay_ms: f64,
) -> String {
    if blocked {
        return String::new();
    }
    if !shown.is_empty() {
        if on_chip || eq(under, shown) {
            return shown.into();
        }
        if !under.is_empty() {
            return String::new();
        }
        if since_over_ms < 300.0 {
            return shown.into();
        }
        return String::new();
    }
    if !under.is_empty() && !eq(under, spent) && !down && rested_ms >= delay_ms {
        return under.into();
    }
    String::new()
}

/// The chip's bookkeeping between pointer checks (the host's Chip* keys).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChipState {
    pub under: String,
    pub under_at: Option<i64>,
    pub last_pos: String,
    /// the row the chip shows for, '' for none
    pub key: String,
    pub over_at: Option<i64>,
    pub spent: String,
    pub armed: bool,
}

/// Step-ChatOverlayChipState: one pointer check's bookkeeping.
pub fn step(st: &mut ChipState, under: &str, pos: &str, on_chip: bool, now: i64) {
    let moved = !eq(pos, &st.last_pos);
    if !eq(under, &st.under) {
        st.under = under.into();
        st.under_at = (!under.is_empty() && moved).then_some(now);
    } else if !under.is_empty() && st.under_at.is_none() && moved {
        st.under_at = Some(now);
    }
    st.last_pos = pos.into();
    if !st.key.is_empty() && (on_chip || eq(under, &st.key)) {
        st.over_at = Some(now);
    }
    if !st.spent.is_empty() && !eq(under, &st.spent) {
        st.spent.clear();
    }
    if !st.key.is_empty() && !on_chip {
        st.armed = true;
    }
}

/// A rect in screen pixels: x, y, width, height.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Rect { x, y, w, h }
    }
    pub fn right(&self) -> i32 {
        self.x + self.w
    }
    pub fn bottom(&self) -> i32 {
        self.y + self.h
    }
    /// Test-ChatOverlayPointerIn.
    pub fn holds(&self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }
}

/// Test-ChatOverlayCardLeft: the card on the panel's left - the side with
/// more of its screen, the left on a tie.
pub fn card_left(panel: Rect, screen: Rect) -> bool {
    (panel.x - screen.x) >= (screen.right() - panel.right())
}

/// Get-ChatOverlayChipLayout's answer: the chip window's corner and each
/// part's offset in it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChipAt {
    pub x: i32,
    pub y: i32,
    pub icons_at: Option<(i32, i32)>,
    pub words_at: Option<(i32, i32)>,
    pub name_at: Option<(i32, i32)>,
    pub left: bool,
    pub out: i32,
}

/// Get-ChatOverlayChipLayout: where the chip's parts go.
#[allow(clippy::too_many_arguments)]
pub fn chip_layout(
    row: Rect,
    line: Rect,
    icons: (i32, i32),
    words: (i32, i32),
    screen: Rect,
    name: &[Rect],
    panel: Option<Rect>,
    gap: i32,
    words_x: Option<i32>,
) -> Option<ChipAt> {
    let panel = panel.unwrap_or(row);
    let left = card_left(panel, screen);
    // (x, y, w, h, which): 0 name, 1 icons, 2 words
    let mut parts: Vec<(i32, i32, i32, i32, u8)> = Vec::new();
    let nr: Vec<&Rect> = name.iter().filter(|r| r.w > 0).collect();
    if !nr.is_empty() {
        let nx = nr.iter().map(|r| r.x).min().unwrap();
        let ny = nr.iter().map(|r| r.y).min().unwrap();
        let rx = nr.iter().map(|r| r.right()).max().unwrap();
        let by = nr.iter().map(|r| r.bottom()).max().unwrap();
        parts.push((nx, ny, rx - nx, by - ny, 0));
    }
    if icons.0 > 0 {
        let right = if nr.is_empty() {
            row.right()
        } else {
            parts[0].0 + parts[0].2
        };
        parts.push((
            right - gap - icons.0,
            row.y + round(f64::from(row.h - icons.1) / 2.0) as i32,
            icons.0,
            icons.1,
            1,
        ));
    }
    let mut out = 0;
    if words.0 > 0 {
        let x = words_x.unwrap_or(if left {
            panel.x - gap - words.0
        } else {
            panel.right() + gap
        });
        parts.push((
            x,
            line.y + round(f64::from(line.h - words.1) / 2.0) as i32,
            words.0,
            words.1,
            2,
        ));
        out = if words_x.is_none() {
            gap + words.0
        } else if left {
            0
        } else {
            (x + words.0 - panel.right()).max(0)
        };
    }
    if left && let Some(ic) = parts.iter().find(|p| p.4 == 1) {
        out = out.max(panel.x - ic.0);
    }
    if parts.is_empty() {
        return None;
    }
    let x = screen.x.max(parts.iter().map(|p| p.0).min().unwrap());
    let y = screen.y.max(parts.iter().map(|p| p.1).min().unwrap());
    let mut at = ChipAt {
        x,
        y,
        left,
        out,
        ..ChipAt::default()
    };
    for p in &parts {
        let off = Some((p.0 - x, p.1 - y));
        match p.4 {
            0 => at.name_at = off,
            1 => at.icons_at = off,
            _ => at.words_at = off,
        }
    }
    Some(at)
}

/// Get-ChatOverlayCardPlacement's answer.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CardAt {
    pub x: i32,
    pub y: i32,
    pub left: bool,
    pub below: bool,
    pub above: bool,
    pub tip_x: i32,
}

/// Get-ChatOverlayCardPlacement: the card beside the panel, level with its
/// row - or, `below`, under a usage gauge, over it where the screen's foot
/// leaves no room.
pub fn card_placement(
    panel: Rect,
    row: Rect,
    size: (i32, i32),
    screen: Rect,
    gap: i32,
    push: i32,
    below: bool,
) -> CardAt {
    if below {
        let mid = f64::from(row.x) + f64::from(row.w) / 2.0;
        let x = screen
            .x
            .max((round(mid - f64::from(size.0) / 2.0) as i32).min(screen.right() - size.0));
        let y = row.bottom() + gap;
        let above = y + size.1 > screen.bottom() && row.y - gap - size.1 >= screen.y;
        let y = if above {
            row.y - gap - size.1
        } else {
            screen.y.max(y.min(screen.bottom() - size.1))
        };
        return CardAt {
            x,
            y,
            left: false,
            below: true,
            above,
            tip_x: round(mid - f64::from(x)) as i32,
        };
    }
    let left = card_left(panel, screen);
    let x = if left {
        panel.x - gap - push - size.0
    } else {
        panel.right() + gap + push
    };
    let x = screen.x.max(x.min(screen.right() - size.0));
    let y = screen.y.max(row.y.min(screen.bottom() - size.1));
    CardAt {
        x,
        y,
        left,
        below: false,
        above: false,
        tip_x: 0,
    }
}

/// $script:ChatOverlayCardWidth, Tail, Gap.
pub const CARD_WIDTH: f64 = 330.0;
pub const CARD_TAIL: f64 = 7.0;
pub const CARD_GAP: i32 = 5;

fn num(v: f64) -> String {
    // a path's numbers, short and exact enough
    let r = (v * 1000.0).round() / 1000.0;
    if r == r.trunc() {
        format!("{}", r as i64)
    } else {
        format!("{r}")
    }
}

/// Set-ChatOverlayCardShape: the card's outline - its rounded body and the
/// tail from the side that faces the panel, tip `tip` units along it - as
/// one path: WPF drew the union of the two, whose outline this traces, the
/// tail's two sides from where they cross the body's edge. Returns the
/// path and the tip as drawn; None for no height.
pub fn card_shape(
    left: bool,
    tip: f64,
    height: f64,
    below: bool,
    above: bool,
) -> Option<(String, f64)> {
    if height <= 0.0 {
        return None;
    }
    let (w, tl, rad, half) = (CARD_WIDTH, CARD_TAIL, 8.0, 6.0);
    // the tail's base is 2 units inside the body: its sides cross the
    // body's edge 2/9 of the way to the tip
    let hw = half * tl / (tl + 2.0);
    let arc = |x: f64, y: f64| format!("A {r} {r} 0 0 1 {} {}", num(x), num(y), r = num(rad));
    if below {
        let x = (rad + half).max(tip.min(w - rad - half)).round_ties_even();
        let top = if above { 0.0 } else { tl };
        let (l, r, t) = (0.5, w - 0.5, top + 0.5);
        let b = t + (height - tl - 1.0).max(1.0);
        let mut p = format!("M {} {} ", num(l + rad), num(t));
        if above {
            p += &format!(
                "H {} {} V {} {} ",
                num(r - rad),
                arc(r, t + rad),
                num(b - rad),
                arc(r - rad, b)
            );
            p += &format!(
                "H {} L {} {} L {} {} H {} ",
                num(x + hw),
                num(x),
                num(height - 0.5),
                num(x - hw),
                num(b),
                num(l + rad)
            );
            p += &format!(
                "{} V {} {} Z",
                arc(l, b - rad),
                num(t + rad),
                arc(l + rad, t)
            );
        } else {
            p += &format!(
                "H {} L {} {} L {} {} H {} ",
                num(x - hw),
                num(x),
                num(0.5),
                num(x + hw),
                num(t),
                num(r - rad)
            );
            p += &format!(
                "{} V {} {} H {} ",
                arc(r, t + rad),
                num(b - rad),
                arc(r - rad, b),
                num(l + rad)
            );
            p += &format!(
                "{} V {} {} Z",
                arc(l, b - rad),
                num(t + rad),
                arc(l + rad, t)
            );
        }
        return Some((p, x));
    }
    let y = if height < 2.0 * (rad + half) {
        height / 2.0
    } else {
        (rad + half).max(tip.min(height - rad - half))
    }
    .round_ties_even();
    let x0 = if left { 0.0 } else { tl };
    let (l, r, t, b) = (x0 + 0.5, x0 + w - 0.5, 0.5, height - 0.5);
    let tipx = if left { w + tl - 0.5 } else { 0.5 };
    let mut p = format!(
        "M {} {} H {} {} ",
        num(l + rad),
        num(t),
        num(r - rad),
        arc(r, t + rad)
    );
    if left {
        p += &format!(
            "V {} L {} {} L {} {} ",
            num(y - hw),
            num(tipx),
            num(y),
            num(r),
            num(y + hw)
        );
    }
    p += &format!(
        "V {} {} H {} {} ",
        num(b - rad),
        arc(r - rad, b),
        num(l + rad),
        arc(l, b - rad)
    );
    if !left {
        p += &format!(
            "V {} L {} {} L {} {} ",
            num(y + hw),
            num(tipx),
            num(y),
            num(l),
            num(y - hw)
        );
    }
    p += &format!("V {} {} Z", num(t + rad), arc(l + rad, t));
    Some((p, y))
}

/// Get-ChatOverlayControlsPlacement's answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CtlAt {
    pub x: i32,
    pub y: i32,
    pub below: bool,
    pub left: bool,
}

/// Get-ChatOverlayControlsPlacement: the bar of buttons in the panel's top
/// strip, the settings box over it or under it, as there is room.
#[allow(clippy::too_many_arguments)]
pub fn controls_placement(
    panel: Rect,
    size: (i32, i32),
    screen: Rect,
    gap: i32,
    prefer_below: bool,
    bar: i32,
    bx: i32,
    inset: i32,
    indent: i32,
) -> CtlAt {
    let top = panel.y + inset;
    let room_above = panel.y - gap - screen.y;
    let room_below = screen.bottom() - (top + bar + gap);
    let fits_above = room_above >= bx;
    let fits_below = room_below >= bx;
    let below = if !fits_above && !fits_below {
        room_below > room_above
    } else if prefer_below {
        fits_below
    } else {
        !fits_above
    };
    let y = if !below && bx > 0 {
        panel.y - gap - bx
    } else {
        top
    };
    let mut x = panel.right() - indent - size.0;
    let mut left = false;
    if x < screen.x {
        x = panel.x + indent;
        left = true;
    }
    CtlAt { x, y, below, left }
}

/// Get-ChatOverlayControlsShown: whether the edges show.
pub fn controls_shown(
    shown: bool,
    on_panel: bool,
    on_controls: bool,
    dragging: bool,
    down: bool,
    rested_ms: f64,
    since_over_ms: f64,
) -> bool {
    if dragging {
        return true;
    }
    if !shown {
        return !down && (on_panel || on_controls) && rested_ms >= 350.0;
    }
    on_panel || on_controls || down || since_over_ms < 700.0
}

/// Get-ChatOverlayResize's answer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Resize {
    pub rows: i64,
    pub recent: i64,
    pub steps: i64,
    pub recent_steps: i64,
    pub grow: f64,
}

/// What a drag of an edge asks for (Get-ChatOverlayResize's parameters).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Drag {
    pub rows: i64,
    pub dy: f64,
    pub row_height: f64,
    pub scale: f64,
    pub collapsed: bool,
    pub kept: i64,
    /// 's' the foot, 'n' the top
    pub top: bool,
    pub open: i64,
    pub recent_drawn: i64,
    pub recent_pool: i64,
    pub recent_kept: i64,
    pub recent_height: f64,
    pub head_height: f64,
}

impl Default for Drag {
    fn default() -> Self {
        Drag {
            rows: 1,
            dy: 0.0,
            row_height: 0.0,
            scale: 1.0,
            collapsed: false,
            kept: 0,
            top: false,
            open: 30,
            recent_drawn: 0,
            recent_pool: 0,
            recent_kept: -1,
            recent_height: 0.0,
            head_height: 0.0,
        }
    }
}

/// Get-ChatOverlayResize: the rows, then the Recent lines, a drag of an
/// edge comes to.
pub fn resize(d: &Drag) -> Resize {
    let scale = if d.scale <= 0.0 { 1.0 } else { d.scale };
    let rh = if d.row_height > 0.0 {
        d.row_height
    } else {
        42.0 * scale
    };
    let lh = if d.recent_height > 0.0 {
        d.recent_height
    } else {
        20.0 * scale
    };
    let down = if d.collapsed {
        0.0
    } else if d.top {
        -d.dy
    } else {
        d.dy
    };
    let hidden = (d.open.min(30) - d.rows).max(0);
    let have = (d.recent_pool.min(20) - d.recent_drawn).max(0);
    let (mut steps, mut lines) = (0i64, 0i64);
    if down > 0.0 {
        steps = hidden.min((down / rh).trunc() as i64);
        if steps == hidden {
            lines = have.min(((down - hidden as f64 * rh) / lh).trunc() as i64);
        }
    } else if down < 0.0 {
        lines = -(d.recent_drawn.min((-down / lh).trunc() as i64));
        if -lines == d.recent_drawn {
            steps = -((d.rows.min(d.open) - 1)
                .max(0)
                .min(((-down - d.recent_drawn as f64 * lh) / rh).trunc() as i64));
        }
    }
    let mut rows = (d.rows + steps).clamp(1, 30);
    if d.kept > 0 {
        if steps == 0 {
            rows = d.kept;
        } else if steps > 0 {
            rows = rows.max(d.kept);
        }
    }
    let mut recent = (d.recent_drawn + lines).clamp(0, 20);
    if d.recent_kept >= 0 {
        if lines == 0 {
            recent = d.recent_kept;
        } else if lines > 0 {
            recent = recent.max(d.recent_kept);
        }
    }
    let head = if d.recent_drawn == 0 && lines > 0 {
        d.head_height
    } else if d.recent_drawn > 0 && d.recent_drawn + lines == 0 {
        -d.head_height
    } else {
        0.0
    };
    Resize {
        rows,
        recent,
        steps,
        recent_steps: lines,
        grow: (steps as f64 * rh + lines as f64 * lh + head) / scale,
    }
}

/// Get-ChatOverlayHeightCap: the panel's MaxHeight in units - down to the
/// working area's foot from its top, or, `bottom` held (a drag of the top
/// edge), up from there to the area's top - never under `floor`.
pub fn height_cap(top: i32, area: Rect, scale: f64, floor: f64, bottom: Option<i32>) -> f64 {
    let scale = if scale <= 0.0 { 1.0 } else { scale };
    let room = match bottom {
        Some(b) => (f64::from(b - area.y) / scale).floor(),
        None => (f64::from(area.bottom() - top) / scale).floor(),
    };
    floor.ceil().max(room)
}

/// Get-ChatOverlayPlacement: where it was left while a 48 x 24 corner of
/// it shows on some screen, else the main screen's top right.
pub fn placement(
    at: Option<(i32, i32)>,
    w: i32,
    h: i32,
    screens: &[(Rect, bool)],
) -> (i32, i32, bool) {
    if let Some((x, y)) = at {
        for (s, _) in screens {
            let vw = (x + w).min(s.right()) - x.max(s.x);
            let vh = (y + h).min(s.bottom()) - y.max(s.y);
            if vw >= 48 && vh >= 24 {
                return (x, y, false);
            }
        }
    }
    let p = screens
        .iter()
        .find(|(_, primary)| *primary)
        .or(screens.first());
    match p {
        None => (0, 0, true),
        Some((p, _)) => (p.right() - w - 16, p.y + 16, true),
    }
}

/// Get-ChatOverlayEdgesRect.
pub fn edges_rect(panel: Rect, out: i32) -> Rect {
    Rect::new(
        panel.x - out,
        panel.y - out,
        panel.w + 2 * out,
        panel.h + 2 * out,
    )
}

/// Get-ChatOverlayRaisePlan: by folder or by name, seconds to look again,
/// and the code whose words are said once in front.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RaisePlan {
    pub by_name: bool,
    pub seconds: i64,
    pub words: i64,
}

pub fn raise_plan(code: i64) -> Option<RaisePlan> {
    let p = |by_name, seconds, words| {
        Some(RaisePlan {
            by_name,
            seconds,
            words,
        })
    };
    match code {
        0 | 10 | 16 | 21 => p(false, 5, code),
        40 | 41 => p(false, 0, 0),
        42 | 43 => p(false, 0, 21),
        25 => p(true, 0, 0),
        26 => p(true, 0, 21),
        _ => None,
    }
}

fn ends_ci(s: &str, tail: &str) -> bool {
    s.len() >= tail.len()
        && s.is_char_boundary(s.len() - tail.len())
        && eq(&s[s.len() - tail.len()..], tail)
}

/// `-replace '\s+-\s+Visual Studio Code( - Insiders)?(\s*\[[^\]]*\])?\s*$', ''`.
fn strip_code_name(title: &str) -> String {
    let mut s = title.trim_end();
    if s.ends_with(']')
        && let Some(open) = s.rfind('[')
        && !s[open + 1..s.len() - 1].contains(']')
    {
        s = s[..open].trim_end();
    }
    let rest = if ends_ci(s, "Visual Studio Code - Insiders") {
        &s[..s.len() - "Visual Studio Code - Insiders".len()]
    } else if ends_ci(s, "Visual Studio Code") {
        &s[..s.len() - "Visual Studio Code".len()]
    } else {
        return title.to_string();
    };
    // \s+-\s+ before it
    let r = rest.trim_end();
    if r.len() == rest.len() || !r.ends_with('-') {
        return title.to_string();
    }
    let before = &r[..r.len() - 1];
    let head = before.trim_end();
    if head.len() == before.len() {
        return title.to_string();
    }
    head.to_string()
}

/// Test-ChatWindowTitleOn (src/live-chats.ps1): a VS Code window's title
/// names `root` last before VS Code's own name, or before a profile's.
pub fn title_on(title: &str, root: &str, profiles: &[String]) -> bool {
    if root.is_empty() {
        return false;
    }
    let s = strip_code_name(title).trim().to_string();
    let mut cut = vec![s.clone()];
    for p in profiles.iter().filter(|p| !p.is_empty()) {
        if ends_ci(&s, &format!(" - {p}")) {
            cut.push(s[..s.len() - p.len() - 3].to_string());
        }
    }
    cut.iter()
        .any(|c| eq(c, root) || ends_ci(c, &format!(" - {root}")))
}

/// Select-ChatCodeWindow (src/live-chats.ps1): the one window for a chat,
/// by its folder's name or by the name its tab file gives; None for none
/// or more than one.
pub fn select_window(
    cwd: &str,
    windows: &[(isize, String)],
    profiles: &[String],
    name: &str,
) -> Option<isize> {
    let roots: Vec<String> = if !name.is_empty() {
        vec![format!("{name} (Workspace)"), name.to_string()]
    } else {
        let t = cwd.trim_end_matches(['\\', '/']);
        let leaf = t.rsplit(['\\', '/']).next().unwrap_or("");
        if leaf.is_empty() {
            Vec::new()
        } else {
            vec![leaf.to_string()]
        }
    };
    if roots.is_empty() {
        return None;
    }
    let hits: Vec<isize> = windows
        .iter()
        .filter(|(h, _)| *h != 0)
        .filter(|(_, title)| roots.iter().any(|r| title_on(title, r, profiles)))
        .map(|(h, _)| *h)
        .collect();
    (hits.len() == 1).then(|| hits[0])
}

/// ConvertFrom-ChatOverlayHotkey (src/overlay.ps1): RegisterHotKey's
/// modifiers and key; None for none; Err with the words it throws.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hotkey {
    pub mods: u32,
    pub vk: u32,
    pub text: String,
}

pub fn parse_hotkey(text: &str) -> Result<Option<Hotkey>, String> {
    let t = text.trim();
    if t.is_empty() || eq(t, "none") {
        return Ok(None);
    }
    let (mut mods, mut vk) = (0u32, None);
    for p in t.split('+').map(str::trim) {
        let l = p.to_ascii_lowercase();
        if l == "ctrl" || l == "control" {
            mods |= 2;
        } else if l == "alt" {
            mods |= 1;
        } else if l == "shift" {
            mods |= 4;
        } else if l == "win" || l == "windows" {
            mods |= 8;
        } else if let Some(k) = l
            .strip_prefix('f')
            .filter(|d| {
                !d.is_empty()
                    && d.len() <= 2
                    && d.bytes().all(|b| b.is_ascii_digit())
                    && !d.starts_with('0')
            })
            .and_then(|d| d.parse::<u32>().ok())
            .filter(|k| (1..=24).contains(k))
        {
            vk = Some(0x6F + k);
        } else if l.len() == 1 && l.as_bytes()[0].is_ascii_lowercase() {
            vk = Some(u32::from(l.as_bytes()[0].to_ascii_uppercase()));
        } else if l.len() == 1 && l.as_bytes()[0].is_ascii_digit() {
            vk = Some(0x30 + u32::from(l.as_bytes()[0] - b'0'));
        } else {
            return Err(format!(
                "cannot read '{p}' in hotkey '{t}' - use e.g. Ctrl+Alt+Shift+O, Ctrl+Win+F9 or none"
            ));
        }
    }
    let Some(vk) = vk else {
        return Err(format!("hotkey '{t}' names no key - e.g. Ctrl+Alt+Shift+O"));
    };
    if mods == 0 {
        return Err(format!(
            "hotkey '{t}' needs Ctrl, Alt, Shift or Win with the key"
        ));
    }
    Ok(Some(Hotkey {
        mods,
        vk,
        text: t.to_string(),
    }))
}

/// Get-ChatOverlayRowClock (src/overlay-data.ps1): what a row's clock
/// counts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ClockSpec {
    pub from: Option<i64>,
    pub to: Option<i64>,
    pub hold: bool,
    pub live: bool,
}

pub fn row_clock(row: &Value) -> ClockSpec {
    let st = s(row, "status");
    let ms = |k: &str| {
        get(row, k)
            .filter(|x| clock::truthy(Some(x)))
            .and_then(|x| clock::ms_of(Some(x)))
    };
    let mut from = ms("since");
    let mut to = None;
    if eq(&st, "queued") {
        from = None;
        to = ms("sendAt");
    } else if eq(&st, "cutoff") {
        to = ms("resetsAt");
    }
    ClockSpec {
        from,
        to,
        hold: eq(&st, "queued"),
        live: false,
    }
}

/// Format-ChatOverlayRowClock (src/overlay-data.ps1): a row clock's five
/// characters at `now_ms`.
pub fn format_row_clock(spec: &ClockSpec, now_ms: i64) -> String {
    let (down, ms) = match spec.to {
        Some(to) if to > now_ms => (true, to - now_ms),
        _ => match spec.from {
            Some(from) if !spec.hold => (false, now_ms - from),
            _ => return "--:--".into(),
        },
    };
    let sec = ms.max(0) / 1000;
    let (hi, lo, sep) = if spec.live && sec < 3600 {
        (sec / 60, sec % 60, ':')
    } else {
        let min = if down { (sec + 59) / 60 } else { sec / 60 };
        if min < 6000 {
            (min / 60, min % 60, 'h')
        } else {
            let hrs = min / 60;
            ((hrs / 24).min(99), hrs % 24, 'd')
        }
    };
    let head = if hi >= 10 {
        format!("{hi:02}")
    } else if down {
        format!("-{hi}")
    } else {
        format!(" {hi}")
    };
    format!("{head}{sep}{lo:02}")
}

/// Get-ChatOverlayRowWords: what a row says past its tile.
pub fn row_words(row: &Value) -> String {
    if eq(&s(row, "kind"), "recent") {
        return s(row, "stateText");
    }
    let mut w = s(row, "stateWords");
    if w.is_empty() {
        w = s(row, "stateText");
    }
    let plain = ["idle", "working", "running", "needs you"];
    if is_in(&w, &plain) {
        return String::new();
    }
    let sep = format!(" {DOT} ");
    if let Some(i) = w.rfind(&sep)
        && i > 0
        && is_in(&w[i + sep.len()..], &plain)
    {
        return w[..i].to_string();
    }
    w
}

/// Get-ChatOverlayCardWords: a chat's words for its card, unless the
/// card's state line (`what`) says them already.
pub fn card_words(row: &Value, what: &str) -> String {
    if eq(&s(row, "kind"), "recent") {
        return String::new();
    }
    let w = row_words(row);
    if w.is_empty() || (!what.is_empty() && (w.contains(what) || what.contains(&w))) {
        return String::new();
    }
    w
}

/// `-like` with a lone '*' at either end or both, any case.
fn like(text: &str, pat: &str) -> bool {
    let t = text.to_lowercase();
    let p = pat.to_lowercase();
    match (p.strip_prefix('*'), p.strip_suffix('*')) {
        (Some(_), Some(_)) if p.len() >= 2 => t.contains(&p[1..p.len() - 1]),
        (Some(tail), _) => t.ends_with(tail),
        (_, Some(head)) => t.starts_with(head),
        _ => t == p,
    }
}

/// Get-ChatOverlayNoteNotice: one of the header's notes as its marker's
/// row, `i` its place among the notes of its kind.
pub fn note_notice(note: &Value, i: i64) -> Value {
    let text = s(note, "text");
    let tone = s(note, "tone");
    let kind = s(note, "kind");
    let (id, word) = if eq(&kind, "memory") {
        ("memory".to_string(), "MEMORY")
    } else if eq(&kind, "leak") {
        (format!("leak:{i}"), "LEAK")
    } else if like(&text, "usage:*") {
        ("usage".into(), "USAGE")
    } else if like(&text, "*watcher stopped*") {
        ("watcher".into(), "WATCHER")
    } else if like(&text, "next queued prompt:*") {
        ("next".into(), "NEXT")
    } else if eq(&tone, "error") {
        ("error".into(), "ERROR")
    } else {
        (format!("note:{i}"), "NOTE")
    };
    json!({ "key": format!("notice:{id}"), "kind": "notice", "provider": "", "sessionId": "", "cwd": "",
        "tone": tone, "word": word, "text": text })
}

/// The header's markers (Add-ChatOverlayHeadNotices): each note but the
/// ask's and a reload's, each kind counted apart, then the ask's banner.
pub fn head_notices(snap: &Value, now_ms: i64, wall: Wall) -> Vec<Value> {
    let none = Value::Null;
    let header = get(snap, "header").unwrap_or(&none);
    let mut seen: Vec<(String, i64)> = Vec::new();
    let mut out = Vec::new();
    let notes: Vec<&Value> = match get(header, "notes") {
        Some(Value::Array(a)) => a.iter().collect(),
        Some(Value::Null) | None => Vec::new(),
        Some(x) => vec![x],
    };
    for note in notes {
        let k = s(note, "kind");
        if !clock::truthy(Some(note)) || is_in(&k, &["ask", "reload"]) {
            continue;
        }
        let i = match seen.iter_mut().find(|(n, _)| eq(n, &k)) {
            Some((_, c)) => {
                *c += 1;
                *c - 1
            }
            None => {
                seen.push((k.clone(), 1));
                0
            }
        };
        out.push(note_notice(note, i));
    }
    if let Some(ask) = get(header, "ask").filter(|a| clock::truthy(Some(a))) {
        out.push(ask_notice(ask, now_ms, wall));
    }
    out
}

/// Add-ChatOverlayAsk's marker row.
pub fn ask_notice(ask: &Value, now_ms: i64, wall: Wall) -> Value {
    let keys: Vec<String> = list(ask, "keys")
        .iter()
        .map(|x| clock::text(Some(x)))
        .collect();
    let titles: Vec<String> = list(ask, "titles")
        .iter()
        .map(|x| clock::text(Some(x)))
        .collect();
    let left: Vec<String> = list(ask, "left")
        .iter()
        .map(|x| clock::text(Some(x)))
        .collect();
    let mut lines = vec![format!(
        "{} {DOT} {} can continue",
        ask_head(ask, now_ms, wall),
        ask_count(ask)
    )];
    lines.extend(titles.iter().cloned());
    lines.extend(left.iter().cloned());
    json!({ "key": "ask", "kind": "ask", "provider": "", "sessionId": "", "cwd": "",
        "count": n(ask, "count"), "keys": keys, "titles": titles, "restart": n(ask, "restart"),
        "tone": "cutoff", "word": "CONTINUE?", "text": lines.join("\n") })
}

/// The snapshot's reload asks (Get-ChatOverlayReloads).
pub fn reloads(snap: &Value) -> Vec<&Value> {
    get(snap, "header").map_or_else(Vec::new, |h| list(h, "reload"))
}

/// Add-ChatOverlayReload's marker row.
pub fn reload_notice(reload: &Value) -> Value {
    let pid = n(reload, "pid");
    let tip = s(reload, "text");
    let text = if tip.is_empty() {
        reload_text(reload)
    } else {
        format!("{}\n{tip}", reload_text(reload))
    };
    json!({ "key": format!("reload:{pid}"), "kind": "reload", "provider": "", "sessionId": "", "cwd": "",
        "pid": pid, "id": s(reload, "id"), "state": s(reload, "state"), "window": s(reload, "window"),
        "tone": "dim", "word": "RELOAD?", "text": text })
}

/// Get-ChatOverlayNoticeModel: a marker's card - word, tone, text.
pub fn notice_model(row: &Value) -> Option<(String, String, String)> {
    if !row.is_object() || !is_in(&s(row, "kind"), &["notice", "ask", "reload"]) {
        return None;
    }
    Some((s(row, "word"), s(row, "tone"), s(row, "text")))
}

/// Get-ChatOverlaySayWord.
pub fn say_word(kind: &str, tone: &str) -> &'static str {
    let warn = eq(tone, "warn");
    match kind.to_ascii_lowercase().as_str() {
        "busy" => "OPENING",
        "late" => "NO ANSWER",
        "nostart" => "NOT OPENED",
        "delete" if warn => "NOT DELETED",
        "delete" => "DELETED",
        "reload" => "RELOAD",
        _ if warn => "NOT OPENED",
        _ => "OPENED",
    }
}

/// Add-ChatOverlayOpenSay's marker row.
pub fn said_notice(kind: &str, tone: &str, text: &str, about: &str) -> Value {
    json!({ "key": "notice:said", "kind": "notice", "provider": "", "sessionId": "", "cwd": "",
        "tone": tone, "word": say_word(kind, tone), "text": text, "about": about })
}

/// New-ChatOverlayUnlockedHint's marker row.
pub fn unlocked_notice(hotkey_text: &str) -> Value {
    let key = if hotkey_text.is_empty() {
        "the tray menu"
    } else {
        hotkey_text
    };
    json!({ "key": "notice:unlocked", "kind": "notice", "provider": "", "sessionId": "", "cwd": "",
        "tone": "unlocked", "word": "UNLOCKED", "text": format!("unlocked - drag to move {DOT} {key} locks it") })
}

/// Add-ChatOverlayCompact's dot and words.
pub fn compact(snap: &Value) -> (&'static str, String) {
    let none = Value::Null;
    let c = get(snap, "counts").unwrap_or(&none);
    let header = get(snap, "header").unwrap_or(&none);
    let need = n(c, "waiting") + n(c, "needsInput");
    let mut bits: Vec<String> = Vec::new();
    let mut cut = if get(c, "cutOff").is_some() {
        n(c, "cutOff")
    } else {
        0
    };
    let can = get(header, "ask").map_or(0, |a| n(a, "count"));
    if need != 0 {
        bits.push(format!("{need} waiting"));
    }
    let rl = reloads(snap).len();
    if rl != 0 {
        bits.push(format!(
            "{rl} reload{} asked",
            if rl != 1 { "s" } else { "" }
        ));
    }
    let new = if get(c, "unread").is_some() {
        n(c, "unread")
    } else {
        0
    };
    if new != 0 {
        bits.push(format!("{new} new"));
    }
    if can != 0 {
        bits.push(format!("{can} can continue"));
    }
    cut = (cut - can).max(0);
    let auto = if get(c, "auto").is_some() {
        n(c, "auto")
    } else {
        0
    };
    if cut != 0 {
        bits.push(if auto != 0 {
            format!("{cut} cut off ({auto} auto)")
        } else {
            format!("{cut} cut off")
        });
    }
    for (k, says) in [
        ("busy", "working"),
        ("running", "running"),
        ("idle", "idle"),
        ("queued", "queued"),
    ] {
        if n(c, k) != 0 {
            bits.push(format!("{} {says}", n(c, k)));
        }
    }
    let state = if need != 0 {
        "waiting"
    } else if cut != 0 || can != 0 {
        "cutoff"
    } else if n(c, "busy") != 0 {
        "busy"
    } else if n(c, "running") != 0 {
        "running"
    } else {
        "idle"
    };
    let text = if bits.is_empty() {
        "no chats open".to_string()
    } else {
        bits.join(&format!(" {DOT} "))
    };
    (state, text)
}

/// The "+N more" line under the rows (Update-ChatOverlayView).
pub fn more_line(rest: &[&Value]) -> String {
    let idle = rest.iter().filter(|r| eq(&s(r, "status"), "idle")).count();
    let q = rest
        .iter()
        .filter(|r| eq(&s(r, "status"), "queued"))
        .count();
    let mut bits = Vec::new();
    if idle != 0 {
        bits.push(format!("{idle} idle"));
    }
    if q != 0 {
        bits.push(format!("{q} queued"));
    }
    let mut t = format!("+{} more", rest.len());
    if !bits.is_empty() {
        t += &format!(" {DOT} {}", bits.join(", "));
    }
    t
}

/// Select-ChatOverlayActiveUsage: the usage of a provider a row is open
/// for.
pub fn active_usage(snap: &Value) -> Vec<&Value> {
    let open: Vec<String> = list(snap, "rows")
        .iter()
        .map(|r| s(r, "provider").to_lowercase())
        .collect();
    get(snap, "header").map_or_else(Vec::new, |h| {
        list(h, "usage")
            .into_iter()
            .filter(|u| open.contains(&s(u, "provider").to_lowercase()))
            .collect()
    })
}

/// A gauge's letters (Add-ChatOverlayGauge -Letter).
pub fn gauge_letter(provider: &str) -> String {
    match provider.to_lowercase().as_str() {
        "claude" => "Cl".into(),
        "codex" => "Cx".into(),
        "copilot" => "Cp".into(),
        _ => {
            let u: Vec<u16> = provider.encode_utf16().take(2).collect();
            String::from_utf16_lossy(&u)
        }
    }
}

/// Get-ChatOverlayOpenSay's busy line, said while an open runs.
pub fn open_busy_text(title: &str, seconds: i64) -> String {
    format!(
        "opening '{}' in VS Code - {seconds}s",
        format_title(title, 40)
    )
}

/// Test-ChatOverlayFullScreenState: busy, full screen and presentation
/// hold the screen.
pub fn full_screen_state(state: i32) -> bool {
    matches!(state, 2..=4)
}

/// Update-ChatOverlayTray's colour name: the most urgent state.
pub fn tray_name(snap: &Value) -> &'static str {
    let none = Value::Null;
    let c = get(snap, "counts").unwrap_or(&none);
    let cut = if get(c, "cutOff").is_some() {
        n(c, "cutOff")
    } else {
        0
    };
    if n(c, "waiting") + n(c, "needsInput") != 0 {
        "waiting"
    } else if cut != 0 {
        "cutoff"
    } else if t(c, "busy") {
        "busy"
    } else if t(c, "running") {
        "running"
    } else {
        "idle"
    }
}

/// Test-ChatOverlayCardRow: a row a card is for.
pub fn card_row(row: &Value) -> bool {
    row.is_object()
        && is_in(
            &s(row, "kind"),
            &[
                "session", "cutoff", "recent", "job", "usage", "notice", "ask", "reload",
            ],
        )
}

/// A tile's mark (New-ChatOverlayTile): where a chat runs.
pub fn tile_mark(row: &Value) -> &'static str {
    if !eq(&s(row, "kind"), "session") {
        return "none";
    }
    match s(row, "where").to_ascii_lowercase().as_str() {
        "vscode" => "vscode",
        "terminal" => "terminal",
        "run" => "run",
        _ => "window",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, NaiveDateTime, Utc};

    fn utc(ms: i64) -> NaiveDateTime {
        DateTime::<Utc>::from_timestamp_millis(ms)
            .unwrap()
            .naive_utc()
    }

    fn rect(v: &Value) -> Rect {
        let a = v.as_array().unwrap();
        let g = |i: usize| a[i].as_i64().unwrap() as i32;
        Rect::new(g(0), g(1), g(2), g(3))
    }

    fn screen(v: &Value) -> Rect {
        Rect::new(
            n(v, "X") as i32,
            n(v, "Y") as i32,
            n(v, "Width") as i32,
            n(v, "Height") as i32,
        )
    }

    fn pair(v: Option<&Value>) -> (i32, i32) {
        v.and_then(Value::as_array).map_or((0, 0), |a| {
            (a[0].as_i64().unwrap() as i32, a[1].as_i64().unwrap() as i32)
        })
    }

    fn at(p: Option<(i32, i32)>) -> Value {
        p.map_or(Value::Null, |(x, y)| json!([x, y]))
    }

    fn strings(v: Option<&Value>) -> Vec<String> {
        v.and_then(Value::as_array)
            .map(|a| a.iter().map(|x| clock::text(Some(x))).collect())
            .unwrap_or_default()
    }

    /// What the Rust port answers for a case, in the shape the PowerShell
    /// side wrote its answer.
    fn answer(input: &Value) -> Value {
        let i = input;
        match s(i, "kind").as_str() {
            "title" => json!(format_title(&s(i, "text"), n(i, "width") as usize)),
            "limit" => json!(limit_text(&s(i, "text"), n(i, "max"), t(i, "ellipsis"))),
            "autoTitle" => json!(auto_title(&s(i, "text"), n(i, "max"))),
            "askHead" => json!(ask_head(&i["ask"], n(i, "now"), &utc)),
            "askCount" => json!(ask_count(&i["ask"])),
            "askLeave" => json!(ask_leave_tip(&i["ask"])),
            "reloadText" => json!(reload_text(&i["reload"])),
            "chipActions" => Value::Array(
                chip_actions(&i["row"])
                    .iter()
                    .map(|a| json!({ "id": a.id, "label": a.label, "tip": a.tip, "disabled": a.disabled }))
                    .collect(),
            ),
            "openable" => json!(row_openable(&i["row"])),
            "deletable" => json!(row_deletable(&i["row"])),
            "deleteArmed" => json!(delete_armed(
                &s(i, "armedKey"),
                get(i, "armedAt").and_then(Value::as_i64),
                &s(i, "key"),
                n(i, "now"),
                4000
            )),
            "pressCounts" => json!(press_counts(get(i, "shown").and_then(Value::as_i64), n(i, "press"), 300)),
            "chipTarget" => json!(chip_target(
                &s(i, "shown"),
                &s(i, "under"),
                f(i, "rested"),
                t(i, "onChip"),
                f(i, "sinceOver"),
                t(i, "down"),
                t(i, "blocked"),
                &s(i, "spent"),
                f(i, "delay")
            )),
            "step" => {
                let st0 = &i["state"];
                let mut st = ChipState {
                    under: s(st0, "under"),
                    under_at: get(st0, "underAt").and_then(Value::as_i64),
                    last_pos: s(st0, "lastPos"),
                    key: s(st0, "key"),
                    over_at: get(st0, "overAt").and_then(Value::as_i64),
                    spent: s(st0, "spent"),
                    armed: t(st0, "armed"),
                };
                step(&mut st, &s(i, "under"), &s(i, "pos"), t(i, "onChip"), n(i, "now"));
                json!({ "under": st.under, "underAt": st.under_at, "lastPos": st.last_pos, "key": st.key,
                    "overAt": st.over_at, "spent": st.spent, "armed": st.armed })
            }
            "cardLeft" => json!(card_left(rect(&i["panel"]), screen(&i["screen"]))),
            "chipLayout" => {
                let name: Vec<Rect> = i["name"].as_array().map_or_else(Vec::new, |a| a.iter().map(rect).collect());
                let got = chip_layout(
                    rect(&i["row"]),
                    rect(&i["line"]),
                    pair(get(i, "icons")),
                    pair(get(i, "words")),
                    screen(&i["screen"]),
                    &name,
                    get(i, "panel").filter(|p| !p.is_null()).map(rect),
                    n(i, "gap") as i32,
                    get(i, "wordsX").and_then(Value::as_i64).map(|x| x as i32),
                );
                got.map_or(Value::Null, |c| {
                    json!({ "X": c.x, "Y": c.y, "IconsAt": at(c.icons_at), "WordsAt": at(c.words_at),
                        "NameAt": at(c.name_at), "Left": c.left, "Out": c.out })
                })
            }
            "cardPlace" => {
                let c = card_placement(
                    rect(&i["panel"]),
                    rect(&i["row"]),
                    pair(get(i, "size")),
                    screen(&i["screen"]),
                    n(i, "gap") as i32,
                    n(i, "push") as i32,
                    t(i, "below"),
                );
                json!({ "X": c.x, "Y": c.y, "Left": c.left, "Below": c.below, "Above": c.above, "TipX": c.tip_x })
            }
            "controlsPlace" => {
                let c = controls_placement(
                    rect(&i["panel"]),
                    pair(get(i, "size")),
                    screen(&i["screen"]),
                    n(i, "gap") as i32,
                    eq(&s(i, "prefer"), "below"),
                    n(i, "bar") as i32,
                    n(i, "box") as i32,
                    n(i, "inset") as i32,
                    n(i, "indent") as i32,
                );
                json!({ "X": c.x, "Y": c.y, "Side": if c.below { "below" } else { "above" },
                    "Align": if c.left { "Left" } else { "Right" } })
            }
            "controlsShown" => json!(controls_shown(
                t(i, "shown"),
                t(i, "onPanel"),
                t(i, "onControls"),
                t(i, "dragging"),
                t(i, "down"),
                f(i, "rested"),
                f(i, "sinceOver")
            )),
            "resize" => {
                let z = resize(&Drag {
                    rows: n(i, "rows"),
                    dy: f(i, "dy"),
                    row_height: f(i, "rowHeight"),
                    scale: f(i, "scale"),
                    collapsed: t(i, "collapsed"),
                    kept: n(i, "kept"),
                    top: eq(&s(i, "edge"), "n"),
                    open: n(i, "open"),
                    recent_drawn: n(i, "recentDrawn"),
                    recent_pool: n(i, "recentPool"),
                    recent_kept: n(i, "recentKept"),
                    recent_height: f(i, "recentHeight"),
                    head_height: f(i, "headHeight"),
                });
                json!({ "Rows": z.rows, "Recent": z.recent, "Steps": z.steps, "RecentSteps": z.recent_steps,
                    "Grow": z.grow })
            }
            "heightCap" => json!(height_cap(
                n(i, "top") as i32,
                screen(&i["area"]),
                f(i, "scale"),
                f(i, "floor"),
                get(i, "bottom").and_then(Value::as_i64).map(|b| b as i32)
            )),
            "placement" => {
                let screens: Vec<(Rect, bool)> = i["screens"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|s0| (screen(s0), t(s0, "Primary")))
                    .collect();
                let xy = match (get(i, "x").and_then(Value::as_i64), get(i, "y").and_then(Value::as_i64)) {
                    (Some(x), Some(y)) => Some((x as i32, y as i32)),
                    _ => None,
                };
                let (x, y, moved) = placement(xy, n(i, "w") as i32, n(i, "h") as i32, &screens);
                json!({ "X": x, "Y": y, "Moved": moved })
            }
            "edgesRect" => {
                let r = edges_rect(rect(&i["panel"]), n(i, "out") as i32);
                json!([r.x, r.y, r.w, r.h])
            }
            "raisePlan" => raise_plan(n(i, "code")).map_or(Value::Null, |p| {
                json!({ "By": if p.by_name { "name" } else { "folder" }, "Seconds": p.seconds, "Words": p.words })
            }),
            "titleOn" => json!(title_on(&s(i, "title"), &s(i, "root"), &strings(get(i, "profiles")))),
            "selectWindow" => {
                let wins: Vec<(isize, String)> = i["windows"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|w| (n(w, "Handle") as isize, s(w, "Title")))
                    .collect();
                select_window(&s(i, "cwd"), &wins, &strings(get(i, "profiles")), &s(i, "name"))
                    .map_or(Value::Null, |h| json!(h))
            }
            "hotkey" => match parse_hotkey(&s(i, "text")) {
                Ok(None) => Value::Null,
                Ok(Some(h)) => json!({ "Mods": h.mods, "Vk": h.vk, "Text": h.text }),
                Err(e) => json!({ "error": e }),
            },
            "rowClock" => {
                let mut spec = row_clock(&i["row"]);
                spec.live = t(i, "live");
                json!(format_row_clock(&spec, n(i, "now")))
            }
            "rowWords" => json!(row_words(&i["row"])),
            "cardWords" => json!(card_words(&i["row"], &s(i, "what"))),
            "headNotices" => Value::Array(head_notices(&i["snap"], n(i, "now"), &utc)),
            "reloadNotice" => reload_notice(&i["reload"]),
            "sayWord" => json!(say_word(&s(i, "say"), &s(i, "tone"))),
            "compact" => {
                let (dot, text) = compact(&i["snap"]);
                json!({ "dot": dot, "text": text })
            }
            "more" => {
                let rows: Vec<&Value> = i["rest"].as_array().unwrap().iter().collect();
                json!(more_line(&rows))
            }
            "activeUsage" => Value::Array(
                active_usage(&i["snap"])
                    .iter()
                    .map(|u| json!(s(u, "provider")))
                    .collect(),
            ),
            "openBusy" => json!(open_busy_text(&s(i, "title"), n(i, "seconds"))),
            "fullScreen" => json!(full_screen_state(n(i, "state") as i32)),
            "trayName" => json!(tray_name(&i["snap"])),
            "cardRow" => json!(card_row(&i["row"])),
            "unlocked" => unlocked_notice(&s(i, "hotkey")),
            other => panic!("a case of kind {other}"),
        }
    }

    /// A number as the vectors write it: a whole one as an integer, so 84.0
    /// and 84 are one answer (ConvertTo-NvJson writes an integral double
    /// without its point).
    fn norm(v: &Value) -> Value {
        match v {
            Value::Number(x) if x.as_i64().is_none() && x.as_u64().is_none() => {
                let f = x.as_f64().unwrap_or(0.0);
                if f == f.trunc() && f.abs() < 9.0e15 {
                    json!(f as i64)
                } else {
                    v.clone()
                }
            }
            Value::Array(a) => Value::Array(a.iter().map(norm).collect()),
            Value::Object(m) => {
                Value::Object(m.iter().map(|(k, x)| (k.clone(), norm(x))).collect())
            }
            _ => v.clone(),
        }
    }

    /// Every case answers what the PowerShell overlay answered, under both
    /// editions where they differ.
    #[test]
    fn every_panel_case_answers_as_powershell_did() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/overlay-panel.json");
        let bytes = std::fs::read(path).expect("native/vectors/overlay-panel.json");
        let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
        let file: Value = serde_json::from_slice(bytes).unwrap();
        let cases = file["cases"].as_array().unwrap();
        assert!(cases.len() >= 100, "cases: {}", cases.len());
        let mut bad = Vec::new();
        for c in cases {
            let name = c["name"].as_str().unwrap();
            let got = norm(&answer(&c["input"]));
            let wants: Vec<&Value> = match c.get("expect") {
                Some(w) => vec![w],
                None => c["expectByEdition"].as_object().unwrap().values().collect(),
            };
            for want in wants {
                if got != norm(want) {
                    bad.push(format!("{name}:\n  got  {got}\n  want {want}"));
                }
            }
        }
        assert!(
            bad.is_empty(),
            "{} of {}:\n{}",
            bad.len(),
            cases.len(),
            bad.join("\n")
        );
    }

    #[test]
    fn a_card_shape_traces_the_body_and_its_tail() {
        let (p, y) = card_shape(false, 40.0, 100.0, false, false).unwrap();
        assert_eq!(y, 40.0);
        assert!(p.starts_with("M 15.5 0.5 "), "{p}");
        assert!(p.contains("L 0.5 40 "), "the tip on the left: {p}");
        let (p, _) = card_shape(true, 2.0, 100.0, false, false).unwrap();
        assert!(p.contains("L 336.5 14 "), "held clear of the corner: {p}");
        let (p, x) = card_shape(false, 320.0, 60.0, true, true).unwrap();
        assert_eq!(x, 316.0, "held 14 in from the right corner");
        assert!(p.contains("L 316 59.5 "), "{p}");
        assert!(card_shape(false, 0.0, 0.0, false, false).is_none());
    }

    /// The '+N more' line, which the vectors leave out: Update-ChatOverlayView
    /// builds it inline, not by a function of its own.
    #[test]
    fn the_more_line_counts_idle_and_queued() {
        let rest = [
            json!({"status": "idle"}),
            json!({"status": "Queued"}),
            json!({"status": "busy"}),
            json!({"status": "idle"}),
        ];
        let refs: Vec<&Value> = rest.iter().collect();
        assert_eq!(more_line(&refs), format!("+4 more {DOT} 2 idle, 1 queued"));
        assert_eq!(more_line(&refs[2..3]), "+1 more");
    }

    /// The tray's state, the most urgent count first (Update-ChatOverlayTray).
    #[test]
    fn the_tray_takes_the_most_urgent_state() {
        assert_eq!(
            tray_name(&json!({"counts": {"needsInput": 1, "cutOff": 2}})),
            "waiting"
        );
        assert_eq!(
            tray_name(&json!({"counts": {"cutOff": 2, "busy": 1}})),
            "cutoff"
        );
        assert_eq!(
            tray_name(&json!({"counts": {"busy": 1, "running": 1}})),
            "busy"
        );
        assert_eq!(tray_name(&json!({"counts": {"running": 1}})), "running");
        assert_eq!(tray_name(&json!({})), "idle");
    }
}
