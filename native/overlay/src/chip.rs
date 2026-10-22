// The open chip, as the WPF overlay has it (src/overlay-windows.ps1): a
// see-through window over the row the pointer rests on, in three parts
// Set-ChatOverlayChipPlacement places apart - open as a ring round the
// row's tile, delete on the tile's own bin with room left of it for what the
// chip says, and the other answers as word chips outside the panel
// (New-ChatOverlayChipContent) - and the bookkeeping of when it comes and
// goes (Update-ChatOverlayChip) and what a click on it counts as
// (Register-ChatOverlayChipPress, Invoke-ChatOverlayChipRelease). Pure: its
// window, the tile drag and what a click asks for are app.rs's.

use serde_json::Value;

use crate::art;
use crate::look::Look;
use crate::model::{self, Action, ChipState, Rect, eq, s};
use crate::panel::MARK_W;
use crate::scene::{self, Draw, Font, Measure, Prim};

const WORD: Font = Font::new(11.0);
/// the room kept for what the chip says, left of delete, and its margin
const ROOM: f64 = 72.0;
const ROOM_GAP: f64 = 3.0;
const ICON: (f64, f64) = crate::panel::ICON;
/// a press this long after the chip came up counts, under a pointer that
/// never left it (Test-ChatOverlayChipPressCounts)
pub const PRESS_MS: i64 = 300;
/// how long delete's sure? waits for its second click
/// (Test-ChatOverlayDeleteArmed)
pub const ARM_MS: i64 = 4000;
/// a second click this soon is a double-click's half, no answer
const DOUBLE_MS: i64 = 400;

/// A drawn row as the chip goes by it, in screen pixels
/// (Get-ChatOverlayRowRects): its rect - its line too, a chat's row being
/// its tile alone and a marker its short tile - and the tile the ring goes
/// round, with its size in units.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub key: String,
    pub row: Value,
    pub rect: Rect,
    pub tile: Option<(Rect, f64, f64)>,
}

/// Find-ChatOverlayRowAt: the first row whose rect holds the point.
pub fn row_at(entries: &[Entry], x: i32, y: i32) -> Option<&Entry> {
    entries.iter().find(|e| e.rect.holds(x, y))
}

/// The ring's light (Set-ChatOverlayNameLit): from clear to the accent and
/// back, eased out - 160 ms on, 110 off - or at once.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Fade {
    from: f64,
    to: f64,
    at: i64,
    ms: i64,
}

impl Fade {
    /// How lit, 0 to 1, at `now`.
    pub fn alpha(&self, now: i64) -> f64 {
        if self.ms <= 0 {
            return self.to;
        }
        let t = ((now - self.at) as f64 / self.ms as f64).clamp(0.0, 1.0);
        self.from + (self.to - self.from) * (1.0 - (1.0 - t).powi(3))
    }

    /// Whether it is still on its way.
    pub fn moving(&self, now: i64) -> bool {
        self.ms > 0 && now - self.at < self.ms
    }

    pub fn set(&mut self, on: bool, at_once: bool, now: i64) {
        let to = if on { 1.0 } else { 0.0 };
        let from = self.alpha(now);
        *self = if at_once {
            Fade {
                from: to,
                to,
                at: now,
                ms: 0,
            }
        } else {
            Fade {
                from,
                to,
                at: now,
                ms: if on { 160 } else { 110 },
            }
        };
    }
}

/// What a click on the chip asks for (Invoke-ChatOverlayChipRelease).
#[derive(Clone, Debug, PartialEq)]
pub enum Click {
    /// open the row's chat (Invoke-ChatOverlayOpen)
    Open,
    /// delete said sure and clicked again: `delete <key>`
    Delete(String),
    /// the banner's answers: ask-go or ask-leave, and the keys it names
    Ask(&'static str, String),
    /// a reload's: `reload-answer <pid>:<id> reload|later`
    Reload(String, &'static str),
    /// auto-continue's: `auto-chip <key> dont|continue`
    Auto(String, &'static str),
}

/// What the chip's window is to do after a pointer check.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Up {
    /// no chip, and none to come
    Idle,
    /// it went, and the card with it
    Gone,
    /// up for a new row: placed, then shown if it has something to offer,
    /// and the card shown with it
    Shown,
    /// on the same row: placed again where it shows, and the card
    Kept,
}

/// One pointer check (Update-ChatOverlayChip's arguments), in screen pixels.
pub struct Check<'a> {
    pub entries: &'a [Entry],
    pub at: (i32, i32),
    pub down: bool,
    pub now: i64,
    /// the pointer on the panel and not on its controls
    pub on_panel: bool,
    /// on the chip's window as it shows
    pub on_chip: bool,
    /// mid-drag
    pub blocked: bool,
    pub collapsed: bool,
    /// config chipDelayMs, 400 unless set
    pub delay: f64,
    /// an open runs: a face made anew says opening
    pub opening: bool,
}

/// Where the chip goes and what it draws.
#[derive(Clone, Debug, PartialEq)]
pub struct Placed {
    /// the window's corner, screen pixels
    pub x: i32,
    pub y: i32,
    /// its size, units
    pub w: f64,
    pub h: f64,
    pub prims: Vec<Prim>,
    /// what of it shows and takes the pointer, units from its corner - its
    /// window's region
    pub region: Vec<[f64; 4]>,
    /// each part a release is matched to, bottom first, units: id and rect
    pub hits: Vec<(&'static str, [f64; 4])>,
    /// how far past the panel's side its words reach (ChipOut)
    pub out: i32,
}

/// The chip's state between checks: the host's Chip* keys.
#[derive(Clone, Debug, Default)]
pub struct Chip {
    /// under, its rest, the row shown for (key), spent, armed
    pub st: ChipState,
    pub entry: Option<Entry>,
    pub acts: Vec<Action>,
    /// the actions and the ring the face was made for (Get-ChatOverlayChipSig,
    /// Get-ChatOverlayChipNameSig)
    sig: String,
    name_sig: String,
    /// its window shows: a row with something to offer
    pub visible: bool,
    shown_tick: Option<i64>,
    pressed: bool,
    pressed_id: String,
    /// delete asking: the row it asks about and since when
    del_key: String,
    del_at: Option<i64>,
    /// what it says left of delete, and in which colour
    pub hint: (String, &'static str),
    /// the word chip that says click again in its label's place
    again: String,
    /// a click said click again: the face made anew next time it comes
    dirty: bool,
    pub ring: Fade,
}

fn sig(acts: &[Action]) -> String {
    acts.iter()
        .map(|a| format!("{}={}={}", a.id, a.label, a.tip))
        .collect::<Vec<_>>()
        .join("|")
}

fn name_sig(e: &Entry) -> String {
    e.tile
        .map_or(String::new(), |(_, w, h)| format!("tile:{w}:{h}"))
}

fn is_word(id: &str) -> bool {
    !matches!(id, "open" | "delete")
}

impl Chip {
    /// The row the chip shows for, '' for none.
    pub fn key(&self) -> &str {
        &self.st.key
    }

    fn act(&self, id: &str) -> Option<&Action> {
        self.acts.iter().find(|a| a.id == id)
    }

    /// The ring's tile: the row's, when open is among its actions.
    fn ring_tile(&self) -> Option<(Rect, f64, f64)> {
        self.act("open")?;
        self.entry.as_ref()?.tile.filter(|t| t.0.w > 0)
    }

    /// Set-ChatOverlayChipHint.
    pub fn say(&mut self, text: &str, color: &'static str) {
        self.hint = (text.into(), color);
    }

    /// Reset-ChatOverlayDeleteArm: a sure? not answered goes.
    fn reset_arm(&mut self) {
        if !self.del_key.is_empty() && self.hint.0 == "sure?" {
            self.say("", "dim");
        }
        self.del_key.clear();
        self.del_at = None;
    }

    /// Whether delete asks sure? now (its bin in the error's colour).
    pub fn asking(&self) -> bool {
        self.entry
            .as_ref()
            .is_some_and(|e| !self.del_key.is_empty() && eq(&self.del_key, &e.key))
    }

    /// The face made anew (New-ChatOverlayChipContent): nothing said but an
    /// open under way, no ask, no click again.
    fn anew(&mut self, opening: bool) {
        self.sig = sig(&self.acts);
        self.name_sig = self.entry.as_ref().map(name_sig).unwrap_or_default();
        self.say(if opening { "opening" } else { "" }, "dim");
        self.del_key.clear();
        self.del_at = None;
        self.again.clear();
        self.dirty = false;
    }

    /// Show-ChatOverlayChip: up for `e`, lit as it comes. Armed is the
    /// app's to set once it is placed: only off a pointer already on it.
    fn show(&mut self, e: &Entry, now: i64, opening: bool) {
        self.st.key = e.key.clone();
        self.entry = Some(e.clone());
        self.st.over_at = Some(now);
        self.st.spent = e.key.clone();
        self.pressed = false;
        self.pressed_id.clear();
        self.reset_arm();
        let acts = model::chip_actions(&e.row);
        if sig(&acts) != self.sig || self.dirty || name_sig(e) != self.name_sig {
            self.acts = acts;
            self.anew(opening);
        }
        if self.acts.is_empty() {
            self.visible = false;
            self.st.armed = false;
            self.shown_tick = None;
            return;
        }
        self.ring.set(false, true, now);
        self.ring.set(true, false, now);
        self.visible = true;
        self.shown_tick = Some(now);
    }

    /// Hide-ChatOverlayChip: gone, the card with it.
    pub fn hide(&mut self) {
        self.visible = false;
        self.st.key.clear();
        self.entry = None;
        self.st.armed = false;
        self.shown_tick = None;
        self.pressed = false;
        self.pressed_id.clear();
        self.reset_arm();
    }

    /// Update-ChatOverlayChip: one pointer check. The tile drag's is the
    /// app's: none comes here while one is under way.
    pub fn update(&mut self, c: &Check) -> Up {
        if !self.del_key.is_empty()
            && !model::delete_armed(&self.del_key, self.del_at, &self.del_key, c.now, ARM_MS)
        {
            self.reset_arm();
        }
        let on_chip = !self.st.key.is_empty() && self.visible && c.on_chip;
        let mut entry = None;
        let mut acts = Vec::new();
        if (c.on_panel || on_chip) && !c.blocked {
            entry = row_at(c.entries, c.at.0, c.at.1).cloned();
            // folded, the gauges' and the markers' alone
            if entry.as_ref().is_some_and(|e| {
                c.collapsed
                    && !model::is_in(&s(&e.row, "kind"), &["usage", "notice", "ask", "reload"])
            }) {
                entry = None;
            }
            if let Some(e) = &entry {
                acts = model::chip_actions(&e.row);
                if acts.is_empty() && !model::card_row(&e.row) {
                    entry = None;
                }
            }
        }
        let under = entry.as_ref().map_or(String::new(), |e| e.key.clone());
        model::step(
            &mut self.st,
            &under,
            &format!("{},{}", c.at.0, c.at.1),
            on_chip,
            c.now,
        );
        let rested = self.st.under_at.map_or(0.0, |at| (c.now - at) as f64);
        let since = self.st.over_at.map_or(f64::MAX, |at| (c.now - at) as f64);
        let target = model::chip_target(
            &self.st.key,
            &under,
            rested,
            on_chip,
            since,
            c.down,
            c.blocked,
            &self.st.spent,
            c.delay,
        );
        if target.is_empty() {
            if self.st.key.is_empty() {
                return Up::Idle;
            }
            self.hide();
            return Up::Gone;
        }
        if !eq(&target, &self.st.key) {
            let e = entry.expect("a new target is the row under the pointer");
            self.show(&e, c.now, c.opening);
            return Up::Shown;
        }
        // the same row: followed, should it have moved, and what it offers
        // now - the banner's count can change under a resting pointer
        if let Some(e) = entry.filter(|e| eq(&e.key, &self.st.key)) {
            let ring_was = self.name_sig.clone();
            self.entry = Some(e.clone());
            if sig(&acts) != self.sig {
                if !acts.is_empty() && !self.visible {
                    self.show(&e, c.now, c.opening);
                    return Up::Shown;
                }
                self.acts = acts;
                self.anew(c.opening);
                self.ring.set(true, true, c.now);
                self.shown_tick = Some(c.now);
                if on_chip {
                    self.st.armed = false;
                }
                if self.acts.is_empty() {
                    self.visible = false;
                }
            } else if self.act("open").is_some() && name_sig(&e) != ring_was {
                // the ring drawn anew round a tile grown wider, lit already
                self.name_sig = name_sig(&e);
                self.ring.set(true, true, c.now);
            }
        }
        Up::Kept
    }

    /// A press on a part of it (MouseLeftButtonDown): it counts once the
    /// chip is armed, or has been up long enough to be seen.
    pub fn press(&mut self, id: &str, now: i64) {
        self.pressed = self.st.armed || model::press_counts(self.shown_tick, now, PRESS_MS);
        self.pressed_id = id.into();
        if id == "open" {
            self.ring.set(true, true, now);
        }
    }

    /// A press given up without a release on it - a tile drag's, or one
    /// the system took back.
    pub fn unpress(&mut self) {
        self.pressed = false;
        self.pressed_id.clear();
    }

    /// The release after a press, over the part `on` ('' for none): acts
    /// only on the part it was pressed on, and only when the press counted;
    /// one that did not is no click, but not a silent one - the chip says
    /// click again, and is armed for it. `opening`: an open under way.
    pub fn release(&mut self, on: &str, now: i64, opening: bool) -> Option<Click> {
        let was = std::mem::take(&mut self.pressed_id);
        let armed = std::mem::replace(&mut self.pressed, false);
        if was == "open" {
            self.ring.set(true, true, now);
        }
        if !was.is_empty() && was == on && !armed {
            self.st.armed = true;
            let greyed = self.act(&was).is_some_and(|a| a.disabled);
            if !greyed && !(opening && was == "open") {
                if is_word(&was) {
                    self.again = was;
                } else {
                    self.say("click again", "dim");
                }
                self.dirty = true;
            }
            return None;
        }
        if !armed || was.is_empty() || was != on {
            return None;
        }
        let row = self.entry.as_ref()?.row.clone();
        let key = self.st.key.clone();
        match on {
            "open" => Some(Click::Open),
            "delete" => {
                if model::row_deletable(&row) {
                    self.delete(&key, now)
                } else {
                    None
                }
            }
            "ask-go" | "ask-leave" => {
                let keys: Vec<String> = model::list(&row, "keys")
                    .into_iter()
                    .map(|k| crate::clock::text(Some(k)))
                    .filter(|k| !k.is_empty())
                    .collect();
                Some(Click::Ask(
                    if on == "ask-go" {
                        "ask-go"
                    } else {
                        "ask-leave"
                    },
                    keys.join(","),
                ))
            }
            "reload-go" | "reload-later" => {
                let (pid, id) = (model::n(&row, "pid"), s(&row, "id"));
                if pid == 0 || id.is_empty() {
                    return None;
                }
                Some(Click::Reload(
                    format!("{pid}:{id}"),
                    if on == "reload-go" { "reload" } else { "later" },
                ))
            }
            "dont" | "continue" => Some(Click::Auto(
                key,
                if on == "dont" { "dont" } else { "continue" },
            )),
            _ => None,
        }
    }

    /// Invoke-ChatOverlayDeleteChip: the first click asks sure?, for 4 s; a
    /// second on the same row in that time deletes, the second half of a
    /// double-click being no answer.
    fn delete(&mut self, key: &str, now: i64) -> Option<Click> {
        if eq(&self.del_key, key) && self.del_at.is_some_and(|at| now - at < DOUBLE_MS) {
            return None;
        }
        if !model::delete_armed(&self.del_key, self.del_at, key, now, ARM_MS) {
            self.reset_arm();
            self.say("sure?", "error");
            self.del_key = key.into();
            self.del_at = Some(now);
            return None;
        }
        self.reset_arm();
        Some(Click::Delete(key.into()))
    }

    /// Set-ChatOverlayChipPlacement and the face: the parts where
    /// Get-ChatOverlayChipLayout puts them, for the panel at `panel` (its
    /// screen pixels, `px` of them a unit) on the work area `screen`; the
    /// ring at the panel's `opacity`.
    #[allow(clippy::too_many_arguments)]
    pub fn place(
        &self,
        m: &dyn Measure,
        panel: Rect,
        screen: Rect,
        px: f64,
        look: &Look,
        opacity: f64,
        now: i64,
    ) -> Option<Placed> {
        let e = self.entry.as_ref()?;
        let (_, th) = m.size("x", WORD, None, 0);
        let with_delete = self.act("delete");
        // the icons part: the hint's room and delete, as tall as the taller
        let icons_h = (th + 1.0).max(ICON.1);
        let icons_w = ROOM + ROOM_GAP + ICON.0;
        // the words: each chip's label and size
        let words: Vec<(&Action, String, f64)> = self
            .acts
            .iter()
            .filter(|a| is_word(a.id))
            .map(|a| {
                let label = if a.id == self.again {
                    "click again".to_string()
                } else {
                    a.label.clone()
                };
                let w = m.size(&label, WORD, None, 0).0 + 16.0;
                (a, label, w)
            })
            .collect();
        let word_h = th + 5.0;
        let words_w =
            words.iter().map(|w| w.2).sum::<f64>() + 4.0 * words.len().saturating_sub(1) as f64;
        let gap = (f64::from(model::CARD_GAP) * px).round() as i32;
        // rounded with the gap before it, so delete's right edge falls where
        // the tile's bin's does
        let icons = if with_delete.is_some() {
            (
                ((icons_w + f64::from(model::CARD_GAP)) * px).round() as i32 - gap,
                (icons_h * px).ceil() as i32,
            )
        } else {
            (0, 0)
        };
        let wsize = if words.is_empty() {
            (0, 0)
        } else {
            ((words_w * px).ceil() as i32, (word_h * px).ceil() as i32)
        };
        let ring = self.ring_tile();
        let names: Vec<Rect> = ring.iter().map(|t| t.0).collect();
        let wx =
            eq(&s(&e.row, "kind"), "reload").then(|| e.rect.x + (MARK_W * px).round() as i32 + gap);
        let at = model::chip_layout(
            e.rect,
            e.rect,
            icons,
            wsize,
            screen,
            &names,
            Some(panel),
            gap,
            wx,
        )?;
        let unit = |o: (i32, i32)| (f64::from(o.0) / px, f64::from(o.1) / px);
        let (mut w, mut h) = (0.0_f64, 0.0_f64);
        let mut grow = |x: f64, y: f64, pw: f64, ph: f64| {
            w = w.max(x + pw);
            h = h.max(y + ph);
        };
        let mut d = Draw::new(1.0);
        let mut region = Vec::new();
        let mut hits = Vec::new();
        // the ring, under the rest, as faint as the panel
        if let (Some((_, tw, tht)), Some(o)) = (ring, at.name_at) {
            let (x, y) = unit(o);
            let a = (self.ring.alpha(now) * 255.0).round() as u32;
            let accent = look.argb("accent");
            let mut rd = Draw::new(opacity);
            rd.border(
                x,
                y,
                tw,
                tht,
                6.0,
                0,
                (a << 24) | (accent & 0x00FF_FFFF),
                2.0,
            );
            d.prims.extend(rd.prims);
            d.add(scene::hit("open", x, y, tw, tht, 6.0, scene::HAND, 0));
            region.push([x, y, tw, tht]);
            hits.push(("open", [x, y, tw, tht]));
            grow(x, y, tw, tht);
        }
        // the words, side by side
        if let Some(o) = at.words_at.filter(|_| !words.is_empty()) {
            let (mut x, y) = unit(o);
            for (a, label, cw) in &words {
                let hover = if a.disabled { 0 } else { look.argb("hover") };
                d.add(scene::hit_on(
                    a.id,
                    x + 1.0,
                    y + 1.0,
                    cw - 2.0,
                    word_h - 2.0,
                    3.5,
                    scene::ARROW,
                    look.argb("panel"),
                    hover,
                ));
                d.add(scene::rect(
                    x,
                    y,
                    *cw,
                    word_h,
                    4.5,
                    0,
                    look.argb("edge"),
                    1.0,
                ));
                let c = look.argb(if a.disabled { "faint" } else { "text" });
                d.add(scene::text(
                    x + 8.0,
                    y + 2.0,
                    cw - 16.0,
                    th,
                    label,
                    c,
                    WORD,
                    false,
                    0,
                    0,
                ));
                region.push([x, y, *cw, word_h]);
                hits.push((a.id, [x, y, *cw, word_h]));
                grow(x, y, *cw, word_h);
                x += cw + 4.0;
            }
        }
        // what it says, against delete, then delete over the tile's bin
        if let (Some(a), Some(o)) = (with_delete, at.icons_at) {
            let (x, y) = unit(o);
            if !self.hint.0.is_empty() {
                let tw = m.size(&self.hint.0, WORD, None, 0).0;
                let hw = (tw + 8.0).min(ROOM);
                let (hx, hy) = (x + ROOM - hw, y + (icons_h - th - 1.0) / 2.0);
                d.add(scene::rect(
                    hx,
                    hy,
                    hw,
                    th + 1.0,
                    3.0,
                    look.argb("panel"),
                    0,
                    0.0,
                ));
                d.add(scene::text(
                    hx + 4.0,
                    hy,
                    hw - 8.0,
                    th,
                    &self.hint.0,
                    look.argb(self.hint.1),
                    WORD,
                    false,
                    0,
                    0,
                ));
                region.push([hx, hy, hw, th + 1.0]);
            }
            let (bx, by) = (x + ROOM + ROOM_GAP, y + (icons_h - ICON.1) / 2.0);
            let hover = if a.disabled { 0 } else { look.argb("hover") };
            d.add(scene::hit(
                "delete",
                bx,
                by,
                ICON.0,
                ICON.1,
                3.0,
                scene::ARROW,
                hover,
            ));
            let c = look.argb(if self.asking() {
                "error"
            } else if a.disabled {
                "faint"
            } else {
                "dim"
            });
            let glyph = art::action_icon("delete", &a.label).xf(art::Xf::at(bx, by));
            d.add_opt(scene::path(&glyph, 0, c, art::ACTION_STROKE, true, true));
            region.push([bx, by, ICON.0, ICON.1]);
            hits.push(("delete", [bx, by, ICON.0, ICON.1]));
            grow(x, y, icons_w, icons_h);
        }
        Some(Placed {
            x: at.x,
            y: at.y,
            w,
            h,
            prims: d.prims,
            region,
            hits,
            out: at.out,
        })
    }
}

/// The part of `p` at (x, y), units from its corner: the topmost, '' for
/// none - what a release is let go on.
pub fn part_at(p: &Placed, x: f64, y: f64) -> &'static str {
    p.hits
        .iter()
        .rev()
        .find(|(_, r)| x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3])
        .map_or("", |(id, _)| id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::look;
    use crate::scene::Fixed;
    use serde_json::json;

    const SID: &str = "0b5c1a52-7a07-4a51-9b55-1c2a3f4e5d6c";
    const PANEL: Rect = Rect::new(1000, 100, 162, 300);
    const SCREEN: Rect = Rect::new(0, 0, 1920, 1040);

    fn chat(key: &str, status: &str) -> Value {
        json!({ "key": key, "kind": "session", "provider": "claude", "status": status, "where": "vscode",
            "sessionId": SID, "cwd": "C:/w", "title": "Fix the build" })
    }

    /// a chat's row on the panel at `PANEL`, its tile at the stack's left
    fn entry(row: Value, top: i32) -> Entry {
        let rect = Rect::new(PANEL.x + 12, PANEL.y + top, 138, 36);
        let tile = Rect::new(rect.x, rect.y, 138, 36);
        Entry {
            key: s(&row, "key"),
            row,
            rect,
            tile: Some((tile, crate::panel::tile_width(), 36.0)),
        }
    }

    fn check<'a>(entries: &'a [Entry], at: (i32, i32), now: i64) -> Check<'a> {
        Check {
            entries,
            at,
            down: false,
            now,
            on_panel: true,
            on_chip: false,
            blocked: false,
            collapsed: false,
            delay: 400.0,
            opening: false,
        }
    }

    #[test]
    fn the_rings_light_eases_out_and_can_come_at_once() {
        let mut f = Fade::default();
        f.set(true, false, 1000);
        assert_eq!(f.alpha(1000), 0.0);
        assert!(
            (f.alpha(1080) - 0.875).abs() < 1e-9,
            "half the time, 1 - 0.5^3"
        );
        assert_eq!(f.alpha(1160), 1.0);
        assert!(f.moving(1100) && !f.moving(1160));
        // off from where it is, in 110 ms
        f.set(false, false, 1080);
        assert!((f.alpha(1080) - 0.875).abs() < 1e-9);
        assert_eq!(f.alpha(1190), 0.0);
        f.set(true, true, 1200);
        assert_eq!(f.alpha(1200), 1.0);
    }

    #[test]
    fn it_comes_after_a_rest_and_a_click_under_a_parked_pointer_asks_again() {
        let es = [entry(chat("s:1", "idle"), 29)];
        let mut c = Chip::default();
        let at = (PANEL.x + 40, PANEL.y + 40);
        // the pointer onto the row: 400 ms on it, moving or not, and it comes
        assert_eq!(c.update(&check(&es, at, 1000)), Up::Idle);
        assert_eq!(c.update(&check(&es, at, 1300)), Up::Idle);
        assert_eq!(c.update(&check(&es, (at.0 + 1, at.1), 1400)), Up::Shown);
        // a row that comes under a parked pointer starts no rest until it moves
        let mut c = Chip::default();
        assert_eq!(c.update(&check(&[], at, 1000)), Up::Idle);
        assert_eq!(c.update(&check(&es, at, 1100)), Up::Idle);
        assert_eq!(c.update(&check(&es, at, 2000)), Up::Idle, "parked: no rest");
        assert_eq!(c.update(&check(&es, (at.0 + 1, at.1), 2100)), Up::Idle);
        assert_eq!(c.update(&check(&es, (at.0 + 1, at.1), 2500)), Up::Shown);
        assert!(c.visible);
        assert_eq!(
            c.acts.iter().map(|a| a.id).collect::<Vec<_>>(),
            ["open", "delete"]
        );
        // a click at once, the pointer never off it: no open, click again
        c.st.armed = false;
        c.press("open", 2550);
        assert_eq!(c.release("open", 2600, false), None);
        assert_eq!(c.hint, ("click again".to_string(), "dim"));
        // armed now: the next counts
        c.press("open", 2650);
        assert_eq!(c.release("open", 2700, false), Some(Click::Open));
        // pressed on open, let go on delete: nothing
        c.press("open", 2710);
        assert_eq!(c.release("delete", 2750, false), None);
        // a press 300 ms after it came up counts even unarmed
        c.st.armed = false;
        c.press("open", 2500 + PRESS_MS);
        assert_eq!(c.release("open", 2850, false), Some(Click::Open));
    }

    #[test]
    fn it_stays_while_the_pointer_crosses_to_it_and_goes_with_another_row() {
        let es = [
            entry(chat("s:1", "idle"), 29),
            entry(chat("s:2", "idle"), 71),
        ];
        let mut c = Chip::default();
        let on1 = (PANEL.x + 40, PANEL.y + 40);
        c.update(&check(&es, on1, 0));
        c.update(&check(&es, (on1.0, on1.1 + 1), 10));
        assert_eq!(c.update(&check(&es, (on1.0, on1.1 + 1), 500)), Up::Shown);
        // off the panel, onto nothing: kept 300 ms
        let mut off = check(&es, (PANEL.x - 50, on1.1), 600);
        off.on_panel = false;
        assert_eq!(c.update(&off), Up::Kept);
        off.now = 900;
        assert_eq!(c.update(&off), Up::Gone);
        assert_eq!(c.key(), "");
        // back on the same row: spent until it leaves it
        c.update(&check(&es, on1, 1000));
        assert_eq!(
            c.update(&check(&es, (on1.0 + 1, on1.1), 2000)),
            Up::Shown,
            "spent went with the pointer off it"
        );
        // another row: gone at once
        assert_eq!(c.update(&check(&es, (on1.0, PANEL.y + 80), 2100)), Up::Gone);
    }

    #[test]
    fn delete_asks_sure_then_deletes_on_a_second_click_in_time() {
        let es = [entry(chat("s:1", "idle"), 29)];
        let mut c = Chip::default();
        let at = (PANEL.x + 40, PANEL.y + 40);
        c.update(&check(&es, at, 0));
        c.update(&check(&es, (at.0 + 1, at.1), 10));
        c.update(&check(&es, (at.0 + 1, at.1), 500));
        c.st.armed = true;
        c.press("delete", 1000);
        assert_eq!(c.release("delete", 1010, false), None);
        assert_eq!(c.hint, ("sure?".to_string(), "error"));
        assert!(c.asking());
        // a double-click's second half is no answer
        c.press("delete", 1200);
        assert_eq!(c.release("delete", 1210, false), None);
        assert!(c.asking());
        c.press("delete", 2000);
        assert_eq!(
            c.release("delete", 2010, false),
            Some(Click::Delete("s:1".into()))
        );
        assert!(!c.asking());
        assert_eq!(c.hint.0, "");
        // asked and not answered in 4 s: back to delete
        c.press("delete", 3000);
        c.release("delete", 3010, false);
        assert!(c.asking());
        c.update(&check(&es, (at.0 + 1, at.1), 3010 + ARM_MS - 1));
        assert!(c.asking());
        c.update(&check(&es, (at.0 + 1, at.1), 3010 + ARM_MS));
        assert!(!c.asking());
        assert_eq!(c.hint.0, "");
    }

    #[test]
    fn a_busy_chats_delete_is_greyed_and_takes_no_click() {
        let es = [entry(chat("s:1", "busy"), 29)];
        let mut c = Chip::default();
        let at = (PANEL.x + 40, PANEL.y + 40);
        c.update(&check(&es, at, 0));
        c.update(&check(&es, (at.0 + 1, at.1), 10));
        c.update(&check(&es, (at.0 + 1, at.1), 500));
        assert!(c.act("delete").unwrap().disabled);
        c.st.armed = false;
        c.press("delete", 600);
        assert_eq!(c.release("delete", 610, false), None);
        assert_eq!(c.hint.0, "", "greyed: no click again");
        c.press("delete", 700);
        assert_eq!(c.release("delete", 710, false), None);
        assert!(!c.asking());
    }

    #[test]
    fn the_banners_and_reloads_answers_name_what_they_answer() {
        let ask = json!({ "key": "ask", "kind": "ask", "tone": "cutoff", "count": 2, "restart": 0, "keys": ["k1", "k2"], "titles": ["One", "Two"] });
        let rl = json!({ "key": "reload:7", "kind": "reload", "tone": "dim", "pid": 7, "id": "x9", "window": "w" });
        for (row, id, want) in [
            (ask.clone(), "ask-go", Click::Ask("ask-go", "k1,k2".into())),
            (ask, "ask-leave", Click::Ask("ask-leave", "k1,k2".into())),
            (
                rl.clone(),
                "reload-go",
                Click::Reload("7:x9".into(), "reload"),
            ),
            (rl, "reload-later", Click::Reload("7:x9".into(), "later")),
        ] {
            let e = Entry {
                key: s(&row, "key"),
                row,
                rect: Rect::new(1012, 130, 138, 20),
                tile: None,
            };
            let mut c = Chip::default();
            c.show(&e, 0, false);
            c.st.armed = true;
            c.press(id, 1000);
            assert_eq!(c.release(id, 1010, false), Some(want));
        }
        let mut row = chat("s:3", "cutoff");
        row["auto"] = json!({ "state": "armed", "long": "auto 13:01" });
        let e = entry(row, 29);
        let mut c = Chip::default();
        c.show(&e, 0, false);
        assert_eq!(
            c.acts.iter().map(|a| a.id).collect::<Vec<_>>(),
            ["dont", "open", "delete"]
        );
        // an unarmed click on a word chip says click again in its place
        c.press("dont", 10);
        assert_eq!(c.release("dont", 20, false), None);
        assert_eq!(c.again, "dont");
        c.press("dont", 30);
        assert_eq!(
            c.release("dont", 40, false),
            Some(Click::Auto("s:3".into(), "dont"))
        );
    }

    #[test]
    fn its_parts_go_on_the_tile_its_bin_and_beside_the_panel() {
        let mut row = chat("s:3", "cutoff");
        row["auto"] = json!({ "state": "off" });
        let e = entry(row, 29);
        let mut c = Chip::default();
        c.show(&e, 0, false);
        let p = c
            .place(&Fixed, PANEL, SCREEN, 1.0, look("dark"), 1.0, 1000)
            .unwrap();
        // the panel has more screen on its left: the words go there, 5 off
        // its side; "continue" is 8 letters of 5.5
        let ww = 44.0 + 16.0;
        assert_eq!(p.x, PANEL.x - 5 - ww as i32);
        assert_eq!(p.out, 5 + ww as i32);
        let hit = |id: &str| p.hits.iter().find(|h| h.0 == id).unwrap().1;
        assert_eq!(hit("continue"), [0.0, 8.0, ww, 20.0]);
        // the ring exactly over the tile, delete 5 in from its right end,
        // over the bin
        let ring = hit("open");
        assert_eq!(ring[0], 5.0 + ww + 12.0);
        assert_eq!(ring[2], crate::panel::tile_width());
        let del = hit("delete");
        assert_eq!(del[0] + del[2], ring[0] + 138.0 - 5.0);
        assert_eq!((del[1], del[3]), (11.0, 14.0));
        assert_eq!(part_at(&p, del[0] + 1.0, del[1] + 1.0), "delete");
        assert_eq!(part_at(&p, ring[0] + 2.0, ring[1] + 2.0), "open");
        assert_eq!(part_at(&p, 2.0, 2.0), "");
        // nothing said: no hint box in the region
        assert_eq!(p.region.len(), 3);
        // a reload's answers on the panel, just past its marker
        let rl =
            json!({ "key": "reload:7", "kind": "reload", "tone": "dim", "pid": 7, "id": "x9" });
        let e = Entry {
            key: "reload:7".into(),
            row: rl,
            rect: Rect::new(1012, 300, 138, 20),
            tile: None,
        };
        c.show(&e, 2000, false);
        let p = c
            .place(&Fixed, PANEL, SCREEN, 1.0, look("dark"), 1.0, 2000)
            .unwrap();
        assert_eq!((p.x, p.y), (1012 + 34 + 5, 300));
        assert_eq!(
            p.out, 0,
            "on the left: the words spill over no side the card takes"
        );
    }

    fn golden(name: &str, c: &Chip, theme: &str) {
        let (scene, win) = scene::golden::scene();
        let m = scene::Measurer::new(&scene);
        let p = c
            .place(&m, PANEL, SCREEN, 1.0, look(theme), 0.9, 10_000)
            .unwrap();
        let (w, h) = (p.w.ceil() as u32, p.h.ceil() as u32);
        scene::show(&scene, p.prims);
        let rgb = scene::golden::render(&scene, &win, w, h);
        scene::golden::check(name, w, h, &rgb);
    }

    #[test]
    fn golden_chip_open_delete_sure() {
        let e = entry(chat("s:1", "idle"), 29);
        let mut c = Chip::default();
        c.show(&e, 0, false);
        c.st.armed = true;
        c.press("delete", 500);
        c.release("delete", 510, false);
        golden("chip-open-delete-sure", &c, "dark");
    }

    #[test]
    fn golden_chip_continue_light() {
        let mut row = chat("s:3", "cutoff");
        row["auto"] = json!({ "state": "late" });
        let e = entry(row, 29);
        let mut c = Chip::default();
        c.show(&e, 0, true);
        golden("chip-continue-opening-light", &c, "light");
    }

    #[test]
    fn golden_chip_ask_words_and_a_greyed_delete() {
        let ask = json!({ "key": "ask", "kind": "ask", "tone": "cutoff", "count": 3, "restart": 0, "keys": ["k1"], "titles": [] });
        let mut c = Chip::default();
        c.show(
            &Entry {
                key: "ask".into(),
                row: ask,
                rect: Rect::new(1012, 130, 138, 20),
                tile: None,
            },
            0,
            false,
        );
        golden("chip-ask", &c, "dark");
        let mut c = Chip::default();
        c.show(&entry(chat("s:1", "waiting"), 29), 0, false);
        golden("chip-greyed-delete", &c, "dark");
    }
}
