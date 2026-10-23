// What every window of the panel draws: one Slint component, Scene, drawing
// a list of prims - rectangles, text, paths, the places that take the
// pointer and a cell of an image (the mascot's frame of its atlas, anim.rs)
// - each where Rust laid it out, in logical pixels. One list keeps
// the WPF overlay's order, later on top. Its texts are measured by Slint
// itself (Measure), wrapped and cut with an ellipsis by Slint too.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use slint::{ComponentHandle, Model, SharedString, VecModel};

use crate::art::{self, Shape};

slint::slint! {
    export struct Prim {
        // 0 a rectangle, 1 text, 2 a path, 3 a place that takes the
        // pointer, 4 an image's cell
        kind: int,
        x: length,
        y: length,
        w: length,
        h: length,
        radius: length,
        fill: color,
        stroke: color,
        sw: length,
        text: string,
        size: length,
        weight: int,
        // 0 left, 1 centre, 2 right
        align: int,
        wrap: bool,
        // at most this many lines, the last cut with an ellipsis; 0 any
        lines: int,
        // in Segoe UI Symbol: WPF's face for a mark Segoe UI has not, where
        // Slint's own fallback would draw an emoji
        symbol: bool,
        cmds: string,
        id: string,
        // 0 the arrow, 1 the hand, 2 move, 3 up and down
        cursor: int,
        hover: color,
        opacity: float,
        // 0 butt, 1 round
        cap: int,
        // 0 miter, 1 round
        join: int,
        // the image, and the cell of it drawn to the box, its pixels
        img: image,
        clip-x: int,
        clip-y: int,
        clip-w: int,
        clip-h: int,
    }

    export component Scene inherits Window {
        in property <[Prim]> prims;
        // the measure: a text set here, its size read back
        in property <string> m-text;
        in property <length> m-size: 12px;
        in property <int> m-weight: 400;
        in property <bool> m-symbol;
        in property <bool> m-wrap;
        in property <length> m-width;
        in property <int> m-lines;
        out property <length> m-w: measure.preferred-width;
        out property <length> m-h: measure.preferred-height;
        // a place's id, and down, up, cancel, enter or leave
        callback hit(string, string);
        no-frame: true;
        always-on-top: true;
        background: transparent;
        default-font-family: "Segoe UI";
        default-font-size: 12px;

        measure := Text {
            visible: false;
            text: root.m-text;
            font-size: root.m-size;
            font-weight: root.m-weight;
            font-family: root.m-symbol ? "Segoe UI Symbol" : "";
            wrap: root.m-wrap ? TextWrap.word-wrap : TextWrap.no-wrap;
            width: root.m-width;
            max-lines: root.m-lines;
            overflow: elide;
        }

        for p in root.prims: Rectangle {
            x: p.x;
            y: p.y;
            width: p.w;
            height: p.h;
            background: p.kind == 0 ? p.fill : transparent;
            border-color: p.kind == 0 ? p.stroke : transparent;
            border-width: p.kind == 0 ? p.sw : 0px;
            border-radius: p.radius;
            opacity: p.opacity;
            if p.kind == 1: Text {
                x: 0;
                y: 0;
                width: parent.width;
                height: parent.height;
                text: p.text;
                color: p.fill;
                font-size: p.size;
                font-weight: p.weight;
                font-family: p.symbol ? "Segoe UI Symbol" : "";
                horizontal-alignment: p.align == 1 ? TextHorizontalAlignment.center : p.align == 2 ? TextHorizontalAlignment.right : TextHorizontalAlignment.left;
                vertical-alignment: TextVerticalAlignment.top;
                wrap: p.wrap ? TextWrap.word-wrap : TextWrap.no-wrap;
                max-lines: p.lines;
                overflow: elide;
            }
            if p.kind == 2: Path {
                x: 0;
                y: 0;
                width: parent.width;
                height: parent.height;
                commands: p.cmds;
                fill: p.fill;
                stroke: p.stroke;
                stroke-width: p.sw;
                fit: preserve;
                stroke-line-cap: p.cap == 1 ? LineCap.round : LineCap.butt;
                stroke-line-join: p.join == 1 ? LineJoin.round : LineJoin.miter;
            }
            if p.kind == 4: Image {
                x: 0;
                y: 0;
                width: parent.width;
                height: parent.height;
                source: p.img;
                source-clip-x: p.clip-x;
                source-clip-y: p.clip-y;
                source-clip-width: p.clip-w;
                source-clip-height: p.clip-h;
                image-fit: fill;
            }
            if p.kind == 3: ta := TouchArea {
                x: 0;
                y: 0;
                width: parent.width;
                height: parent.height;
                mouse-cursor: p.cursor == 1 ? MouseCursor.pointer : p.cursor == 2 ? MouseCursor.move : p.cursor == 3 ? MouseCursor.ns-resize : MouseCursor.default;
                Rectangle {
                    background: ta.has-hover ? p.hover : p.fill;
                    border-radius: p.radius;
                }
                pointer-event(e) => {
                    if e.kind == PointerEventKind.cancel {
                        root.hit(p.id, "cancel");
                    } else if e.button == PointerEventButton.left && e.kind != PointerEventKind.move {
                        root.hit(p.id, e.kind == PointerEventKind.down ? "down" : "up");
                    }
                }
                changed has-hover => {
                    root.hit(p.id, self.has-hover ? "enter" : "leave");
                }
            }
        }
    }
}

fn color(argb: u32) -> slint::Color {
    slint::Color::from_argb_encoded(argb)
}

fn blank() -> Prim {
    Prim {
        opacity: 1.0,
        weight: 400,
        ..Default::default()
    }
}

/// A rectangle: `fill` inside, `stroke` `sw` wide inside its edge, as a
/// WPF Border draws (0 for none, 0xAARRGGBB).
#[allow(clippy::too_many_arguments)]
pub fn rect(x: f64, y: f64, w: f64, h: f64, radius: f64, fill: u32, stroke: u32, sw: f64) -> Prim {
    Prim {
        kind: 0,
        x: x as f32,
        y: y as f32,
        w: w as f32,
        h: h as f32,
        radius: radius as f32,
        fill: color(fill),
        stroke: color(stroke),
        sw: if stroke >> 24 == 0 { 0.0 } else { sw as f32 },
        ..blank()
    }
}

/// How a text is set: its size, weight and face.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Font {
    pub size: f64,
    pub weight: i32,
    pub symbol: bool,
}

impl Font {
    pub const fn new(size: f64) -> Font {
        Font {
            size,
            weight: 400,
            symbol: false,
        }
    }

    pub const fn bold(self) -> Font {
        Font {
            weight: 600,
            ..self
        }
    }

    /// In Segoe UI Symbol (Prim's `symbol`).
    pub const fn symbol(self) -> Font {
        Font {
            symbol: true,
            ..self
        }
    }
}

/// A text at (x, y), `w` wide - wrapped there if `wrap` - and `h` tall.
#[allow(clippy::too_many_arguments)]
pub fn text(
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    s: &str,
    argb: u32,
    font: Font,
    wrap: bool,
    lines: i32,
    align: i32,
) -> Prim {
    Prim {
        kind: 1,
        x: x as f32,
        y: y as f32,
        w: w as f32,
        h: h as f32,
        text: s.into(),
        fill: color(argb),
        size: font.size as f32,
        weight: font.weight,
        symbol: font.symbol,
        wrap,
        lines,
        align,
        ..blank()
    }
}

/// A shape drawn in its own box, which its stroke never leaves
/// (art::boxed); None for an empty shape.
pub fn path(
    shape: &Shape,
    fill: u32,
    stroke: u32,
    sw: f64,
    round: bool,
    round_join: bool,
) -> Option<Prim> {
    let miter = !round_join;
    let (x, y, w, h, cmds) = art::boxed(shape, if stroke >> 24 == 0 { 0.0 } else { sw }, miter)?;
    Some(Prim {
        kind: 2,
        x: x as f32,
        y: y as f32,
        w: w as f32,
        h: h as f32,
        cmds: cmds.into(),
        fill: color(fill),
        stroke: color(stroke),
        sw: sw as f32,
        cap: i32::from(round),
        join: i32::from(round_join),
        ..blank()
    })
}

/// The cell `clip` ([x, y, w, h], the image's pixels) of `img`, drawn to
/// fill the box at (x, y), `w` x `h`.
pub fn image(x: f64, y: f64, w: f64, h: f64, img: &slint::Image, clip: [u32; 4]) -> Prim {
    let [cx, cy, cw, ch] = clip.map(|v| i32::try_from(v).unwrap_or(i32::MAX));
    Prim {
        kind: 4,
        x: x as f32,
        y: y as f32,
        w: w as f32,
        h: h as f32,
        img: img.clone(),
        clip_x: cx,
        clip_y: cy,
        clip_w: cw,
        clip_h: ch,
        ..blank()
    }
}

/// The image prim at `i` of the scene's list moved to the cell `clip`, the
/// rest of the list left alone: the mascot's frame stepped between redraws.
pub fn set_clip(scene: &Scene, i: usize, clip: [u32; 4]) {
    let model = scene.get_prims();
    let Some(mut p) = model.row_data(i).filter(|p| p.kind == 4) else {
        return;
    };
    let [cx, cy, cw, ch] = clip.map(|v| i32::try_from(v).unwrap_or(i32::MAX));
    if (p.clip_x, p.clip_y, p.clip_w, p.clip_h) == (cx, cy, cw, ch) {
        return;
    }
    (p.clip_x, p.clip_y, p.clip_w, p.clip_h) = (cx, cy, cw, ch);
    model.set_row_data(i, p);
}

pub const ARROW: i32 = 0;
pub const HAND: i32 = 1;
pub const MOVE: i32 = 2;
pub const UP_DOWN: i32 = 3;

/// A place that takes the pointer, `id` its name to Rust: lit `hover` under
/// the pointer (0 for never).
#[allow(clippy::too_many_arguments)]
pub fn hit(id: &str, x: f64, y: f64, w: f64, h: f64, radius: f64, cursor: i32, hover: u32) -> Prim {
    Prim {
        kind: 3,
        x: x as f32,
        y: y as f32,
        w: w as f32,
        h: h as f32,
        radius: radius as f32,
        id: id.into(),
        cursor,
        hover: color(hover),
        ..blank()
    }
}

/// As `hit`, on a ground of its own, `fill`, which `hover` stands in for
/// under the pointer - as a WPF element's Background set on MouseEnter.
#[allow(clippy::too_many_arguments)]
pub fn hit_on(
    id: &str,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    radius: f64,
    cursor: i32,
    fill: u32,
    hover: u32,
) -> Prim {
    Prim {
        fill: color(fill),
        ..hit(
            id,
            x,
            y,
            w,
            h,
            radius,
            cursor,
            if hover >> 24 == 0 { fill } else { hover },
        )
    }
}

/// Prims as one list, each at `opacity` (the panel's, on what it fades).
#[derive(Default)]
pub struct Draw {
    pub prims: Vec<Prim>,
    pub opacity: f32,
}

impl Draw {
    pub fn new(opacity: f64) -> Draw {
        Draw {
            prims: Vec::new(),
            opacity: opacity as f32,
        }
    }

    pub fn add(&mut self, mut p: Prim) {
        p.opacity *= self.opacity;
        self.prims.push(p);
    }

    pub fn add_opt(&mut self, p: Option<Prim>) {
        if let Some(p) = p {
            self.add(p);
        }
    }

    /// As `add`, at `opacity` of its own instead.
    pub fn add_at(&mut self, mut p: Prim, opacity: f64) {
        p.opacity = opacity as f32;
        self.prims.push(p);
    }

    /// A WPF Border: `fill` inside its edge, the edge `t` wide in
    /// `stroke`, `r` its CornerRadius - which WPF takes as the edge's
    /// middle: the outer corners r + t/2 round, the inner ones r - t/2
    /// (Border's Radii). Two prims where both show, so a see-through edge
    /// is not drawn over the fill, as WPF draws neither under the other.
    #[allow(clippy::too_many_arguments)]
    pub fn border(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        r: f64,
        fill: u32,
        stroke: u32,
        t: f64,
    ) {
        let edge = stroke >> 24 != 0 && t > 0.0;
        if !edge {
            self.add(rect(x, y, w, h, r, fill, 0, 0.0));
            return;
        }
        if fill >> 24 != 0 {
            let inner = if r > 0.0 { (r - t / 2.0).max(0.0) } else { 0.0 };
            self.add(rect(
                x + t,
                y + t,
                w - 2.0 * t,
                h - 2.0 * t,
                inner,
                fill,
                0,
                0.0,
            ));
        }
        let outer = if r > 0.0 { r + t / 2.0 } else { 0.0 };
        self.add(rect(x, y, w, h, outer, 0, stroke, t));
    }
}

/// The scene's prims to `new`: rows that differ set in place, the list
/// itself only when its length changes.
pub fn show(scene: &Scene, new: Vec<Prim>) {
    let model = scene.get_prims();
    if let Some(vec) = model.as_any().downcast_ref::<VecModel<Prim>>()
        && vec.row_count() == new.len()
    {
        for (i, p) in new.into_iter().enumerate() {
            if vec.row_data(i).as_ref() != Some(&p) {
                vec.set_row_data(i, p);
            }
        }
        return;
    }
    scene.set_prims(Rc::new(VecModel::from(new)).into());
}

/// What measures a text: Slint's own layout of it, through the scene's
/// hidden Text, kept per text and setting.
pub trait Measure {
    /// (width, height) of `s` in `font`, wrapped at `wrap` if given, at
    /// most `lines` lines (0 any).
    fn size(&self, s: &str, font: Font, wrap: Option<f64>, lines: i32) -> (f64, f64);
}

type Key = (SharedString, i32, i32, bool, i32, i32);

pub struct Measurer {
    scene: slint::Weak<Scene>,
    kept: RefCell<HashMap<Key, (f64, f64)>>,
}

impl Measurer {
    pub fn new(scene: &Scene) -> Measurer {
        Measurer {
            scene: scene.as_weak(),
            kept: RefCell::new(HashMap::new()),
        }
    }
}

impl Measure for Measurer {
    fn size(&self, s: &str, font: Font, wrap: Option<f64>, lines: i32) -> (f64, f64) {
        let key: Key = (
            s.into(),
            (font.size * 100.0) as i32,
            font.weight,
            font.symbol,
            wrap.map_or(-1, |w| (w * 100.0) as i32),
            lines,
        );
        if let Some(&v) = self.kept.borrow().get(&key) {
            return v;
        }
        let Some(scene) = self.scene.upgrade() else {
            return (0.0, 0.0);
        };
        scene.set_m_text(s.into());
        scene.set_m_size(font.size as f32);
        scene.set_m_weight(font.weight);
        scene.set_m_symbol(font.symbol);
        scene.set_m_wrap(wrap.is_some());
        scene.set_m_width(wrap.unwrap_or(0.0) as f32);
        scene.set_m_lines(lines);
        let v = (f64::from(scene.get_m_w()), f64::from(scene.get_m_h()));
        let mut kept = self.kept.borrow_mut();
        if kept.len() > 4000 {
            kept.clear();
        }
        kept.insert(key, v);
        v
    }
}

/// A measure of fixed metrics, for the tests that want no fonts: 6 units a
/// character at 12, a line 4/3 of the size, wrapped by whole widths.
#[cfg(test)]
pub struct Fixed;

#[cfg(test)]
impl Measure for Fixed {
    fn size(&self, s: &str, font: Font, wrap: Option<f64>, lines: i32) -> (f64, f64) {
        let w = (s.encode_utf16().count() as f64 * font.size / 2.0).ceil();
        let lh = (font.size * 4.0 / 3.0).ceil();
        match wrap {
            Some(at) if at > 0.0 && w > at => {
                let n = (w / at).ceil();
                let n = if lines > 0 {
                    n.min(f64::from(lines))
                } else {
                    n
                };
                (at, lh * n)
            }
            _ => (w, lh),
        }
    }
}

/// Renders scenes off the screen, as the tests' golden pictures: Slint's
/// software renderer on a window of its own per scene, as RGB - the
/// renderer clears to the window's see-through ground first, so what the
/// scene leaves bare comes out black.
#[cfg(test)]
pub mod golden {
    use std::cell::RefCell;
    use std::path::PathBuf;
    use std::rc::Rc;

    use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType};
    use slint::platform::{Platform, WindowAdapter};
    use slint::{ComponentHandle, PhysicalSize, Rgb8Pixel};

    use super::Scene;

    thread_local! {
        static LAST: RefCell<Option<Rc<MinimalSoftwareWindow>>> = const { RefCell::new(None) };
    }

    struct Offscreen;

    impl Platform for Offscreen {
        fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
            let w = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
            LAST.with(|l| *l.borrow_mut() = Some(w.clone()));
            Ok(w)
        }
    }

    /// A scene on a window of its own, this thread's platform the
    /// off-screen one.
    pub fn scene() -> (Scene, Rc<MinimalSoftwareWindow>) {
        let _ = slint::platform::set_platform(Box::new(Offscreen));
        let s = Scene::new().unwrap();
        let w = LAST
            .with(|l| l.borrow_mut().take())
            .expect("the scene's window");
        (s, w)
    }

    /// The scene drawn at `w` x `h` logical pixels, scale 1, as RGB.
    pub fn render(scene: &Scene, win: &MinimalSoftwareWindow, w: u32, h: u32) -> Vec<u8> {
        win.set_size(PhysicalSize::new(w, h));
        scene.show().unwrap();
        let mut px = vec![Rgb8Pixel { r: 0, g: 0, b: 0 }; (w * h) as usize];
        win.request_redraw();
        win.draw_if_needed(|r| {
            r.render(&mut px, w as usize);
        });
        scene.hide().unwrap();
        px.iter().flat_map(|p| [p.r, p.g, p.b]).collect()
    }

    fn dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("goldens")
    }

    fn write(path: &PathBuf, w: u32, h: u32, rgb: &[u8]) {
        let f = std::fs::File::create(path).unwrap();
        let mut e = png::Encoder::new(std::io::BufWriter::new(f), w, h);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(rgb).unwrap();
    }

    fn read(path: &PathBuf) -> Option<(u32, u32, Vec<u8>)> {
        let d = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).ok()?));
        let mut r = d.read_info().ok()?;
        let mut buf = vec![0; r.output_buffer_size()?];
        let info = r.next_frame(&mut buf).ok()?;
        buf.truncate(info.buffer_size());
        Some((info.width, info.height, buf))
    }

    /// The picture against goldens/<name>.png: the same pixels, or a panic
    /// with goldens/<name>.actual.png beside it to look at. CHATQ_GOLDENS
    /// set to write writes the golden instead (TESTING.md says when).
    pub fn check(name: &str, w: u32, h: u32, rgb: &[u8]) {
        let want = dir().join(format!("{name}.png"));
        let actual = dir().join(format!("{name}.actual.png"));
        std::fs::create_dir_all(dir()).unwrap();
        if std::env::var("CHATQ_GOLDENS").as_deref() == Ok("write") {
            write(&want, w, h, rgb);
            let _ = std::fs::remove_file(&actual);
            return;
        }
        match read(&want) {
            Some((gw, gh, g)) if gw == w && gh == h && g == rgb => {
                let _ = std::fs::remove_file(&actual);
            }
            got => {
                write(&actual, w, h, rgb);
                let differ = got.as_ref().map_or(0, |(_, _, g)| {
                    g.chunks(3)
                        .zip(rgb.chunks(3))
                        .filter(|(a, b)| a != b)
                        .count()
                });
                panic!(
                    "{name}: the picture is not its golden ({}; {differ} pixels differ) - see {}",
                    if got.is_some() {
                        "differs"
                    } else {
                        "no golden"
                    },
                    actual.display()
                );
            }
        }
    }
}
