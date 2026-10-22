// The panel's vector art, as the WPF overlay draws it, number for number:
// the seven-segment clock (Get-ChatOverlaySegGeometry), a tile's mark
// (New-ChatOverlayTileMark), the action and notice glyphs
// (Get-ChatOverlayActionGlyph, New-ChatOverlayNoticeGlyph), the bar's
// buttons (New-ChatOverlayControls) and a queued tile's dashes. A shape is
// a list of absolute path commands in f64, written out as the SVG text a
// Slint Path's `commands` reads. Pure.

pub type P = (f64, f64);

/// A WPF Matrix: (x, y) to (a x + c y + e, b x + d y + f).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Xf {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub e: f64,
    pub f: f64,
}

impl Xf {
    pub fn at(x: f64, y: f64) -> Xf {
        Xf {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            e: x,
            f: y,
        }
    }

    pub fn scale(s: f64, x: f64, y: f64) -> Xf {
        Xf {
            a: s,
            b: 0.0,
            c: 0.0,
            d: s,
            e: x,
            f: y,
        }
    }

    /// WPF's RotateTransform(degrees, cx, cy): clockwise on the screen.
    pub fn turn(degrees: f64, cx: f64, cy: f64) -> Xf {
        let (sin, cos) = degrees.to_radians().sin_cos();
        Xf {
            a: cos,
            b: sin,
            c: -sin,
            d: cos,
            e: cx - cx * cos + cy * sin,
            f: cy - cx * sin - cy * cos,
        }
    }

    /// This, then `next`.
    pub fn then(self, n: Xf) -> Xf {
        Xf {
            a: n.a * self.a + n.c * self.b,
            b: n.b * self.a + n.d * self.b,
            c: n.a * self.c + n.c * self.d,
            d: n.b * self.c + n.d * self.d,
            e: n.a * self.e + n.c * self.f + n.e,
            f: n.b * self.e + n.d * self.f + n.f,
        }
    }

    pub fn apply(&self, (x, y): P) -> P {
        (
            self.a * x + self.c * y + self.e,
            self.b * x + self.d * y + self.f,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Cmd {
    M(P),
    L(P),
    Q(P, P),
    A {
        r: P,
        rot: f64,
        large: bool,
        sweep: bool,
        to: P,
    },
    Z,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Shape(Vec<Cmd>);

impl Shape {
    /// The mini-language's absolute commands the overlay writes: M, L, H,
    /// V, Q, A and Z; a pair after M's first is a line, as in WPF.
    pub fn parse(d: &str) -> Shape {
        let mut out = Vec::new();
        let mut nums: Vec<f64> = Vec::new();
        let mut op = ' ';
        let mut at = (0.0, 0.0);
        let mut start = (0.0, 0.0);
        let flush =
            |op: char, nums: &mut Vec<f64>, out: &mut Vec<Cmd>, at: &mut P, start: &mut P| {
                let n = nums.len();
                let mut i = 0;
                let mut first = true;
                loop {
                    match op {
                        'M' | 'L' if i + 2 <= n => {
                            let p = (nums[i], nums[i + 1]);
                            out.push(if op == 'M' && first {
                                Cmd::M(p)
                            } else {
                                Cmd::L(p)
                            });
                            if op == 'M' && first {
                                *start = p;
                            }
                            *at = p;
                            i += 2;
                        }
                        'H' if i < n => {
                            *at = (nums[i], at.1);
                            out.push(Cmd::L(*at));
                            i += 1;
                        }
                        'V' if i < n => {
                            *at = (at.0, nums[i]);
                            out.push(Cmd::L(*at));
                            i += 1;
                        }
                        'Q' if i + 4 <= n => {
                            *at = (nums[i + 2], nums[i + 3]);
                            out.push(Cmd::Q((nums[i], nums[i + 1]), *at));
                            i += 4;
                        }
                        'A' if i + 7 <= n => {
                            *at = (nums[i + 5], nums[i + 6]);
                            out.push(Cmd::A {
                                r: (nums[i], nums[i + 1]),
                                rot: nums[i + 2],
                                large: nums[i + 3] != 0.0,
                                sweep: nums[i + 4] != 0.0,
                                to: *at,
                            });
                            i += 7;
                        }
                        'Z' if first => {
                            out.push(Cmd::Z);
                            *at = *start;
                        }
                        _ => break,
                    }
                    first = false;
                }
                nums.clear();
            };
        let mut word = String::new();
        let take = |word: &mut String, nums: &mut Vec<f64>| {
            if !word.is_empty() {
                nums.push(word.parse().expect("a number in a path"));
                word.clear();
            }
        };
        for ch in d.chars() {
            if ch.is_ascii_alphabetic() && ch != 'e' && ch != 'E' {
                take(&mut word, &mut nums);
                flush(op, &mut nums, &mut out, &mut at, &mut start);
                op = ch;
            } else if ch == ',' || ch.is_whitespace() {
                take(&mut word, &mut nums);
            } else if ch == '-' && !word.is_empty() && !word.ends_with(['e', 'E']) {
                take(&mut word, &mut nums);
                word.push(ch);
            } else {
                word.push(ch);
            }
        }
        take(&mut word, &mut nums);
        flush(op, &mut nums, &mut out, &mut at, &mut start);
        Shape(out)
    }

    /// WPF's EllipseGeometry, round: two half arcs from its right.
    pub fn circle(cx: f64, cy: f64, r: f64) -> Shape {
        let arc = |to| Cmd::A {
            r: (r, r),
            rot: 0.0,
            large: false,
            sweep: true,
            to,
        };
        Shape(vec![
            Cmd::M((cx + r, cy)),
            arc((cx - r, cy)),
            arc((cx + r, cy)),
            Cmd::Z,
        ])
    }

    /// A rounded rectangle from (x + r, y), clockwise.
    pub fn rrect(x: f64, y: f64, w: f64, h: f64, r: f64) -> Shape {
        let arc = |to| Cmd::A {
            r: (r, r),
            rot: 0.0,
            large: false,
            sweep: true,
            to,
        };
        let mut c = vec![Cmd::M((x + r, y)), Cmd::L((x + w - r, y))];
        if r > 0.0 {
            c.push(arc((x + w, y + r)));
        }
        c.push(Cmd::L((x + w, y + h - r)));
        if r > 0.0 {
            c.push(arc((x + w - r, y + h)));
        }
        c.push(Cmd::L((x + r, y + h)));
        if r > 0.0 {
            c.push(arc((x, y + h - r)));
        }
        c.push(Cmd::L((x, y + r)));
        if r > 0.0 {
            c.push(arc((x + r, y)));
        }
        c.push(Cmd::Z);
        Shape(c)
    }

    /// A closed polygon through `points`.
    pub fn poly(points: &[P]) -> Shape {
        let mut c = vec![Cmd::M(points[0])];
        c.extend(points[1..].iter().map(|&p| Cmd::L(p)));
        c.push(Cmd::Z);
        Shape(c)
    }

    pub fn and(mut self, other: Shape) -> Shape {
        self.0.extend(other.0);
        self
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The shape through `t`: a uniform scale, a turn and a move, as the
    /// overlay's transforms are, so an arc stays an arc.
    pub fn xf(&self, t: Xf) -> Shape {
        let s = (t.a * t.d - t.b * t.c).abs().sqrt();
        let turn = t.b.atan2(t.a).to_degrees();
        Shape(
            self.0
                .iter()
                .map(|c| match *c {
                    Cmd::M(p) => Cmd::M(t.apply(p)),
                    Cmd::L(p) => Cmd::L(t.apply(p)),
                    Cmd::Q(c, p) => Cmd::Q(t.apply(c), t.apply(p)),
                    Cmd::A {
                        r,
                        rot,
                        large,
                        sweep,
                        to,
                    } => Cmd::A {
                        r: (r.0 * s, r.1 * s),
                        rot: rot + turn,
                        large,
                        sweep,
                        to: t.apply(to),
                    },
                    Cmd::Z => Cmd::Z,
                })
                .collect(),
        )
    }

    /// As SVG path text, for a Slint Path's `commands`.
    pub fn svg(&self) -> String {
        let mut s = String::new();
        let pt = |s: &mut String, (x, y): P| {
            s.push_str(&num(x));
            s.push(' ');
            s.push_str(&num(y));
        };
        for c in &self.0 {
            if !s.is_empty() {
                s.push(' ');
            }
            match *c {
                Cmd::M(p) => {
                    s.push_str("M ");
                    pt(&mut s, p);
                }
                Cmd::L(p) => {
                    s.push_str("L ");
                    pt(&mut s, p);
                }
                Cmd::Q(c, p) => {
                    s.push_str("Q ");
                    pt(&mut s, c);
                    s.push(' ');
                    pt(&mut s, p);
                }
                Cmd::A {
                    r,
                    rot,
                    large,
                    sweep,
                    to,
                } => {
                    s.push_str("A ");
                    pt(&mut s, r);
                    s.push(' ');
                    s.push_str(&num(rot));
                    s.push_str(if large { " 1" } else { " 0" });
                    s.push_str(if sweep { " 1 " } else { " 0 " });
                    pt(&mut s, to);
                }
                Cmd::Z => s.push('Z'),
            }
        }
        s
    }

    /// Each figure as points, curves cut into short lines, and whether it
    /// closes.
    fn flat(&self) -> Vec<(Vec<P>, bool)> {
        let mut out: Vec<(Vec<P>, bool)> = Vec::new();
        let mut at = (0.0, 0.0);
        for c in &self.0 {
            match *c {
                Cmd::M(p) => {
                    out.push((vec![p], false));
                    at = p;
                }
                Cmd::L(p) => {
                    push(&mut out, at, p);
                    at = p;
                }
                Cmd::Q(c, p) => {
                    for i in 1..=32 {
                        let t = f64::from(i) / 32.0;
                        let u = 1.0 - t;
                        let q = (
                            u * u * at.0 + 2.0 * u * t * c.0 + t * t * p.0,
                            u * u * at.1 + 2.0 * u * t * c.1 + t * t * p.1,
                        );
                        push(&mut out, at, q);
                    }
                    at = p;
                }
                Cmd::A {
                    r,
                    rot,
                    large,
                    sweep,
                    to,
                } => {
                    for q in arc_points(at, r, rot, large, sweep, to) {
                        push(&mut out, at, q);
                    }
                    at = to;
                }
                Cmd::Z => {
                    if let Some(last) = out.last_mut() {
                        last.1 = true;
                        at = last.0[0];
                    }
                }
            }
        }
        out
    }

    /// The geometry's bounds, (left, top, right, bottom).
    pub fn bounds(&self) -> Option<(f64, f64, f64, f64)> {
        let mut b: Option<(f64, f64, f64, f64)> = None;
        for (pts, _) in self.flat() {
            for &(x, y) in &pts {
                b = Some(match b {
                    None => (x, y, x, y),
                    Some((l, t, r, bt)) => (l.min(x), t.min(y), r.max(x), bt.max(y)),
                });
            }
        }
        b
    }

    /// The stroke's bounds: the geometry's out by half the width - round
    /// caps and joins reach exactly that - and, for miter joins, each
    /// corner's tip within WPF's limit of 10.
    pub fn reach(&self, width: f64, miter: bool) -> Option<(f64, f64, f64, f64)> {
        let half = width / 2.0;
        let (mut l, mut t, mut r, mut b) = self.bounds()?;
        (l, t, r, b) = (l - half, t - half, r + half, b + half);
        if miter {
            for (pts, closed) in self.flat() {
                let n = pts.len();
                for i in 0..n {
                    let (prev, next) = match (i, closed) {
                        (0, false) => continue,
                        (_, false) if i == n - 1 => continue,
                        (0, true) => (pts[n - 1], pts[1 % n]),
                        _ => (pts[i - 1], pts[(i + 1) % n]),
                    };
                    if let Some((x, y)) = miter_tip(prev, pts[i], next, half) {
                        (l, t, r, b) = (l.min(x), t.min(y), r.max(x), b.max(y));
                    }
                }
            }
        }
        Some((l, t, r, b))
    }

    /// WPF's natural size for a Path of this shape with Stretch none: its
    /// stroke's right and bottom, the origin taken in.
    pub fn natural(&self, width: f64, miter: bool) -> (f64, f64) {
        self.reach(width, miter)
            .map_or((0.0, 0.0), |(_, _, r, b)| (r.max(0.0), b.max(0.0)))
    }

    /// Where a Path of this shape sits centred in a box, as WPF centres it.
    pub fn centred(&self, width: f64, miter: bool, w: f64, h: f64) -> Xf {
        let (nw, nh) = self.natural(width, miter);
        Xf::at((w - nw) / 2.0, (h - nh) / 2.0)
    }
}

fn push(out: &mut Vec<(Vec<P>, bool)>, at: P, p: P) {
    if out.is_empty() {
        out.push((vec![at], false));
    }
    out.last_mut().unwrap().0.push(p);
}

/// The tip of a miter join at `at`, if within the limit of 10.
fn miter_tip(prev: P, at: P, next: P, half: f64) -> Option<P> {
    let unit = |(x, y): P| {
        let l = (x * x + y * y).sqrt();
        (l > 1e-9).then(|| (x / l, y / l))
    };
    let u = unit((prev.0 - at.0, prev.1 - at.1))?;
    let v = unit((next.0 - at.0, next.1 - at.1))?;
    let cos = (u.0 * v.0 + u.1 * v.1).clamp(-1.0, 1.0);
    let sin_half = ((1.0 - cos) / 2.0).sqrt();
    if sin_half < 0.1 || sin_half > 0.9999 {
        return None;
    }
    let out = unit((-(u.0 + v.0), -(u.1 + v.1)))?;
    let len = half / sin_half;
    Some((at.0 + out.0 * len, at.1 + out.1 * len))
}

/// An SVG arc from `from` as points, no more than a degree apart; a
/// radius too short is grown as SVG grows it.
fn arc_points(from: P, r: P, rot: f64, large: bool, sweep: bool, to: P) -> Vec<P> {
    let (mut rx, mut ry) = (r.0.abs(), r.1.abs());
    if rx < 1e-9 || ry < 1e-9 || from == to {
        return vec![to];
    }
    let (sin, cos) = rot.to_radians().sin_cos();
    let (dx, dy) = ((from.0 - to.0) / 2.0, (from.1 - to.1) / 2.0);
    let (x1, y1) = (cos * dx + sin * dy, -sin * dx + cos * dy);
    let grow = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if grow > 1.0 {
        rx *= grow.sqrt();
        ry *= grow.sqrt();
    }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    let mut k = (num / den).max(0.0).sqrt();
    if large == sweep {
        k = -k;
    }
    let (cx1, cy1) = (k * rx * y1 / ry, -k * ry * x1 / rx);
    let (cx, cy) = (
        cos * cx1 - sin * cy1 + (from.0 + to.0) / 2.0,
        sin * cx1 + cos * cy1 + (from.1 + to.1) / 2.0,
    );
    let angle = |ux: f64, uy: f64| uy.atan2(ux);
    let a0 = angle((x1 - cx1) / rx, (y1 - cy1) / ry);
    let a1 = angle((-x1 - cx1) / rx, (-y1 - cy1) / ry);
    let mut da = a1 - a0;
    let tau = std::f64::consts::TAU;
    if sweep && da < 0.0 {
        da += tau;
    } else if !sweep && da > 0.0 {
        da -= tau;
    }
    let steps = (da.abs().to_degrees().ceil() as usize).max(1);
    (1..=steps)
        .map(|i| {
            if i == steps {
                return to;
            }
            let a = a0 + da * i as f64 / steps as f64;
            let (ex, ey) = (rx * a.cos(), ry * a.sin());
            (cos * ex - sin * ey + cx, sin * ex + cos * ey + cy)
        })
        .collect()
}

/// A number as short as it reads: four places at most, no trailing zeros.
pub fn num(v: f64) -> String {
    let s = format!("{v:.4}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" || s.is_empty() {
        "0".into()
    } else {
        s.into()
    }
}

/// A rounded rectangle's outline from (x + r, y), clockwise, as dashes:
/// `on` drawn, `off` skipped, from its start - WPF's StrokeDashArray on a
/// Rectangle, there in multiples of the stroke. Each dash an open figure,
/// for flat caps.
pub fn dashed_rrect(x: f64, y: f64, w: f64, h: f64, r: f64, on: f64, off: f64) -> Shape {
    use std::f64::consts::FRAC_PI_2;
    enum Piece {
        Line(P, P),
        Arc(P, f64),
    }
    let (l, t, rt, b) = (x, y, x + w, y + h);
    let pieces = [
        Piece::Line((l + r, t), (rt - r, t)),
        Piece::Arc((rt - r, t + r), -FRAC_PI_2),
        Piece::Line((rt, t + r), (rt, b - r)),
        Piece::Arc((rt - r, b - r), 0.0),
        Piece::Line((rt - r, b), (l + r, b)),
        Piece::Arc((l + r, b - r), FRAC_PI_2),
        Piece::Line((l, b - r), (l, t + r)),
        Piece::Arc((l + r, t + r), 2.0 * FRAC_PI_2),
    ];
    let length = |p: &Piece| match *p {
        Piece::Line(a, b) => ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt(),
        Piece::Arc(..) => r * FRAC_PI_2,
    };
    let point = |p: &Piece, s: f64| match *p {
        Piece::Line(a, b) => {
            let k = s / length(p).max(1e-9);
            (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k)
        }
        Piece::Arc(c, a0) => {
            let a = a0 + s / r;
            (c.0 + r * a.cos(), c.1 + r * a.sin())
        }
    };
    let total: f64 = pieces.iter().map(length).sum();
    let mut out = Vec::new();
    let mut s0 = 0.0;
    while s0 < total {
        let s1 = (s0 + on).min(total);
        // the dash from s0 to s1, piece by piece
        let mut base = 0.0;
        let mut first = true;
        for p in &pieces {
            let len = length(p);
            let (a, b) = (s0.max(base), s1.min(base + len));
            if b > a {
                if first {
                    out.push(Cmd::M(point(p, a - base)));
                    first = false;
                }
                let to = point(p, b - base);
                out.push(match p {
                    Piece::Line(..) => Cmd::L(to),
                    Piece::Arc(..) => Cmd::A {
                        r: (r, r),
                        rot: 0.0,
                        large: false,
                        sweep: true,
                        to,
                    },
                });
            }
            base += len;
        }
        s0 += on + off;
    }
    Shape(out)
}

// ---- the seven-segment clock (Get-ChatOverlaySegPoints, -SegGeometry)

pub const SEG_TALL: f64 = 26.0;
const SEG_WD: f64 = 13.0;
const SEG_TH: f64 = 3.2;

/// A row clock's cells' left edges, and its width and height.
pub struct SegDims {
    pub xs: [f64; 5],
    pub width: f64,
    pub height: f64,
    tan: f64,
    slant: f64,
    sep_w: f64,
}

pub fn seg_dims() -> SegDims {
    let cg = f64::max(1.2, SEG_WD * 0.2);
    let sep_w = SEG_WD * 0.66;
    let tan = (7.0 * std::f64::consts::PI / 180.0).tan();
    let slant = tan * SEG_TALL;
    let mut xs = [0.0; 5];
    let mut x = 0.0;
    for (i, slot) in xs.iter_mut().enumerate() {
        *slot = x;
        x += if i == 2 { sep_w } else { SEG_WD } + cg;
    }
    SegDims {
        xs,
        width: x - cg + slant + 1.0,
        height: SEG_TALL + 1.0,
        tan,
        slant,
        sep_w,
    }
}

/// One cell's segments a to g, each a hexagon's corners, upright.
fn seg_points(x: f64, y: f64, w: f64, tall: f64, t: f64) -> [[P; 6]; 7] {
    let h = t / 2.0;
    let g = f64::max(0.4, t * 0.18);
    let m = y + tall / 2.0;
    let hz = |x0: f64, x1: f64, yy: f64| {
        [
            (x0, yy),
            (x0 + h, yy - h),
            (x1 - h, yy - h),
            (x1, yy),
            (x1 - h, yy + h),
            (x0 + h, yy + h),
        ]
    };
    let vt = |y0: f64, y1: f64, xx: f64| {
        [
            (xx, y0),
            (xx + h, y0 + h),
            (xx + h, y1 - h),
            (xx, y1),
            (xx - h, y1 - h),
            (xx - h, y0 + h),
        ]
    };
    let (l, r, tp, b) = (x + h, x + w - h, y + h, y + tall - h);
    [
        hz(l + g, r - g, tp),
        vt(tp + g, m - g, r),
        vt(m + g, b - g, r),
        hz(l + g, r - g, b),
        vt(m + g, b - g, l),
        vt(tp + g, m - g, l),
        hz(l + g, r - g, m),
    ]
}

fn seg_lit(ch: char) -> &'static str {
    match ch {
        '0' => "abcdef",
        '1' => "bc",
        '2' => "abdeg",
        '3' => "abcdg",
        '4' => "bcfg",
        '5' => "acdfg",
        '6' => "acdefg",
        '7' => "abc",
        '8' => "abcdefg",
        '9' => "abcdfg",
        '-' => "g",
        _ => "",
    }
}

impl SegDims {
    /// Polygons slanted 7 degrees, half a unit in from the top left.
    fn slanted(&self, polys: &[[P; 6]], dx: f64) -> Shape {
        let mut s = Shape::default();
        for poly in polys {
            let pts: Vec<P> = poly
                .iter()
                .map(|&(x, y)| (dx + x - self.tan * y + self.slant + 0.5, y + 0.5))
                .collect();
            s = s.and(Shape::poly(&pts));
        }
        s
    }

    fn picked(cell: &[[P; 6]; 7], on: &str) -> Vec<[P; 6]> {
        on.bytes().map(|b| cell[(b - b'a') as usize]).collect()
    }

    /// Every digit's unlit segments, cells 0, 1, 3 and 4.
    pub fn ghost(&self) -> Shape {
        let mut s = Shape::default();
        for i in [0, 1, 3, 4] {
            let cell = seg_points(self.xs[i], 0.0, SEG_WD, SEG_TALL, SEG_TH);
            s = s.and(self.slanted(&Self::picked(&cell, "abcdefg"), 0.0));
        }
        s
    }

    /// What five characters light (Format-ChatOverlayRowClock's text): a
    /// digit or minus in cells 0, 1, 3 and 4, a colon or a small h or d in
    /// the separator's.
    pub fn lit(&self, text: &str) -> Shape {
        let chars: Vec<char> = text.chars().collect();
        let mut s = Shape::default();
        for (i, &dx) in self.xs.iter().enumerate() {
            let ch = chars.get(i).copied().unwrap_or(' ');
            if i != 2 {
                let cell = seg_points(0.0, 0.0, SEG_WD, SEG_TALL, SEG_TH);
                s = s.and(self.slanted(&Self::picked(&cell, seg_lit(ch)), dx));
                continue;
            }
            let small = seg_points(
                0.0,
                SEG_TALL * 0.38,
                self.sep_w,
                SEG_TALL * 0.62,
                SEG_TH * 0.7,
            );
            match ch.to_ascii_lowercase() {
                ':' => {
                    let a = SEG_TH * 0.95 / 2.0;
                    for cy in [SEG_TALL * 0.31, SEG_TALL * 0.71] {
                        let cx = self.sep_w / 2.0;
                        let sq = [
                            (cx - a, cy - a),
                            (cx + a, cy - a),
                            (cx + a, cy + a),
                            (cx - a, cy + a),
                        ];
                        let pts: Vec<P> = sq
                            .iter()
                            .map(|&(x, y)| (dx + x - self.tan * y + self.slant + 0.5, y + 0.5))
                            .collect();
                        s = s.and(Shape::poly(&pts));
                    }
                }
                'h' => s = s.and(self.slanted(&Self::picked(&small, "cefg"), dx)),
                'd' => s = s.and(self.slanted(&Self::picked(&small, "bcdeg"), dx)),
                _ => {}
            }
        }
        s
    }
}

// ---- a tile's mark (New-ChatOverlayTileMark), on its 16 x 14 box

/// The mark's stroke: 1.3 on its 14 x 12 grid, scaled into 16 x 14.
pub const MARK_STROKE: f64 = 1.3 * 16.0 / 14.0;

/// The mark's lines, and the part both stroked and filled (a play
/// triangle), in the 16 x 14 box. `mark`: tile_mark's word.
pub fn tile_mark(mark: &str, runs: bool) -> (Shape, Option<Shape>) {
    let s = 16.0 / 14.0;
    let m = Xf::scale(s, (16.0 - 14.0 * s) / 2.0, (14.0 - 12.0 * s) / 2.0);
    let mut line = if mark == "none" {
        Shape::circle(7.0, 6.0, 4.6)
    } else {
        Shape::rrect(0.75, 0.75, 12.5, 10.5, 2.0)
    };
    match mark {
        "vscode" => line = line.and(Shape::parse("M0.9,3.7 H13.1")),
        "terminal" => line = line.and(Shape::parse("M3.3,3.9 L5.4,6 L3.3,8.1 M7.2,8.3 H10.8")),
        _ => {}
    }
    let fill = match (mark, runs) {
        ("run", _) => Some(Shape::parse("M5.2,3.3 L9.6,6 L5.2,8.7 Z")),
        ("none", true) => Some(Shape::parse("M5.9,4.1 L8.9,6 L5.9,7.9 Z")),
        _ => None,
    };
    (line.xf(m), fill.map(|f| f.xf(m)))
}

// ---- the action glyphs (Get-ChatOverlayActionGlyph), 10 units square

pub const ACTION_STROKE: f64 = 1.2;

pub fn action_glyph(id: &str, label: &str) -> Shape {
    match (id, label) {
        ("open", "watch") => Shape::parse("M0.5,5.5 Q5,0.5 9.5,5.5 Q5,10.5 0.5,5.5 Z")
            .and(Shape::circle(5.0, 5.5, 1.6)),
        ("open", _) => Shape::parse("M4,1.5 H1.5 V9.5 H9.5 V7 M6.5,1.5 H9.5 V4.5 M9.5,1.5 L5,6"),
        _ => Shape::parse(
            "M1,2.5 H9 M3.75,2.5 V1 H6.25 V2.5 M2.25,2.5 L2.8,9.5 H7.2 L7.75,2.5 M4.2,4.5 V7.5 M5.8,4.5 V7.5",
        ),
    }
}

/// The glyph centred in its 20 x 14 box (New-ChatOverlayActionIcon).
pub fn action_icon(id: &str, label: &str) -> Shape {
    let g = action_glyph(id, label);
    let at = g.centred(ACTION_STROKE, false, 20.0, 14.0);
    g.xf(at)
}

// ---- a notice marker's glyph (New-ChatOverlayNoticeGlyph), 12 x 12

pub const NOTICE_STROKE: f64 = 1.3;

pub fn notice_glyph(tone: &str) -> Shape {
    Shape::parse(match tone {
        "error" => "M6,1 A5,5 0 1 1 5.99,1 Z M4.2,4.2 L7.8,7.8 M7.8,4.2 L4.2,7.8",
        "dim" | "faint" => "M6,1 A5,5 0 1 1 5.99,1 Z M6,5.4 V8.6 M6,3.5 V3.6",
        "unlocked" => "M2,5.5 H10 V10.8 H2 Z M3.8,5.5 V3.4 A2.2,2.2 0 0 1 8.2,3.4",
        _ => "M6,1.2 L11.2,10.6 H0.8 Z M6,4.6 V7.1 M6,8.8 V8.9",
    })
}

// ---- the bar's buttons (New-ChatOverlayControls), each in 22 x 20

pub const BUTTON_STROKE: f64 = 1.4;

/// The buttons left to right: fold, again, gear, min, max, close.
pub const BUTTONS: [&str; 6] = ["fold", "again", "gear", "min", "max", "close"];

/// A button's glyph, centred in its box as WPF centres it - round caps,
/// miter joins - and whether it is filled too (the gear's knobs). The
/// again arrow turned `spin` degrees about its arc's centre, as its
/// RenderTransform turns it, after it is placed.
pub fn button_glyph(which: &str, collapsed: bool, spin: f64) -> (Shape, bool) {
    let (g, fill) = button_raw(which, collapsed);
    let at = g.centred(BUTTON_STROKE, true, 22.0, 20.0);
    let t = if which == "again" && spin != 0.0 {
        Xf::turn(spin, 5.2, 5.3).then(at)
    } else {
        at
    };
    (g.xf(t), fill)
}

fn button_raw(which: &str, collapsed: bool) -> (Shape, bool) {
    match which {
        "fold" if collapsed => (Shape::parse("M0.5,1 L4.5,5 L8.5,1"), false),
        "fold" => (Shape::parse("M0.5,5 L4.5,1 L8.5,5"), false),
        "again" => (
            Shape::parse("M8.6,3.2 A4,4 0 1 0 9,6.5 M8.8,0.6 L8.7,3.4 L5.9,3.1"),
            false,
        ),
        "gear" => (
            Shape::parse("M0,2.5 L11,2.5 M0,8.5 L11,8.5")
                .and(Shape::circle(3.5, 2.5, 1.8))
                .and(Shape::circle(7.5, 8.5, 1.8)),
            true,
        ),
        "min" => (Shape::parse("M0.5,0.5 L8.5,0.5"), false),
        "max" => (Shape::parse("M0.5,0.5 L8.5,0.5 L8.5,8.5 L0.5,8.5 Z"), false),
        _ => (Shape::parse("M0.5,0.5 L8.5,8.5 M8.5,0.5 L0.5,8.5"), false),
    }
}

/// A shape set for a Path prim: the box it is drawn in - its stroke's
/// reach and a unit more, on whole units - and its commands from that
/// box's corner. None for nothing to draw.
pub fn boxed(shape: &Shape, stroke: f64, miter: bool) -> Option<(f64, f64, f64, f64, String)> {
    let (l, t, r, b) = shape.reach(stroke, miter)?;
    let (x, y) = ((l - 1.0).floor(), (t - 1.0).floor());
    let (w, h) = ((r + 1.0).ceil() - x, (b + 1.0).ceil() - y);
    Some((x, y, w, h, shape.xf(Xf::at(-x, -y)).svg()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-3
    }

    #[test]
    fn the_clock_has_the_mockups_numbers() {
        let d = seg_dims();
        let want = [0.0, 15.6, 31.2, 42.38, 57.98];
        assert!(
            d.xs.iter().zip(want).all(|(a, b)| near(*a, b)),
            "{:?}",
            d.xs
        );
        assert!(near(d.width, 75.1724), "{}", d.width);
        assert_eq!(d.height, 27.0);
        // an 8 lights all seven, a blank none; 12:34 lights 2 + 5 + 2 dots + 5 + 4
        assert_eq!(d.lit("8    ").svg().matches('M').count(), 7);
        assert!(d.lit("     ").is_empty());
        assert_eq!(d.lit("12:34").svg().matches('M').count(), 2 + 5 + 2 + 5 + 4);
        assert_eq!(d.lit(" 3h05").svg().matches('M').count(), 5 + 4 + 6 + 5);
        assert_eq!(d.lit("--:--").svg().matches('M').count(), 1 + 1 + 2 + 1 + 1);
        assert_eq!(d.ghost().svg().matches('M').count(), 28);
    }

    #[test]
    fn glyphs_sit_where_wpf_centres_them() {
        // the offsets WPF's layout gives each glyph, read from its natural
        // size: its stroke's right and bottom, the origin taken in
        let at = |g: &Shape, w: f64, miter: bool, bw: f64, bh: f64| g.centred(w, miter, bw, bh);
        let cases = [
            (action_glyph("delete", "delete"), (5.2, 1.95)),
            (action_glyph("open", "open"), (4.95, 1.95)),
            (action_glyph("open", "watch"), (4.95, 2.7)),
        ];
        for (g, (x, y)) in cases {
            let t = at(&g, ACTION_STROKE, false, 20.0, 14.0);
            assert!(near(t.e, x) && near(t.f, y), "{} {}", t.e, t.f);
        }
        // the bar's: miter joins, so the folded chevron's tip reaches 0.99
        // under its corner, not the 0.7 a round join would
        let bar = [
            ("min", false, (6.4, 9.4)),
            ("max", false, (6.4, 5.4)),
            ("close", false, (6.4, 5.4)),
            ("gear", false, (5.15, 4.5)),
            ("fold", false, (6.4, 7.15)),
            ("fold", true, (6.4, 7.005)),
        ];
        for (which, collapsed, (x, y)) in bar {
            let t = button_raw(which, collapsed)
                .0
                .centred(BUTTON_STROKE, true, 22.0, 20.0);
            assert!(near(t.e, x) && near(t.f, y), "{which}: {} {}", t.e, t.f);
        }
    }

    #[test]
    fn the_parser_reads_wpfs_short_forms() {
        let s = Shape::parse("M4,1.5 H1.5 V9.5");
        assert_eq!(s.svg(), "M 4 1.5 L 1.5 1.5 L 1.5 9.5");
        let a = Shape::parse("M6,1 A5,5 0 1 1 5.99,1 Z");
        assert_eq!(a.svg(), "M 6 1 A 5 5 0 1 1 5.99 1 Z");
        let (l, t, r, b) = a.bounds().unwrap();
        assert!(
            near(l, 0.995) && near(t, 1.0) && near(r, 10.995) && near(b, 11.0),
            "{l} {t} {r} {b}"
        );
        assert_eq!(num(-0.00001), "0");
        assert_eq!(num(2.25), "2.25");
    }

    #[test]
    fn a_queued_tile_dashes_from_its_top_left_round() {
        let d = dashed_rrect(0.75, 0.75, 136.5, 34.5, 6.0, 3.0, 2.25);
        let text = d.svg();
        assert!(
            text.starts_with("M 6.75 0.75 L 9.75 0.75 M 12 0.75"),
            "{text}"
        );
        // the outline's length over the pattern's
        let total = 2.0 * (124.5 + 22.5) + std::f64::consts::TAU * 6.0;
        assert_eq!(text.matches('M').count(), (total / 5.25).ceil() as usize);
    }

    #[test]
    fn a_turn_keeps_an_arc_on_its_circle() {
        // the again arrow's arc is about (5.2, 5.3), radius 4: turned about
        // that, every point stays within its circle
        let arc = Shape::parse("M8.6,3.2 A4,4 0 1 0 9,6.5");
        for deg in [0.0, 90.0, 200.0] {
            let (l, t, r, b) = arc.xf(Xf::turn(deg, 5.2, 5.3)).bounds().unwrap();
            assert!(
                l > 1.18 && t > 1.28 && r < 9.22 && b < 9.32,
                "{deg}: {l} {t} {r} {b}"
            );
        }
        let (x, y) = Xf::turn(90.0, 0.0, 0.0).apply((1.0, 0.0));
        assert!(near(x, 0.0) && near(y, 1.0), "clockwise on the screen");
    }
}
