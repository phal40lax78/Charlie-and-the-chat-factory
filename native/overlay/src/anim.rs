// The mascot's atlas animator, docs/skin-pack.md section 6's second piece:
// the PNG of the mood on show decoded - one atlas at a time, never all
// seven - and the frame it is on, stepped by the panel's timer at the
// atlas's fps (App::mascot_step). `loop` wraps; `pingpong` runs back from
// the last frame, neither end shown twice. A mood switch starts the new
// atlas at frame 0; a redraw keeps the frame. A pack's sheet that fails to
// decode - the loader read only its header - plays the default skin's
// atlas for that mood, in one log line. The mood itself is idle until the
// mood switch, the next piece, picks it.

use std::time::Duration;

use slint::{Image, Rgba8Pixel, SharedPixelBuffer};

use crate::panel;
use crate::selflog;
use crate::skin::{self, AtlasMeta, Mood, Play, Skin};

/// The frame `step` steps into a mood: `loop` wraps at the last; `pingpong`
/// goes 0 .. frames - 1 and back down to 1, then again from 0.
pub fn frame_at(play: Play, frames: u32, step: u64) -> u32 {
    if frames <= 1 {
        return 0;
    }
    let n = u64::from(frames);
    let i = match play {
        Play::Loop => step % n,
        Play::Pingpong => {
            let period = 2 * (n - 1);
            let p = step % period;
            if p < n { p } else { period - p }
        }
    };
    i as u32
}

/// A sheet's PNG decoded to premultiplied RGBA, held to the decoded budget
/// (skin::MAX_DECODED_BYTES) before a pixel is made, and to the grid its
/// frame data gives (AtlasMeta::sheet): the loader checked the header, but
/// the file can change after it.
pub fn decode(bytes: &[u8], meta: &AtlasMeta) -> Result<SharedPixelBuffer<Rgba8Pixel>, String> {
    let bad = |e: png::DecodingError| format!("does not decode: {e}");
    let mut d = png::Decoder::new(std::io::Cursor::new(bytes));
    d.set_transformations(
        png::Transformations::EXPAND | png::Transformations::STRIP_16 | png::Transformations::ALPHA,
    );
    let mut r = d.read_info().map_err(bad)?;
    let (w, h) = (r.info().width, r.info().height);
    let size = u64::from(w) * u64::from(h) * 4;
    if size > skin::MAX_DECODED_BYTES {
        return Err(format!(
            "{w}x{h} is {size} bytes decoded, over {}",
            skin::MAX_DECODED_BYTES
        ));
    }
    let (sw, sh) = meta.sheet();
    if (w, h) != (sw, sh) {
        return Err(format!(
            "{w}x{h} is not the {sw}x{sh} sheet its frame data gives"
        ));
    }
    let mut out = SharedPixelBuffer::<Rgba8Pixel>::new(w, h);
    match r.output_color_type() {
        (png::ColorType::Rgba, png::BitDepth::Eight) => {
            r.next_frame(out.make_mut_bytes()).map_err(bad)?;
        }
        (png::ColorType::GrayscaleAlpha, png::BitDepth::Eight) => {
            let mut ga = vec![0; r.output_buffer_size().ok_or("too big to decode")?];
            r.next_frame(&mut ga).map_err(bad)?;
            for (px, s) in out.make_mut_slice().iter_mut().zip(ga.as_chunks::<2>().0) {
                *px = Rgba8Pixel::new(s[0], s[0], s[0], s[1]);
            }
        }
        (c, b) => return Err(format!("decodes to {c:?} at {b:?}, not 8-bit RGBA")),
    }
    let pre = |c: u8, a: u8| ((u16::from(c) * u16::from(a) + 127) / 255) as u8;
    for px in out.make_mut_slice().iter_mut().filter(|p| p.a < 255) {
        (px.r, px.g, px.b) = (pre(px.r, px.a), pre(px.g, px.a), pre(px.b, px.a));
    }
    Ok(out)
}

/// The atlas a mood plays, decoded: its frame data, its display size, the
/// image and its decoded bytes.
struct Sheet {
    meta: AtlasMeta,
    size: (f64, f64),
    image: Image,
    bytes: u64,
}

fn sheet_of(skin: &Skin, mood: Mood) -> Result<Sheet, String> {
    let a = skin.atlas_for(mood);
    let buf = a
        .png
        .bytes()
        .map_err(|e| format!("cannot be read: {e}"))
        .and_then(|b| decode(&b, &a.meta))?;
    let m = &skin.manifest.mascot;
    Ok(Sheet {
        meta: a.meta.clone(),
        size: (f64::from(m.w), f64::from(m.h)),
        bytes: u64::from(buf.width()) * u64::from(buf.height()) * 4,
        image: Image::from_rgba8_premultiplied(buf),
    })
}

/// `mood`'s sheet from `skin`, or, where it fails to decode, the default
/// skin's, with the line that says so.
fn open(skin: &Skin, mood: Mood) -> (Sheet, Option<String>) {
    match sheet_of(skin, mood) {
        Ok(s) => (s, None),
        Err(e) => {
            let face = skin.face(mood).as_str();
            let note = format!("skin {}: moods/{face}.png: {e}; using default", skin.id());
            let s = sheet_of(&Skin::default(), mood)
                .unwrap_or_else(|e| panic!("the built-in {face} atlas: {e}"));
            (s, Some(note))
        }
    }
}

/// The mascot as it plays: the skin, the mood on show, its one decoded
/// sheet and the steps taken since the mood came on.
pub struct Anim {
    skin: Skin,
    mood: Mood,
    sheet: Sheet,
    step: u64,
}

impl Anim {
    /// `skin` playing `mood` from frame 0, its sheet decoded.
    pub fn new(skin: Skin, mood: Mood) -> Anim {
        let (sheet, note) = open(&skin, mood);
        if let Some(n) = note {
            selflog::line(&n);
        }
        Anim {
            skin,
            mood,
            sheet,
            step: 0,
        }
    }

    /// Another mood: its sheet decoded in the old one's place, from frame
    /// 0; the same mood keeps its frame. The old sheet is let go first, so
    /// two are held only while the scene still draws the old one.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn set_mood(&mut self, mood: Mood) {
        if mood == self.mood {
            return;
        }
        self.sheet.image = Image::default();
        let (sheet, note) = open(&self.skin, mood);
        if let Some(n) = note {
            selflog::line(&n);
        }
        self.mood = mood;
        self.sheet = sheet;
        self.step = 0;
    }

    /// One step on, as the timer ticks.
    pub fn advance(&mut self) {
        self.step = self.step.wrapping_add(1);
    }

    pub fn frame(&self) -> u32 {
        let m = &self.sheet.meta;
        frame_at(m.play, m.frames, self.step)
    }

    /// The frame's cell of the sheet, [x, y, w, h] in its pixels.
    pub fn clip(&self) -> [u32; 4] {
        self.sheet.meta.clip(self.frame())
    }

    /// More than one frame: something for a timer to step.
    pub fn animates(&self) -> bool {
        self.sheet.meta.frames > 1
    }

    /// A frame's time at the atlas's fps.
    pub fn interval(&self) -> Duration {
        Duration::from_secs_f64(1.0 / f64::from(self.sheet.meta.fps.max(1)))
    }

    /// What the decoded sheet holds, in bytes: the one atlas.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn bytes(&self) -> u64 {
        self.sheet.bytes
    }

    /// The panel's mascot at the frame on now.
    pub fn mascot(&self) -> panel::Mascot {
        panel::Mascot {
            w: self.sheet.size.0,
            h: self.sheet.size.1,
            img: self.sheet.image.clone(),
            clip: self.clip(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn meta(frames: u32, w: u32, h: u32, cols: u32, play: Play) -> AtlasMeta {
        AtlasMeta {
            frames,
            fps: 15,
            w,
            h,
            cols,
            rows: frames.div_ceil(cols),
            play,
        }
    }

    /// A blank w x h PNG, 1 bit grey, as skin.rs's tests make them: a few
    /// hundred bytes whatever its size decoded.
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

    /// A folder of its own beside the test exe, emptied first.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("data")
            .join("anim-test")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn put(dir: &Path, rel: &str, bytes: &[u8]) {
        let p = dir.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, bytes).unwrap();
    }

    fn frames(play: Play, n: u32, steps: u64) -> Vec<u32> {
        (0..steps).map(|s| frame_at(play, n, s)).collect()
    }

    #[test]
    fn a_loop_wraps_at_its_last_frame() {
        assert_eq!(frames(Play::Loop, 4, 9), [0, 1, 2, 3, 0, 1, 2, 3, 0]);
        assert_eq!(frame_at(Play::Loop, 24, 23), 23);
        assert_eq!(frame_at(Play::Loop, 24, 24), 0);
        assert_eq!(frames(Play::Loop, 1, 3), [0, 0, 0]);
        assert_eq!(frame_at(Play::Loop, 24, u64::MAX), (u64::MAX % 24) as u32);
    }

    #[test]
    fn a_pingpong_turns_at_each_end_without_showing_it_twice() {
        assert_eq!(
            frames(Play::Pingpong, 4, 10),
            [0, 1, 2, 3, 2, 1, 0, 1, 2, 3]
        );
        assert_eq!(frames(Play::Pingpong, 2, 4), [0, 1, 0, 1]);
        assert_eq!(frames(Play::Pingpong, 1, 3), [0, 0, 0]);
        // 22 frames: up 0..21, back down to 1, 42 steps a round
        assert_eq!(frame_at(Play::Pingpong, 22, 21), 21);
        assert_eq!(frame_at(Play::Pingpong, 22, 22), 20);
        assert_eq!(frame_at(Play::Pingpong, 22, 41), 1);
        assert_eq!(frame_at(Play::Pingpong, 22, 42), 0);
    }

    /// 2048 x 1024 is 8,388,608 bytes decoded, the budget exactly: it
    /// decodes. A pixel more a side is over it, and refused before a pixel
    /// is made; a sheet not its grid is refused too.
    #[test]
    fn the_decoded_budget_holds_at_its_edge() {
        let at = meta(8, 256, 1024, 8, Play::Loop);
        let buf = decode(&blank_png(2048, 1024), &at).unwrap();
        assert_eq!(
            u64::from(buf.width()) * u64::from(buf.height()) * 4,
            skin::MAX_DECODED_BYTES
        );
        assert_eq!(skin::MAX_DECODED_BYTES, 8_388_608);
        // blank and grey: every pixel black, opaque
        assert!(buf.as_bytes().chunks(4).all(|p| p == [0, 0, 0, 255]));
        let over = meta(8, 256, 1025, 8, Play::Loop);
        assert_eq!(
            decode(&blank_png(2048, 1025), &over).unwrap_err(),
            "2048x1025 is 8396800 bytes decoded, over 8388608"
        );
        let wide = meta(1, 2049, 1024, 1, Play::Loop);
        assert_eq!(
            decode(&blank_png(2049, 1024), &wide).unwrap_err(),
            "2049x1024 is 8392704 bytes decoded, over 8388608"
        );
        assert_eq!(
            decode(&blank_png(512, 512), &at).unwrap_err(),
            "512x512 is not the 2048x1024 sheet its frame data gives"
        );
    }

    /// The default skin's idle: one sheet, 7,864,320 bytes, frame 0 at
    /// the start; stepped, a redraw keeps the frame; a mood switch starts
    /// the new sheet at frame 0 and still holds one; the same mood keeps
    /// its frame.
    #[test]
    fn one_sheet_is_held_and_a_mood_switch_starts_at_frame_0() {
        let mut a = Anim::new(Skin::default(), Mood::Idle);
        assert_eq!(a.bytes(), 1920 * 1024 * 4);
        assert!(a.animates());
        assert_eq!(a.interval(), Duration::from_secs_f64(1.0 / 15.0));
        assert_eq!(a.clip(), [0, 0, 320, 256]);
        for _ in 0..7 {
            a.advance();
        }
        assert_eq!(a.frame(), 7);
        assert_eq!(a.clip(), [320, 256, 320, 256]);
        let m = a.mascot();
        assert_eq!((m.w, m.h, m.clip), (160.0, 128.0, [320, 256, 320, 256]));
        assert_eq!(a.mascot().clip, m.clip, "a redraw keeps the frame");
        a.set_mood(Mood::Idle);
        assert_eq!(a.frame(), 7, "the same mood keeps its frame");
        a.set_mood(Mood::Ready);
        assert_eq!(a.frame(), 0);
        assert_eq!(a.bytes(), 1920 * 1024 * 4);
        assert_ne!(a.mascot().img, m.img, "the old sheet let go");
    }

    /// A pack whose idle sheet has a good header and nothing after it:
    /// the loader takes it, the decode fails, and the default skin's idle
    /// plays in its place with one line; its ready decodes as its own.
    #[test]
    fn a_sheet_that_fails_to_decode_plays_the_default_atlas() {
        let data = scratch("broken-sheet");
        let dir = data.join("skins").join("mini");
        let skin_json = r#"{ "format": 1, "id": "mini", "name": "Mini", "voice": "MINI",
            "mascot": { "w": 8, "h": 8, "scale": 1 }, "moods": ["idle", "ready"] }"#;
        put(&dir, "skin.json", skin_json.as_bytes());
        let frames =
            br#"{ "frames": 2, "fps": 10, "w": 8, "h": 8, "cols": 2, "play": "pingpong" }"#;
        put(&dir, "moods/idle.json", frames);
        put(&dir, "moods/ready.json", frames);
        // the signature and IHDR alone: 33 bytes
        put(&dir, "moods/idle.png", &blank_png(16, 8)[..33]);
        put(&dir, "moods/ready.png", &blank_png(16, 8));
        let s = skin::load(&data, "mini").unwrap();
        let (idle, note) = open(&s, Mood::Idle);
        let note = note.unwrap();
        assert!(
            note.starts_with("skin mini: moods/idle.png: does not decode: "),
            "{note}"
        );
        assert!(note.ends_with("; using default"), "{note}");
        assert_eq!((idle.meta.frames, idle.size), (24, (160.0, 128.0)));
        let (ready, note) = open(&s, Mood::Ready);
        assert_eq!(note, None);
        assert_eq!(
            (ready.meta.frames, ready.meta.play, ready.size, ready.bytes),
            (2, Play::Pingpong, (8.0, 8.0), 16 * 8 * 4)
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// A data folder with no skins/ in it: the default skin, its idle
    /// decoded and playing, no line logged.
    #[test]
    fn the_mascot_plays_with_no_skins_folder() {
        let data = scratch("no-skins");
        assert!(!data.join("skins").exists());
        let s = skin::load_or_default(&data, skin::DEFAULT);
        assert!(s.notes.is_empty(), "{:?}", s.notes);
        let (sheet, note) = open(&s, Mood::Idle);
        assert_eq!(note, None);
        assert_eq!(sheet.bytes, 7_864_320);
        let a = Anim::new(s, Mood::Idle);
        assert!(a.animates());
        assert_eq!(a.mascot().clip, [0, 0, 320, 256]);
        let _ = std::fs::remove_dir_all(&data);
    }
}
