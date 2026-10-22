// The pointer on the panel (Update-ChatOverlayHover and the windows' mouse
// handlers, src/overlay-windows.ps1): looked at every 120 ms - the edges
// shown and hidden, the settings box shut once left, a slider at rest sent,
// the chip put up over the row it rests on - and the windows' presses,
// releases and hovers as Slint hands them (App::hit). A press that drags -
// the frame or the bar's grip, an edge, a slider's thumb, the chip's ring -
// is followed every 16 ms until the button is up (App::frame): Slint gives
// no move to a TouchArea once pressed outside it.
//
// Under CHATQ_PANEL_DRIVE a test's file of lines stands in for the pointer
// and a full screen (App::drive_poll): nothing then reads the real ones or
// the pointer's buttons.

use std::time::{Duration, Instant};

use slint::{ComponentHandle, TimerMode};

use super::{App, BAR, CHIP, EDGES, Held, PANEL, REST, held, rect_of};
use crate::controls::{self, Thumb};
use crate::model::{self, Rect, eq};
use crate::{chip, selflog, trayicon, win32};

/// A tooltip shows once the pointer rests this long, and goes after
/// SHOW_TIP (ToolTipService's own delays).
const TIP_REST: Duration = Duration::from_millis(400);
const SHOW_TIP: Duration = Duration::from_secs(5);
/// The again arrow turns this long after a click.
const SPIN: Duration = Duration::from_secs(2);
/// A press on the ring moved this far is a drag of the panel.
const TILE_SLOP: i32 = 4;

/// A drag under way.
pub(super) enum Drag {
    /// the panel by its frame or the bar's grip: the pointer and the
    /// panel's corner at the press
    Move { mx: i32, my: i32, x: i32, y: i32 },
    /// an edge, for more or fewer rows
    Size(Size),
    /// a slider's thumb: which, the pointer's x and the value at the press
    Thumb { i: usize, mx: i32, v0: f64 },
}

/// A drag of an edge (Start-ChatOverlaySizeDrag): what it started from.
pub(super) struct Size {
    d: model::Drag,
    my: i32,
    pub(super) rows: i64,
    pub(super) recent: i64,
    /// the top edge: the foot held, the panel grown up
    pub(super) top: bool,
    pub(super) cap: f64,
    pub(super) want: Option<f64>,
    pub(super) bottom: i32,
    kept: i64,
    recent_kept: i64,
    area_y: i32,
    area_bottom: i32,
}

/// A press on the chip's ring: the pointer, the panel's corner, and
/// whether it has moved into a drag of the panel.
pub(super) struct Tile {
    mx: i32,
    my: i32,
    x: i32,
    y: i32,
    moved: bool,
}

fn ms_since(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

impl App {
    /// Where the pointer is: the drive's, under the drive seam.
    fn cursor(&self) -> Option<(i32, i32)> {
        if self.drive.is_some() {
            return Some(self.fake.unwrap_or((super::OFF, super::OFF)));
        }
        win32::cursor_now()
    }

    fn win_rect(&self, i: usize) -> Rect {
        Rect::new(
            self.pos[i].0,
            self.pos[i].1,
            self.sizes[i].0,
            self.sizes[i].1,
        )
    }

    /// The pointer in window `i`'s units.
    fn units(&self, i: usize, at: (i32, i32)) -> (f64, f64) {
        let sc = f64::from(self.scenes[i].window().scale_factor());
        (
            f64::from(at.0 - self.pos[i].0) / sc,
            f64::from(at.1 - self.pos[i].1) / sc,
        )
    }

    /// Update-ChatOverlayHover, every 120 ms.
    pub(super) fn hover(&mut self) {
        self.drive_poll();
        self.screen_poll();
        self.tip_poll();
        if !self.shown {
            return;
        }
        let Some(at) = self.cursor() else { return };
        let down = self.drive.is_none() && win32::any_button();
        let now = Instant::now();
        let px = self.px();
        let pr = self.rect;
        let on_panel = pr.holds(at.0, at.1);
        let near = Rect::new(pr.x - 64, pr.y - 64, pr.w + 128, pr.h + 128).holds(at.0, at.1);
        let busy = self.edges_shown
            || self.box_open
            || !self.chip.key().is_empty()
            || self.chip.asking()
            || self.drag.is_some()
            || self.tile.is_some()
            || self.spinning()
            || self.pending();
        if !near && !busy {
            self.left(false, now);
            self.enter_at = None;
            let ms = self.ms();
            model::step(
                &mut self.chip.st,
                "",
                &format!("{},{}", at.0, at.1),
                false,
                ms,
            );
            return;
        }
        let rim = model::edges_rect(pr, (4.0 * px).round() as i32).holds(at.0, at.1);
        let on_ctl = self.visible[BAR] && self.win_rect(BAR).holds(at.0, at.1);
        self.left(rim || on_ctl, now);
        if !(rim || on_ctl) || (down && !self.edges_shown) {
            self.enter_at = None;
        } else if self.enter_at.is_none() {
            self.enter_at = Some(now);
        }
        if rim || on_ctl {
            self.over_at = Some(now);
            if self.box_open {
                self.box_over_at = Some(now);
            }
        }
        let sizing = matches!(self.drag, Some(Drag::Size(_) | Drag::Move { .. }));
        let rested = self.enter_at.map_or(0.0, ms_since);
        let since = self.over_at.map_or(f64::MAX, ms_since);
        let edges = !self.st.collapsed
            && model::controls_shown(self.edges_shown, rim, on_ctl, sizing, down, rested, since);
        let mut changed = edges != self.edges_shown;
        self.edges_shown = edges;
        if self.box_open
            && !down
            && self.drag.is_none()
            && self.box_over_at.is_none_or(|t| t.elapsed() >= REST)
        {
            self.box_open = false;
            changed = true;
        }
        if !down && self.pending_at.is_some_and(|t| t.elapsed() >= REST) {
            self.send_pending();
        }
        if changed {
            self.layout(self.pos[PANEL]);
        }
        self.chip_check(at, down, on_panel && !on_ctl);
    }

    /// The pointer on the panel or its controls, or off them since when:
    /// the relock's clock.
    fn left(&mut self, on: bool, now: Instant) {
        if on {
            self.pointer_in = true;
        } else if self.pointer_in {
            self.pointer_in = false;
            if !self.st.locked {
                self.left_at = Some(now);
            }
        }
    }

    /// The rows as the chip finds them: screen pixels.
    fn entries(&self) -> Vec<chip::Entry> {
        let Some(b) = self.built.as_ref() else {
            return Vec::new();
        };
        let px = self.px();
        let (x0, y0) = self.pos[PANEL];
        let r = |v: f64| (v * px).round() as i32;
        let at = |q: [f64; 4]| Rect::new(x0 + r(q[0]), y0 + r(q[1]), r(q[2]), r(q[3]));
        b.items
            .iter()
            .map(|it| chip::Entry {
                key: it.key.clone(),
                row: it.row.clone(),
                rect: at(it.rect),
                tile: it.tile.map(|t| (at(t), t[2], t[3])),
            })
            .collect()
    }

    /// Update-ChatOverlayChip: the chip up for the row the pointer rests on.
    fn chip_check(&mut self, at: (i32, i32), down: bool, on_panel: bool) {
        if self.tile.as_ref().is_some_and(|t| t.moved) {
            return;
        }
        let entries = self.entries();
        let on_chip = self.visible[CHIP] && self.win_rect(CHIP).holds(at.0, at.1);
        let c = chip::Check {
            entries: &entries,
            at,
            down,
            now: self.ms(),
            on_panel,
            on_chip,
            blocked: matches!(self.drag, Some(Drag::Move { .. } | Drag::Size(_))),
            collapsed: self.st.collapsed,
            delay: self.delay(),
            opening: self.opening.is_some(),
        };
        match self.chip.update(&c) {
            chip::Up::Idle => {}
            chip::Up::Gone => self.hide_chip(),
            chip::Up::Shown => {
                self.layout(self.pos[PANEL]);
                // armed only off a pointer not already on it
                self.chip.st.armed = !self.win_rect(CHIP).holds(at.0, at.1);
                self.card_tick();
                self.wake();
            }
            chip::Up::Kept => self.layout(self.pos[PANEL]),
        }
    }

    /// One of a window's TouchAreas: pressed, released, cancelled, or the
    /// pointer in or out of it.
    pub(super) fn hit(&mut self, i: usize, id: &str, kind: &str) {
        if !self.shown {
            return;
        }
        if kind == "down" {
            self.hide_tip();
        }
        match i {
            PANEL => self.panel_hit(id, kind),
            BAR => self.bar_hit(id, kind),
            EDGES => self.edge_hit(id, kind),
            CHIP => self.chip_hit(id, kind),
            _ => {}
        }
    }

    fn panel_hit(&mut self, id: &str, kind: &str) {
        match kind {
            "down" if !self.st.locked => self.start_move(),
            "enter" => {
                let key = id.strip_prefix("tip:").unwrap_or("");
                let tip = self
                    .built
                    .as_ref()
                    .and_then(|b| b.items.iter().find(|it| !key.is_empty() && it.key == key))
                    .map(|it| it.tip.clone());
                if let Some(t) = tip.filter(|t| !t.is_empty()) {
                    self.want_tip(t);
                }
            }
            "leave" => self.hide_tip(),
            _ => {}
        }
    }

    fn bar_hit(&mut self, id: &str, kind: &str) {
        match kind {
            "down" if id == "bar" => self.start_move(),
            "down" => {
                if let Some(name) = id.strip_prefix("slider:") {
                    self.slider_jump(name);
                } else if let Some(name) = id.strip_prefix("thumb:") {
                    self.start_thumb(name);
                }
            }
            "up" => {
                let Some(at) = self.cursor() else { return };
                let (ux, uy) = self.units(BAR, at);
                let on = self
                    .ctl
                    .as_ref()
                    .map_or("", |c| controls::part_at(&c.hits, ux, uy));
                if on == id {
                    self.press_part(id);
                }
            }
            "enter" => {
                if let Some(name) = id.strip_prefix("thumb:") {
                    self.thumb_look(name, Thumb::Over);
                } else if let Some(t) = controls::tip(id, self.st.collapsed) {
                    self.want_tip(t.into());
                }
            }
            "leave" => {
                if let Some(name) = id.strip_prefix("thumb:") {
                    self.thumb_look(name, Thumb::Still);
                }
                self.hide_tip();
            }
            _ => {}
        }
    }

    /// A button or a choice in the controls clicked.
    fn press_part(&mut self, id: &str) {
        let now = Instant::now();
        match id {
            "again" => {
                if self.drag.is_none() {
                    self.cmd("refresh");
                    self.spin_until = Some(now + SPIN);
                    self.wake();
                }
            }
            "gear" => {
                self.box_open = !self.box_open;
                if self.box_open {
                    self.hide_chip();
                    self.box_over_at = Some(now);
                } else {
                    self.box_over_at = None;
                }
                self.layout(self.pos[PANEL]);
            }
            "min" => {
                self.act("hide", false);
                if self.tray.is_some() && !self.hide_told {
                    self.hide_told = true;
                    let key = self.hotkey_words();
                    let or = if key.is_empty() {
                        String::new()
                    } else {
                        format!(" or press {key}")
                    };
                    self.local_balloon(
                        &format!("Hidden. Click the tray icon{or} to show it again."),
                        6000,
                        "None",
                    );
                }
            }
            "max" => self.act("console", false),
            "close" => self.cmd("close"),
            "fold" => self.act(
                if self.st.collapsed {
                    "expand"
                } else {
                    "collapse"
                },
                false,
            ),
            _ => self.choice(id, now),
        }
    }

    /// A chip of the settings box: sent at once, shown as sent until the
    /// snapshot's config has it.
    fn choice(&mut self, id: &str, now: Instant) {
        let Some((group, v)) = id.split_once(':') else {
            return;
        };
        match group {
            "theme" => {
                self.theme = Some(Held {
                    v: v.into(),
                    sent: Some(now),
                });
                self.cmd(&format!("config theme {v}"));
                self.hide_chip();
            }
            "recent" => {
                let k: i64 = if v == "off" {
                    0
                } else {
                    v.parse().unwrap_or(5)
                };
                self.recent = Some(Held {
                    v: k,
                    sent: Some(now),
                });
                self.cmd(&format!("config recent {k}"));
            }
            "cut" => {
                let (a, verb) = match v {
                    "continue" => ("on", "auto-on"),
                    "ask" => ("ask", "auto-ask"),
                    _ => ("off", "auto-off"),
                };
                self.auto = Some(Held {
                    v: a.into(),
                    sent: Some(now),
                });
                self.cmd(verb);
            }
            _ => return,
        }
        self.redraw();
    }

    fn slider_index(name: &str) -> usize {
        usize::from(name != "opacity")
    }

    fn slider(&self, name: &str) -> Option<controls::Slider> {
        self.ctl
            .as_ref()?
            .sliders
            .iter()
            .find(|s| s.name == name)
            .copied()
    }

    /// A press on a slider's track: the thumb jumps there.
    fn slider_jump(&mut self, name: &str) {
        let (Some(sl), Some(at)) = (self.slider(name), self.cursor()) else {
            return;
        };
        let v = sl.at(self.units(BAR, at).0);
        self.slide(Self::slider_index(name), v);
    }

    fn start_thumb(&mut self, name: &str) {
        let Some(at) = self.cursor() else { return };
        let i = Self::slider_index(name);
        let v0 = if i == 0 {
            self.opacity()
        } else {
            self.max_rows() as f64
        };
        self.thumbs[i] = Thumb::Held;
        self.drag = Some(Drag::Thumb { i, mx: at.0, v0 });
        self.wake();
        self.layout(self.pos[PANEL]);
    }

    fn thumb_look(&mut self, name: &str, t: Thumb) {
        let i = Self::slider_index(name);
        if self.thumbs[i] != Thumb::Held && self.thumbs[i] != t {
            self.thumbs[i] = t;
            self.layout(self.pos[PANEL]);
        }
    }

    /// A slider moved to `v`: shown at once, sent once it rests
    /// (Set-ChatOverlayOpacity; the rows the same way).
    fn slide(&mut self, i: usize, v: f64) {
        if i == 0 {
            let v = (v.clamp(0.3, 1.0) * 100.0).round() / 100.0;
            if self
                .opacity
                .as_ref()
                .is_some_and(|h| h.v == v && h.sent.is_none())
            {
                return;
            }
            self.opacity = held(v);
        } else {
            let v = (v.round() as i64).clamp(1, 30);
            if self
                .max_rows
                .as_ref()
                .is_some_and(|h| h.v == v && h.sent.is_none())
            {
                return;
            }
            self.max_rows = held(v);
        }
        self.pending_at = Some(Instant::now());
        self.redraw();
    }

    /// The sliders at rest: the opacity sent unless config.json has it,
    /// the rows whatever they are.
    fn send_pending(&mut self) {
        self.pending_at = None;
        let now = Instant::now();
        if let Some(v) = self
            .opacity
            .as_ref()
            .filter(|h| h.sent.is_none())
            .map(|h| h.v)
        {
            if (v - model::f(self.cfg(), "opacity")).abs() < 0.005 {
                self.opacity = None;
            } else {
                self.opacity = Some(Held { v, sent: Some(now) });
                self.cmd(&format!("config opacity {v:.2}"));
            }
        }
        if let Some(v) = self
            .max_rows
            .as_ref()
            .filter(|h| h.sent.is_none())
            .map(|h| h.v)
        {
            self.max_rows = Some(Held { v, sent: Some(now) });
            self.cmd(&format!("config maxRows {v}"));
        }
    }

    fn edge_hit(&mut self, id: &str, kind: &str) {
        let edge = id.strip_prefix("edge:").unwrap_or("");
        match kind {
            "down" => self.start_size(edge == "n"),
            "enter" if !self.st.collapsed => {
                if self.hint != edge {
                    self.hint = edge.into();
                    self.layout(self.pos[PANEL]);
                }
            }
            "leave" if !matches!(self.drag, Some(Drag::Size(_))) && !self.hint.is_empty() => {
                self.hint.clear();
                self.layout(self.pos[PANEL]);
            }
            _ => {}
        }
    }

    fn chip_hit(&mut self, id: &str, kind: &str) {
        match kind {
            "down" => {
                self.chip.press(id, self.ms());
                if id == "open"
                    && let Some(at) = self.cursor()
                {
                    let (x, y) = self.pos[PANEL];
                    self.tile = Some(Tile {
                        mx: at.0,
                        my: at.1,
                        x,
                        y,
                        moved: false,
                    });
                    self.wake();
                }
                self.layout(self.pos[PANEL]);
            }
            "up" => {
                if self.tile.take().is_some_and(|t| t.moved) {
                    self.chip.unpress();
                    return;
                }
                let Some(at) = self.cursor() else { return };
                let (ux, uy) = self.units(CHIP, at);
                let on = self
                    .placed_chip
                    .as_ref()
                    .map_or("", |p| chip::part_at(p, ux, uy));
                let c = self.chip.release(on, self.ms(), self.opening.is_some());
                self.clicked(c);
            }
            "cancel" => {
                self.tile = None;
                self.chip.unpress();
            }
            "enter" => {
                let tip = self
                    .chip
                    .acts
                    .iter()
                    .find(|a| a.id == id)
                    .map(|a| a.tip.clone());
                if let Some(t) = tip.filter(|t| !t.is_empty()) {
                    self.want_tip(t);
                }
            }
            "leave" => self.hide_tip(),
            _ => {}
        }
    }

    /// What a click on the chip comes to: all but an open take it down.
    fn clicked(&mut self, c: Option<chip::Click>) {
        let Some(c) = c else {
            // sure?, or click again: its face anew
            self.layout(self.pos[PANEL]);
            return;
        };
        let row = self.chip.entry.as_ref().map(|e| e.row.clone());
        if !matches!(c, chip::Click::Open) {
            self.hide_chip();
        }
        match c {
            chip::Click::Open => {
                if let Some(row) = row {
                    self.open_row(&row);
                }
            }
            chip::Click::Delete(k) => self.cmd(&format!("delete {k}")),
            chip::Click::Ask(v, keys) if keys.is_empty() => self.cmd(v),
            chip::Click::Ask(v, keys) => self.cmd(&format!("{v} {keys}")),
            chip::Click::Reload(id, a) => self.cmd(&format!("reload-answer {id} {a}")),
            chip::Click::Auto(k, a) => self.cmd(&format!("auto-chip {k} {a}")),
        }
        self.layout(self.pos[PANEL]);
    }

    // ---- drags -------------------------------------------------------------

    /// A press on the frame (unlocked) or the bar's grip: the panel moves
    /// with the pointer (Start-ChatOverlayGripDrag).
    fn start_move(&mut self) {
        if self.drag.is_some() {
            return;
        }
        let Some(at) = self.cursor() else { return };
        self.hide_chip();
        let (x, y) = self.pos[PANEL];
        self.drag = Some(Drag::Move {
            mx: at.0,
            my: at.1,
            x,
            y,
        });
        self.wake();
    }

    /// A press on an edge (Start-ChatOverlaySizeDrag): the rows and the
    /// Recent lines a drag comes to, from what is drawn now.
    fn start_size(&mut self, top: bool) {
        if self.drag.is_some() || self.st.collapsed {
            return;
        }
        let (Some(b), Some(at)) = (self.built.as_ref(), self.cursor()) else {
            return;
        };
        let px = self.px();
        let max = self.max_rows();
        let drawn = b.rows as i64;
        let from = if drawn > 0 && drawn < max { drawn } else { max };
        let pool = (model::list(&self.snap, "recent").len()
            + model::list(&self.snap, "recentMore").len())
        .min(20) as i64;
        let recent_kept = self.recent_count();
        let d = model::Drag {
            rows: from,
            dy: 0.0,
            row_height: if b.row_h > 0.0 { b.row_h } else { 42.0 } * px,
            scale: px,
            collapsed: false,
            kept: max,
            top,
            open: model::list(&self.snap, "rows").len() as i64,
            recent_drawn: b.recent as i64,
            recent_pool: pool,
            recent_kept,
            recent_height: b.recent_h * px,
            head_height: (b.line + 7.0) * px,
        };
        let area = rect_of(self.work);
        let z = Size {
            d,
            my: at.1,
            rows: max,
            recent: recent_kept,
            top,
            cap: self.cap(),
            want: None,
            bottom: self.rect.bottom(),
            kept: max,
            recent_kept,
            area_y: area.y,
            area_bottom: area.bottom(),
        };
        self.hide_chip();
        self.drag = Some(Drag::Size(z));
        self.hint = if top { "n" } else { "s" }.into();
        self.wake();
        self.layout(self.pos[PANEL]);
    }

    /// A drag of an edge moved to the pointer's `y`
    /// (Update-ChatOverlaySizeDrag).
    fn size_to(&mut self, y: i32) {
        let Some(Drag::Size(z)) = self.drag.as_mut() else {
            return;
        };
        let mut d = z.d;
        d.dy = f64::from(y - z.my);
        let r = model::resize(&d);
        if z.top {
            z.want = Some(z.cap + r.grow);
        }
        if (r.rows, r.recent) == (z.rows, z.recent) {
            return;
        }
        z.rows = r.rows;
        z.recent = r.recent;
        let (top, bottom, area_y, area_bottom) = (z.top, z.bottom, z.area_y, z.area_bottom);
        self.redraw();
        if top {
            let px = self.px();
            let tall = self.sizes[PANEL].1;
            let units = self.built.as_ref().map_or(0.0, |b| b.height);
            let y =
                area_y.max((bottom - tall).min(area_bottom - ((units + 1.0) * px).ceil() as i32));
            if y != self.pos[PANEL].1 {
                self.layout((self.pos[PANEL].0, y));
            }
        }
    }

    /// The drag let go.
    pub(super) fn end_drag(&mut self) {
        let Some(drag) = self.drag.take() else { return };
        let now = Instant::now();
        match drag {
            Drag::Move { .. } => {
                self.save_at();
                self.redraw();
            }
            Drag::Size(z) => {
                let on_edge = self.cursor().is_some_and(|at| {
                    self.visible[EDGES] && self.win_rect(EDGES).holds(at.0, at.1)
                });
                if !on_edge {
                    self.hint.clear();
                }
                if z.rows != z.kept {
                    self.max_rows = Some(Held {
                        v: z.rows,
                        sent: Some(now),
                    });
                    self.cmd(&format!("config maxRows {}", z.rows));
                }
                if z.recent != z.recent_kept {
                    self.recent = Some(Held {
                        v: z.recent,
                        sent: Some(now),
                    });
                    self.cmd(&format!("config recent {}", z.recent));
                }
                self.save_at();
                self.redraw();
            }
            Drag::Thumb { i, .. } => {
                self.thumbs[i] = Thumb::Still;
                self.pending_at = Some(now);
                self.layout(self.pos[PANEL]);
            }
        }
    }

    /// The panel's corner kept where a drag left it.
    fn save_at(&mut self) {
        let (x, y) = self.pos[PANEL];
        if self.st.x != Some(x) || self.st.y != Some(y) {
            self.st.x = Some(x);
            self.st.y = Some(y);
            self.save_place();
        }
    }

    /// The 16 ms timer on, while a drag, a spin or the ring's fade wants it.
    pub(super) fn wake(&mut self) {
        if !self.frame_timer.running() {
            self.frame_timer
                .start(TimerMode::Repeated, Duration::from_millis(16), || {
                    super::with_app(|a| a.frame())
                });
        }
    }

    /// Every 16 ms while wanted: the drag followed, the arrow turned, the
    /// ring faded; off once none of them is left.
    fn frame(&mut self) {
        let up = self.drive.is_some() || !win32::left_button().0;
        if let Some(at) = self.cursor() {
            // a press on the ring is the release's (chip_hit) unless it moves
            let tile = self.tile.as_ref().map(|t| (t.mx, t.my, t.x, t.y, t.moved));
            if let Some((mx, my, x, y, false)) = tile
                && !up
                && ((at.0 - mx).abs() > TILE_SLOP || (at.1 - my).abs() > TILE_SLOP)
            {
                // the ring pressed and moved: the panel dragged, the chip
                // along with it, unlit
                if let Some(t) = self.tile.as_mut() {
                    t.moved = true;
                }
                self.chip.unpress();
                self.chip.ring.set(false, true, self.ms());
                self.drag = Some(Drag::Move { mx, my, x, y });
            }
            match self.drag {
                Some(_) if up => {
                    self.end_drag();
                    self.tile = None;
                }
                Some(Drag::Move { mx, my, x, y }) => self.move_to((x + at.0 - mx, y + at.1 - my)),
                Some(Drag::Size(_)) => self.size_to(at.1),
                Some(Drag::Thumb { i, mx, v0 }) => {
                    let name = if i == 0 { "opacity" } else { "rows" };
                    if let Some(sl) = self.slider(name) {
                        let sc = f64::from(self.scenes[BAR].window().scale_factor());
                        self.slide(i, sl.dragged(v0, f64::from(at.0 - mx) / sc));
                    }
                }
                None => {}
            }
        }
        let fading = self.chip.visible && self.chip.ring.moving(self.ms());
        if self.spinning() || fading {
            self.layout(self.pos[PANEL]);
        }
        if self.drag.is_none() && (self.tile.is_none() || up) && !self.spinning() && !fading {
            self.frame_timer.stop();
            self.layout(self.pos[PANEL]);
        }
    }

    /// The panel to `to`, the chip's row with it.
    fn move_to(&mut self, to: (i32, i32)) {
        let (dx, dy) = (to.0 - self.pos[PANEL].0, to.1 - self.pos[PANEL].1);
        if (dx, dy) == (0, 0) {
            return;
        }
        if let Some(e) = self.chip.entry.as_mut() {
            e.rect = Rect::new(e.rect.x + dx, e.rect.y + dy, e.rect.w, e.rect.h);
            if let Some(t) = e.tile.as_mut() {
                t.0 = Rect::new(t.0.x + dx, t.0.y + dy, t.0.w, t.0.h);
            }
        }
        self.layout(to);
    }

    // ---- tooltips ----------------------------------------------------------

    fn want_tip(&mut self, text: String) {
        if self.tip_want.as_ref().is_none_or(|(t, _)| *t != text) {
            self.hide_tip();
            self.tip_want = Some((text, Instant::now()));
        }
    }

    pub(super) fn hide_tip(&mut self) {
        self.tip_want = None;
        self.tip_up = None;
        if let Some(t) = self.tip.as_mut() {
            t.hide();
        }
    }

    /// A tooltip up once the pointer rests, down after a while.
    fn tip_poll(&mut self) {
        if self.tip_up.is_some_and(|t| t.elapsed() >= SHOW_TIP) {
            self.tip_up = None;
            if let Some(t) = self.tip.as_mut() {
                t.hide();
            }
            return;
        }
        let Some((text, since)) = self.tip_want.clone() else {
            return;
        };
        if self.tip_up.is_some() || since.elapsed() < TIP_REST || self.drag.is_some() {
            return;
        }
        let Some(at) = self.cursor() else { return };
        let dy = (20.0 * self.px()).round() as i32;
        if let Some(t) = self.tip.as_mut() {
            t.show(&text, at.0, at.1 + dy);
        }
        self.tip_up = Some(Instant::now());
    }

    // ---- the drive seam ----------------------------------------------------

    /// CHATQ_PANEL_DRIVE: the file's lines, each acted on once, the file
    /// then gone - a test's pointer, tray and hotkeys.
    fn drive_poll(&mut self) {
        let Some(path) = self.drive.clone() else {
            return;
        };
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let _ = std::fs::remove_file(&path);
        for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
            selflog::line(&format!(
                "ui drive: {}",
                line.split(' ').next().unwrap_or("")
            ));
            self.drive_line(line);
        }
        self.write_ui(true);
    }

    fn drive_line(&mut self, line: &str) {
        let (word, rest) = line.split_once(' ').unwrap_or((line, ""));
        match word {
            "hover" => {
                self.fake = match rest {
                    "-" => None,
                    "bar" => Some((
                        self.pos[BAR].0 + self.sizes[BAR].0 / 2,
                        self.pos[BAR].1 + (controls::BAR_H * self.px() / 2.0) as i32,
                    )),
                    key => self
                        .entries()
                        .iter()
                        .find(|e| eq(&e.key, key))
                        .map(|e| (e.rect.x + e.rect.w / 2, e.rect.y + e.rect.h / 2)),
                };
            }
            "click"
                if matches!(
                    rest,
                    "open"
                        | "delete"
                        | "ask-go"
                        | "ask-leave"
                        | "reload-go"
                        | "reload-later"
                        | "dont"
                        | "continue"
                ) =>
            {
                let now = self.ms();
                self.chip.st.armed = true;
                self.chip.press(rest, now);
                let c = self.chip.release(rest, now, self.opening.is_some());
                self.clicked(c);
            }
            "click" => self.press_part(rest),
            "set" => {
                let (name, v) = rest.split_once(' ').unwrap_or((rest, ""));
                if let Ok(v) = v.parse::<f64>() {
                    self.slide(Self::slider_index(name), v);
                }
            }
            "menu" => {
                let item = self
                    .menu()
                    .into_iter()
                    .find(|i| !i.name.is_empty() && i.name == rest);
                if let Some(i) = item {
                    self.menu_pick(i.name, &i.verb);
                }
            }
            "hotkey" => self.tray(trayicon::Ev::Hotkey(if rest == "console" {
                trayicon::CONSOLE
            } else {
                trayicon::MAIN
            })),
            // the query's answer in its place, seen at the next tick: on is
            // a D3D full screen (3), off accepting notifications (5), fail a
            // query that failed, and a number that state itself
            "full-screen" => {
                self.fake_full = match rest {
                    "on" => Some(3),
                    "off" => Some(5),
                    "fail" => None,
                    n => n.parse().ok(),
                }
            }
            "balloon-click" => self.tray(trayicon::Ev::BalloonClick),
            "tray-left" => self.tray(trayicon::Ev::Left),
            "edge" => {
                let (edge, dy) = rest.split_once(' ').unwrap_or((rest, "0"));
                let dy: i32 = dy.parse().unwrap_or(0);
                let start = (
                    self.rect.x + self.rect.w / 2,
                    if edge == "n" {
                        self.rect.y
                    } else {
                        self.rect.bottom()
                    },
                );
                self.fake = Some(start);
                self.start_size(edge == "n");
                self.size_to(start.1 + dy);
                self.end_drag();
                self.fake = None;
            }
            "move" => {
                let (dx, dy) = rest.split_once(' ').unwrap_or((rest, "0"));
                let (dx, dy): (i32, i32) = (dx.parse().unwrap_or(0), dy.parse().unwrap_or(0));
                let (x, y) = self.pos[PANEL];
                self.fake = Some((x, y));
                self.start_move();
                self.move_to((x + dx, y + dy));
                self.end_drag();
                self.fake = None;
            }
            _ => selflog::line(&format!("ui drive: no such line: {word}")),
        }
    }
}
