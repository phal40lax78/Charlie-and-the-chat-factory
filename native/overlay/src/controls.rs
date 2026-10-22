// The controls window and the edges window, as the WPF overlay draws them:
// the bar of buttons along the panel's top strip and the settings box on
// one side of it (New-ChatOverlayControls, New-ChatOverlaySettings,
// New-ChatOverlayChips, Set-ChatOverlayControlsSide), and the two strips to
// size the panel by, with the accent line along the side one sizes
// (New-ChatOverlayEdgesWindow, Show-ChatOverlayEdgeHint). Pure: what each
// window draws and where it takes the pointer, in its own logical pixels;
// app.rs places the windows (model::controls_placement) and acts on the
// hits. The sliders are drawn as WPF's own template (Aero2's) draws them.

use crate::art::{self, Shape, Xf};
use crate::look::Look;
use crate::model::eq;
use crate::scene::{self, Draw, Font, Measure, Prim};

/// The bar's height, how far under the panel's top edge it sits and how
/// far in from its sides, and the gap from the box to the bar or the panel
/// ($script:ChatOverlayBarInset, BarIndent, BoxGap).
pub const BAR_H: f64 = 20.0;
pub const BAR_INSET: f64 = 4.0;
pub const BAR_INDENT: f64 = 8.0;
pub const BOX_GAP: f64 = 4.0;
pub const BOX_W: f64 = 280.0;
/// How far the edges' window reaches outside the panel, and how deep each
/// strip is: 4 out and 3 in ($script:ChatOverlayEdgeOut, EdgeIn).
pub const EDGE_OUT: f64 = 4.0;
pub const EDGE_DEEP: f64 = 7.0;
const BUTTON_W: f64 = 22.0;
const SMALL: Font = Font::new(11.0);
/// Aero2's slider: an 11 x 18 thumb on a track 4 tall, 5 in from each end.
const THUMB_W: f64 = 11.0;
const THUMB_H: f64 = 18.0;
const TRACK: (u32, u32) = (0xFFE7_EAEA, 0xFFD6_D6D6);
/// A slider's width: its column's, 184, less its right margin.
const SLIDER_W: f64 = 180.0;

const CUT_TIP: &str = "A chat the usage limit cuts off: Continue sends it \"Continue from where you left off.\" a minute after the reset - after a 529, once Claude is back. Ask says so once the limit is over, and continues it if you say so. Leave only marks it orange.";

/// The box's three choices: each a label and its chips, (name, hit, text).
#[allow(clippy::type_complexity)]
const CHOICES: [(&str, [(&str, &str, &str); 3]); 3] = [
    (
        "Theme",
        [
            ("dark", "theme:dark", "Dark"),
            ("light", "theme:light", "Light"),
            ("system", "theme:system", "System"),
        ],
    ),
    (
        "Recent",
        [
            ("off", "recent:off", "Off"),
            ("5", "recent:5", "5"),
            ("10", "recent:10", "10"),
        ],
    ),
    (
        "Cut off",
        [
            ("continue", "cut:continue", "Continue"),
            ("ask", "cut:ask", "Ask"),
            ("leave", "cut:leave", "Leave"),
        ],
    ),
];

/// A slider's thumb: at rest, under the pointer, or dragged.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Thumb {
    #[default]
    Still,
    Over,
    Held,
}

fn thumb_colors(t: Thumb) -> (u32, u32) {
    match t {
        Thumb::Still => (0xFFF0_F0F0, 0xFFAC_ACAC),
        Thumb::Over => (0xFFDC_ECFC, 0xFF7E_B4EA),
        Thumb::Held => (0xFFDA_ECFC, 0xFF56_9DE5),
    }
}

/// What the box shows: config.json's settings, the opacity the panel's.
pub struct Values<'a> {
    pub opacity: f64,
    pub rows: i64,
    pub theme: &'a str,
    pub recent: i64,
    /// config.json's autoContinue: on, ask or off
    pub auto: &'a str,
}

pub struct In<'a> {
    pub look: &'static Look,
    /// the panel's: the buttons take it, the bar and the box never
    pub opacity: f64,
    pub panel_w: f64,
    pub collapsed: bool,
    /// the again arrow's turn now, degrees (Update-ChatOverlaySpin)
    pub spin: f64,
    /// the settings box open, below the bar rather than above it, and
    /// the window's content flush left rather than right
    pub open: bool,
    pub below: bool,
    pub left: bool,
    pub values: Values<'a>,
    /// the opacity slider's thumb, then the rows slider's
    pub thumbs: [Thumb; 2],
}

/// One slider, in its window's units: where it is, its range, and whether
/// it snaps to whole numbers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slider {
    pub name: &'static str,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub min: f64,
    pub max: f64,
    pub snap: bool,
}

impl Slider {
    /// The value under `x`: a press off the thumb moves it there
    /// (IsMoveToPointEnabled, Track.ValueFromPoint).
    pub fn at(&self, x: f64) -> f64 {
        self.fit(
            self.min + (x - self.x - THUMB_W / 2.0) / (self.w - THUMB_W) * (self.max - self.min),
        )
    }

    /// The value once the thumb, pressed at `v0`, is dragged `dx` on: the
    /// thumb keeps where it was taken hold of (Slider.OnThumbDragDelta).
    pub fn dragged(&self, v0: f64, dx: f64) -> f64 {
        self.fit(v0 + dx * (self.max - self.min) / (self.w - THUMB_W))
    }

    /// In range, and snapped if it snaps: to the nearer whole step, a tie
    /// to the next (Slider.SnapToTick).
    fn fit(&self, v: f64) -> f64 {
        let v = v.clamp(self.min, self.max);
        if self.snap {
            (self.min + (v - self.min + 0.5).floor()).min(self.max)
        } else {
            v
        }
    }

    /// The thumb's rect for `v`, on a whole unit (SnapsToDevicePixels).
    pub fn thumb(&self, v: f64) -> [f64; 4] {
        let r = ((v - self.min) / (self.max - self.min)).clamp(0.0, 1.0);
        [
            (self.x + r * (self.w - THUMB_W)).round(),
            self.y,
            THUMB_W,
            THUMB_H,
        ]
    }
}

pub struct Controls {
    pub prims: Vec<Prim>,
    /// the window's size
    pub w: f64,
    pub h: f64,
    /// the box's own height, 0 shut: the placement's -Box
    pub box_h: f64,
    /// what takes the pointer, bottom first
    pub hits: Vec<(&'static str, [f64; 4])>,
    /// what the window keeps of itself (win32::set_region): the bar and the
    /// box, never the gap between them
    pub region: Vec<[f64; 4]>,
    pub sliders: Vec<Slider>,
}

/// The tooltip a hit has, if any (the WPF ToolTips): the bar's, each
/// button's, the cut-off label's and its chips'.
pub fn tip(id: &str, collapsed: bool) -> Option<&'static str> {
    Some(match id {
        "bar" => "Drag to move - drag the panel's top or bottom edge for more or fewer rows",
        "fold" if collapsed => "Expand",
        "fold" => "Collapse to one line",
        "again" => "Ask Claude, Codex and Copilot for usage now",
        "gear" => "Settings - opacity, rows, theme, recent chats, cut-off chats",
        "min" => "Minimize to the tray - click the tray icon to show it",
        "max" => {
            "Maximize: the console, in the panel's place - write to a chat, queue, continue; Esc brings the panel back"
        }
        "close" => {
            "Close the overlay - it stays closed until you next sign in, or until charlie starts it"
        }
        "tip:cut" => CUT_TIP,
        "cut:continue" => "Continue each chat the limit cuts off, by itself.",
        "cut:ask" => {
            "Once the limit is over, say how many chats it cut off, and continue them on a click."
        }
        "cut:leave" => {
            "Only mark them - Continue in the console, or chatq '<title>' -Continue, queues one."
        }
        _ => return None,
    })
}

/// The topmost hit at (x, y): the last that holds it, '' for none.
pub fn part_at(hits: &[(&'static str, [f64; 4])], x: f64, y: f64) -> &'static str {
    hits.iter()
        .rev()
        .find(|(_, r)| x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3])
        .map_or("", |(id, _)| id)
}

fn slider_row(lh: f64) -> f64 {
    lh.max(THUMB_H + 2.0)
}

/// A row of chips: each a line and 5 tall, 2 clear above and below.
fn choice_row(lh: f64) -> f64 {
    lh + 9.0
}

/// The box's height: its rows, its padding (5 each end) and its edge.
fn box_height(lh: f64) -> f64 {
    2.0 * slider_row(lh) + 3.0 * choice_row(lh) + 12.0
}

/// The controls window's content. Above, the box comes first and the bar
/// at its foot, the gap and the bar's inset between; below, the bar first
/// and the box the gap under it. Shut, the bar alone.
pub fn build(i: &In, m: &dyn Measure) -> Controls {
    let bar_w = (i.panel_w - 2.0 * BAR_INDENT).max(0.0);
    let lh = m.size("Opacity", SMALL, None, 0).1;
    let box_h = if i.open { box_height(lh) } else { 0.0 };
    let w = if i.open { BOX_W.max(bar_w) } else { bar_w };
    let (bar_y, box_y, h) = match (i.open, i.below) {
        (false, _) => (0.0, 0.0, BAR_H),
        (true, true) => (0.0, BAR_H + BOX_GAP, BAR_H + BOX_GAP + box_h),
        (true, false) => (
            box_h + BOX_GAP + BAR_INSET,
            0.0,
            box_h + BOX_GAP + BAR_INSET + BAR_H,
        ),
    };
    let at = |width: f64| if i.left { 0.0 } else { w - width };
    let mut c = Controls {
        prims: Vec::new(),
        w,
        h,
        box_h,
        hits: Vec::new(),
        region: Vec::new(),
        sliders: Vec::new(),
    };
    if i.open {
        settings(&mut c, i, m, at(BOX_W), box_y, lh, box_h);
    }
    bar(&mut c, i, at(bar_w), bar_y, bar_w);
    c
}

/// The bar, painted at an alpha of 1 in 255 so it takes the pointer, and
/// never under the panel's opacity, which would take that to nothing; its
/// buttons at its right end, at the panel's opacity, each lit 'hover'
/// under the pointer.
fn bar(c: &mut Controls, i: &In, x: f64, y: f64, w: f64) {
    let mut d = Draw::new(i.opacity);
    d.add_at(scene::rect(x, y, w, BAR_H, 0.0, 0x0100_0000, 0, 0.0), 1.0);
    d.add_at(scene::hit("bar", x, y, w, BAR_H, 0.0, scene::MOVE, 0), 1.0);
    c.hits.push(("bar", [x, y, w, BAR_H]));
    c.region.push([x, y, w, BAR_H]);
    let dim = i.look.argb("dim");
    let x0 = x + w - BUTTON_W * art::BUTTONS.len() as f64;
    for (k, &id) in art::BUTTONS.iter().enumerate() {
        let bx = x0 + BUTTON_W * k as f64;
        d.add(scene::hit(
            id,
            bx,
            y,
            BUTTON_W,
            BAR_H,
            4.0,
            scene::ARROW,
            i.look.argb("hover"),
        ));
        c.hits.push((id, [bx, y, BUTTON_W, BAR_H]));
        let (g, fill) = art::button_glyph(id, i.collapsed, i.spin);
        d.add_opt(scene::path(
            &g.xf(Xf::at(bx, y)),
            if fill { dim } else { 0 },
            dim,
            art::BUTTON_STROKE,
            true,
            false,
        ));
    }
    c.prims.extend(d.prims);
}

fn label(x: f64, y: f64, lh: f64, s: &str, look: &Look) -> Prim {
    scene::text(x, y, 44.0, lh, s, look.argb("dim"), SMALL, false, 1, 0)
}

/// The settings box at (x, y), at full opacity, as its window is: a grid of
/// label (44), slider or chips (184) and value (30), inside a padding of
/// 10 by 5 and a 1-unit edge.
#[allow(clippy::too_many_arguments)]
fn settings(c: &mut Controls, i: &In, m: &dyn Measure, x: f64, y: f64, lh: f64, h: f64) {
    let look = i.look;
    let mut d = Draw::new(1.0);
    d.border(
        x,
        y,
        BOX_W,
        h,
        6.0,
        look.argb("panel"),
        look.argb("edge"),
        1.0,
    );
    c.region.push([x, y, BOX_W, h]);
    let (c0, mut gy) = (x + 11.0, y + 6.0);
    let (c1, c2) = (c0 + 44.0, c0 + 228.0);
    let v = &i.values;
    let opacity = v.opacity.clamp(0.3, 1.0);
    let rows = v.rows.clamp(1, 30);
    let sliders = [
        (
            "Opacity",
            "opacity",
            ("slider:opacity", "thumb:opacity"),
            (0.3, 1.0, false),
            opacity,
            format!("{}%", (opacity * 100.0).round_ties_even() as i64),
        ),
        (
            "Rows",
            "rows",
            ("slider:rows", "thumb:rows"),
            (1.0, 30.0, true),
            rows as f64,
            rows.to_string(),
        ),
    ];
    for (k, (name, key, (sid, tid), (min, max, snap), value, said)) in
        sliders.into_iter().enumerate()
    {
        let rh = slider_row(lh);
        d.add(label(c0, gy + (rh - lh) / 2.0, lh, name, look));
        let s = Slider {
            name: key,
            x: c1,
            y: gy + 1.0 + (rh - 2.0 - THUMB_H) / 2.0,
            w: SLIDER_W,
            min,
            max,
            snap,
        };
        d.add(scene::rect(
            s.x + 5.0,
            s.y + (THUMB_H - 4.0) / 2.0,
            s.w - 10.0,
            4.0,
            0.0,
            TRACK.0,
            TRACK.1,
            1.0,
        ));
        let t = s.thumb(value);
        let (fill, stroke) = thumb_colors(i.thumbs[k]);
        d.add(scene::rect(t[0], t[1], t[2], t[3], 0.0, fill, stroke, 1.0));
        d.add(scene::hit(
            sid,
            s.x,
            s.y,
            s.w,
            THUMB_H,
            0.0,
            scene::ARROW,
            0,
        ));
        c.hits.push((sid, [s.x, s.y, s.w, THUMB_H]));
        d.add(scene::hit(
            tid,
            t[0],
            t[1],
            t[2],
            t[3],
            0.0,
            scene::ARROW,
            0,
        ));
        c.hits.push((tid, t));
        d.add(scene::text(
            c2,
            gy + (rh - lh) / 2.0,
            30.0,
            lh,
            &said,
            look.argb("text"),
            SMALL,
            false,
            1,
            2,
        ));
        c.sliders.push(s);
        gy += rh;
    }
    let cut = match v.auto.to_ascii_lowercase().as_str() {
        "on" => "continue",
        "ask" => "ask",
        _ => "leave",
    };
    let recent = if v.recent <= 0 {
        "off".to_string()
    } else {
        v.recent.to_string()
    };
    for (name, chips) in CHOICES {
        let rh = choice_row(lh);
        let ly = gy + (rh - lh) / 2.0;
        d.add(label(c0, ly, lh, name, look));
        if name == "Cut off" {
            d.add(scene::hit(
                "tip:cut",
                c0,
                ly,
                44.0,
                lh,
                0.0,
                scene::ARROW,
                0,
            ));
            c.hits.push(("tip:cut", [c0, ly, 44.0, lh]));
        }
        let now = match name {
            "Theme" => v.theme,
            "Recent" => recent.as_str(),
            _ => cut,
        };
        let (mut cx, cy) = (c1, gy + 2.0);
        for (chip, id, text) in chips {
            let on = eq(chip, now);
            let tw = m.size(text, SMALL, None, 0).0;
            let (cw, ch) = (tw + 18.0, lh + 5.0);
            let fill = if on { look.argb("accent") } else { 0 };
            d.border(
                cx,
                cy,
                cw,
                ch,
                4.0,
                fill,
                look.argb(if on { "accent" } else { "edge" }),
                1.0,
            );
            d.add(scene::text(
                cx + 9.0,
                cy + 2.0,
                tw,
                lh,
                text,
                look.argb(if on { "onAccent" } else { "text" }),
                SMALL,
                false,
                1,
                0,
            ));
            d.add(scene::hit(id, cx, cy, cw, ch, 4.0, scene::HAND, 0));
            c.hits.push((id, [cx, cy, cw, ch]));
            cx += cw + 4.0;
        }
        gy += rh;
    }
    c.prims.extend(d.prims);
}

pub struct Edges {
    pub prims: Vec<Prim>,
    pub hits: Vec<(&'static str, [f64; 4])>,
    /// the two strips, and the accent line's band while it shows
    pub region: Vec<[f64; 4]>,
}

/// The accent line along one side of a box `w` x `h`: what WPF's Border
/// draws for a CornerRadius of 8 and an edge 2 thick on that side alone -
/// its outer corners 9 by 8 round, its inner ones 7 by 8 (Border's Radii).
fn hint_shape(side: &str, w: f64, h: f64) -> Option<Shape> {
    let n = art::num;
    let d = match side {
        "n" => format!(
            "M0,10 L0,8 A9,8 0 0 1 9,0 L{},0 A9,8 0 0 1 {},8 L{},10 A7,8 0 0 0 {},2 L7,2 A7,8 0 0 0 0,10 Z",
            n(w - 9.0),
            n(w),
            n(w),
            n(w - 7.0)
        ),
        "s" => format!(
            "M0,{} L0,{} A9,8 0 0 0 9,{} L{},{} A9,8 0 0 0 {},{} L{},{} A7,8 0 0 1 {},{} L7,{} A7,8 0 0 1 0,{} Z",
            n(h - 10.0),
            n(h - 8.0),
            n(h),
            n(w - 9.0),
            n(h),
            n(w),
            n(h - 8.0),
            n(w),
            n(h - 10.0),
            n(w - 7.0),
            n(h - 2.0),
            n(h - 2.0),
            n(h - 10.0)
        ),
        _ => return None,
    };
    Some(Shape::parse(&d))
}

/// The edges window's content at its size, `w` x `h` (the panel's rect
/// and EDGE_OUT round it): a strip across its top and one across its
/// bottom, painted at an alpha of 1 in 255 so they take the pointer, and
/// the accent line along the side `hint` names (n, s, or '' for none),
/// over the panel's own edge and under the strips. Folded, nothing: one
/// line has no rows to add or take.
pub fn edges(look: &Look, w: f64, h: f64, collapsed: bool, hint: &str) -> Edges {
    let mut e = Edges {
        prims: Vec::new(),
        hits: Vec::new(),
        region: Vec::new(),
    };
    if collapsed {
        return e;
    }
    let (hw, hh) = (w - 2.0 * EDGE_OUT, h - 2.0 * EDGE_OUT);
    if let Some(shape) = hint_shape(hint, hw, hh) {
        let p = scene::path(
            &shape.xf(Xf::at(EDGE_OUT, EDGE_OUT)),
            look.argb("accent"),
            0,
            0.0,
            false,
            false,
        );
        e.prims.extend(p);
        let y = if hint == "n" {
            EDGE_OUT
        } else {
            h - EDGE_OUT - 10.0
        };
        e.region.push([EDGE_OUT, y, hw, 10.0]);
    }
    for (id, y) in [("edge:n", 0.0), ("edge:s", h - EDGE_DEEP)] {
        e.prims
            .push(scene::rect(0.0, y, w, EDGE_DEEP, 0.0, 0x0100_0000, 0, 0.0));
        e.prims
            .push(scene::hit(id, 0.0, y, w, EDGE_DEEP, 0.0, scene::UP_DOWN, 0));
        e.hits.push((id, [0.0, y, w, EDGE_DEEP]));
        e.region.push([0.0, y, w, EDGE_DEEP]);
    }
    e
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::look;
    use crate::scene::Fixed;

    fn input(theme: &str, open: bool, below: bool) -> In<'static> {
        In {
            look: look(theme),
            opacity: 0.9,
            panel_w: 162.0,
            collapsed: false,
            spin: 0.0,
            open,
            below,
            left: false,
            values: Values {
                opacity: 0.9,
                rows: 8,
                theme: "dark",
                recent: 5,
                auto: "ask",
            },
            thumbs: [Thumb::Still; 2],
        }
    }

    fn hit<'a>(c: &'a Controls, id: &str) -> &'a [f64; 4] {
        &c.hits
            .iter()
            .find(|(h, _)| *h == id)
            .unwrap_or_else(|| panic!("no {id}"))
            .1
    }

    #[test]
    fn the_bar_is_the_panels_strip_and_its_buttons_sit_at_its_right_end() {
        let c = build(&input("dark", false, false), &Fixed);
        assert_eq!((c.w, c.h, c.box_h), (146.0, 20.0, 0.0));
        assert_eq!(c.region, vec![[0.0, 0.0, 146.0, 20.0]]);
        assert_eq!(*hit(&c, "bar"), [0.0, 0.0, 146.0, 20.0]);
        assert_eq!(*hit(&c, "fold"), [14.0, 0.0, 22.0, 20.0]);
        assert_eq!(*hit(&c, "close"), [124.0, 0.0, 22.0, 20.0]);
        assert_eq!(part_at(&c.hits, 15.0, 10.0), "fold");
        assert_eq!(part_at(&c.hits, 5.0, 10.0), "bar");
        assert_eq!(part_at(&c.hits, 145.9, 19.9), "close");
        assert_eq!(part_at(&c.hits, 146.0, 10.0), "");
        assert!(c.sliders.is_empty());
        // the buttons at the panel's opacity, the bar never under it
        assert_eq!(c.prims[0].opacity, 1.0);
        assert!(
            c.prims[2..]
                .iter()
                .all(|p| (f64::from(p.opacity) - 0.9).abs() < 1e-6)
        );
    }

    #[test]
    fn the_box_goes_above_with_the_bar_at_its_foot_or_below_the_bar() {
        let c = build(&input("dark", true, false), &Fixed);
        // two slider rows of 20, three chip rows of 15 + 9, 12 of padding and edge
        assert_eq!((c.w, c.h, c.box_h), (280.0, 152.0, 124.0));
        assert_eq!(
            c.region,
            vec![[0.0, 0.0, 280.0, 124.0], [134.0, 132.0, 146.0, 20.0]]
        );
        let c = build(&input("dark", true, true), &Fixed);
        assert_eq!((c.w, c.h), (280.0, 148.0));
        assert_eq!(
            c.region,
            vec![[0.0, 24.0, 280.0, 124.0], [134.0, 0.0, 146.0, 20.0]]
        );
        let mut i = input("dark", true, true);
        i.left = true;
        let c = build(&i, &Fixed);
        assert_eq!(
            c.region,
            vec![[0.0, 24.0, 280.0, 124.0], [0.0, 0.0, 146.0, 20.0]]
        );
        assert_eq!(*hit(&c, "slider:opacity"), [55.0, 31.0, 180.0, 18.0]);
        assert_eq!(*hit(&c, "slider:rows"), [55.0, 51.0, 180.0, 18.0]);
        // the chips: a line and 5 tall, 18 wider than their words, 4 apart
        assert_eq!(*hit(&c, "theme:dark"), [55.0, 72.0, 40.0, 20.0]);
        assert_eq!(*hit(&c, "theme:light"), [99.0, 72.0, 46.0, 20.0]);
        assert_eq!(*hit(&c, "cut:continue"), [55.0, 120.0, 62.0, 20.0]);
        assert_eq!(*hit(&c, "tip:cut"), [11.0, 122.5, 44.0, 15.0]);
        assert_eq!(part_at(&c.hits, 56.0, 73.0), "theme:dark");
    }

    #[test]
    fn a_slider_moves_to_a_press_and_follows_its_thumb() {
        let mut i = input("dark", true, false);
        i.values.opacity = 1.0;
        let c = build(&i, &Fixed);
        let (o, r) = (c.sliders[0], c.sliders[1]);
        assert_eq!((o.name, o.x, o.y, o.w), ("opacity", 55.0, 7.0, 180.0));
        assert_eq!(o.at(55.0 + 5.5), 0.3);
        assert_eq!(o.at(55.0 + 180.0 - 5.5), 1.0);
        assert_eq!(o.at(0.0), 0.3);
        assert_eq!(o.thumb(1.0), [224.0, 7.0, 11.0, 18.0]);
        assert_eq!(*hit(&c, "thumb:opacity"), [224.0, 7.0, 11.0, 18.0]);
        assert_eq!(part_at(&c.hits, 225.0, 8.0), "thumb:opacity");
        assert_eq!(part_at(&c.hits, 200.0, 8.0), "slider:opacity");
        assert!((o.dragged(0.5, 169.0 / 7.0) - 0.6).abs() < 1e-9);
        assert_eq!(o.dragged(0.5, 169.0), 1.0);
        // rows: whole ones, a tie to the next
        assert_eq!((r.name, r.y, r.snap), ("rows", 27.0, true));
        assert_eq!(r.fit(2.5), 3.0);
        assert_eq!(r.fit(3.49), 3.0);
        assert_eq!(r.fit(3.5), 4.0);
        assert_eq!(r.fit(0.0), 1.0);
        assert_eq!(r.fit(31.0), 30.0);
        assert_eq!(r.at(55.0 + 5.5 + 169.0), 30.0);
    }

    #[test]
    fn the_box_says_its_values_and_fills_the_chip_in_force() {
        let mut i = input("dark", true, false);
        i.values = Values {
            opacity: 0.625,
            rows: 40,
            theme: "LIGHT",
            recent: 7,
            auto: "On",
        };
        let c = build(&i, &Fixed);
        let l = look("dark");
        let ink = |s: &str| {
            c.prims
                .iter()
                .find(|p| p.kind == 1 && p.text == s)
                .unwrap_or_else(|| panic!("no {s}"))
                .fill
        };
        let on = slint::Color::from_argb_encoded(l.argb("onAccent"));
        let off = slint::Color::from_argb_encoded(l.argb("text"));
        // 62.5 to the even 62, as [Math]::Round; rows held to 30
        assert_eq!(ink("62%"), off);
        assert_eq!(ink("30"), off);
        assert_eq!(ink("Light"), on);
        assert_eq!(ink("Dark"), off);
        // a count no chip names fills none
        assert!(["Off", "5", "10"].iter().all(|s| ink(s) == off));
        assert_eq!(ink("Continue"), on);
        assert_eq!(ink("Leave"), off);
    }

    #[test]
    fn the_edges_take_their_strips_and_the_line_shows_along_one_side() {
        let l = look("dark");
        let e = edges(l, 170.0, 60.0, false, "");
        assert_eq!(
            e.region,
            vec![[0.0, 0.0, 170.0, 7.0], [0.0, 53.0, 170.0, 7.0]]
        );
        assert_eq!(part_at(&e.hits, 10.0, 6.9), "edge:n");
        assert_eq!(part_at(&e.hits, 10.0, 30.0), "");
        assert_eq!(part_at(&e.hits, 10.0, 53.0), "edge:s");
        let e = edges(l, 170.0, 60.0, false, "n");
        assert_eq!(e.region[0], [4.0, 4.0, 162.0, 10.0]);
        assert_eq!(e.prims[0].kind, 2);
        let e = edges(l, 170.0, 60.0, false, "s");
        assert_eq!(e.region[0], [4.0, 46.0, 162.0, 10.0]);
        let e = edges(l, 170.0, 60.0, true, "n");
        assert!(e.prims.is_empty() && e.hits.is_empty() && e.region.is_empty());
    }

    #[test]
    fn the_tips_are_the_wpf_ones() {
        assert_eq!(tip("fold", true), Some("Expand"));
        assert_eq!(tip("fold", false), Some("Collapse to one line"));
        assert!(
            tip("tip:cut", false)
                .unwrap()
                .starts_with("A chat the usage limit cuts off")
        );
        assert!(
            tip("max", false)
                .unwrap()
                .ends_with("Esc brings the panel back")
        );
        assert_eq!(tip("theme:dark", false), None);
        assert_eq!(tip("slider:rows", false), None);
    }

    fn golden(name: &str, i: &In) {
        let (scene, win) = scene::golden::scene();
        let m = scene::Measurer::new(&scene);
        let c = build(i, &m);
        let (w, h) = (c.w.ceil() as u32, c.h.ceil() as u32);
        scene::show(&scene, c.prims);
        let rgb = scene::golden::render(&scene, &win, w, h);
        scene::golden::check(name, w, h, &rgb);
    }

    #[test]
    fn golden_controls_bar() {
        golden("controls-bar", &input("dark", false, false));
    }

    #[test]
    fn golden_controls_box_below_light() {
        let mut i = input("light", true, true);
        i.opacity = 0.6;
        i.values = Values {
            opacity: 0.6,
            rows: 6,
            theme: "system",
            recent: 5,
            auto: "ask",
        };
        i.thumbs = [Thumb::Over, Thumb::Still];
        golden("controls-box-below-light", &i);
    }

    #[test]
    fn golden_controls_box_above_folded_and_spinning() {
        let mut i = input("dark", true, false);
        i.collapsed = true;
        i.spin = 90.0;
        i.values = Values {
            opacity: 1.0,
            rows: 30,
            theme: "dark",
            recent: 0,
            auto: "on",
        };
        i.thumbs = [Thumb::Still, Thumb::Held];
        golden("controls-box-above-folded", &i);
    }

    fn golden_edges(name: &str, theme: &str, hint: &str) {
        let (scene, win) = scene::golden::scene();
        let e = edges(look(theme), 170.0, 60.0, false, hint);
        scene::show(&scene, e.prims);
        let rgb = scene::golden::render(&scene, &win, 170, 60);
        scene::golden::check(name, 170, 60, &rgb);
    }

    #[test]
    fn golden_edges_hint_n() {
        golden_edges("edges-hint-n", "dark", "n");
    }

    #[test]
    fn golden_edges_hint_s_light() {
        golden_edges("edges-hint-s-light", "light", "s");
    }
}
