// The overlay's UI in Slint (M9), on Slint's software renderer on winit +
// softbuffer. Its own run is the panel the headless PowerShell host starts
// (app.rs); the M9 spike's modes, carried over from native/spikes/overlay,
// stay beside it until the panel has what they proved.
//
//   <data folder>      the panel: draws <data folder>/overlay.json, answers
//                      in overlay-ui.json, ends when stdin closes (app.rs)
//   --since MS         (panel) the host's commands from before MS, the
//                      Unix ms it started its first panel at, are not its own
//   --floor           one empty, fully transparent window: the memory floor
//   --probe            a speech bubble with Hangul, Chinese, Georgia, symbols
//                      and a clock, plus an automatic per-pixel alpha check
//   --cycles N         (probe) hide and re-show N times, once a second
//   --mouse            step 2, the mouse model: a panel with strips that
//                      take clicks while it is locked (mouse.rs)
//   --glued            step 3, the overlay's five windows glued to the
//                      panel: placing, z-order, flash, height (glue.rs)
//   --scale            the five glued windows waiting for the user to
//                      change Windows' display scale; each change is
//                      followed by a re-place and the checks (glue.rs)
//   --poke             (scale) after the self-test, send the spike's own
//                      windows WM_DPICHANGED to another DPI and back, late
//                      and in a check round, with nothing really changed
//   --pretend          (scale) after the self-test, pretend Windows' scale
//                      went to 150% (100% if it is at 150%), and after the
//                      next round back; each window is sent WM_DPICHANGED
//                      as the real change reached them (win32::pretend_dpi)
//   --tray             step 4: tray icon, tooltip, menu, balloons and the
//                      spike's own hotkey, ending in a close balloon and a
//                      4 s delayed exit (tray.rs)
//   --second           (tray) a second instance: only the same hotkey,
//                      which must come back taken
//   --standin          (tray) the hand checks stood in for by messages
//                      posted to the spike's own windows (tray/standin.rs)
//   --gate             step 5, the gate hour: steps 1-4 at once in one
//                      process, drawn from the live data/overlay.json (read
//                      only), the collector's reads stood in for on a worker
//                      thread, a sample a minute and a summary at exit
//                      (gate.rs); implies --exercise
//   --ui-only          (gate) the same without the read-load stand-in and
//                      with overlay.json read once: the 10-minute side run
//   --exercise         (gate) a timer drives chip, card, settings slider,
//                      opacity and click-through; always on with --gate
//   --seconds N        exit by itself after N seconds (default 60); --tray
//                      and --gate then close, 4 s more
//
// The spike's modes log to <exe dir>/data/spike.log, the panel to <data
// folder>/logs/overlay-panel.log (selflog.rs). Windows only.

// No console window on start, from the PowerShell host or a click: a panic
// still reaches the log (selflog::start's hook).
#![windows_subsystem = "windows"]

mod app;
mod art;
mod card;
mod chip;
mod clock;
mod controls;
mod gate;
mod glue;
mod look;
mod model;
mod mouse;
mod open;
mod panel;
mod scene;
mod selflog;
mod snapshot;
mod tooltip;
mod tray;
mod trayicon;
mod ui;
mod win32;

use std::path::PathBuf;
use std::time::Duration;

use slint::ComponentHandle;
use slint::winit_030::{WinitWindowAccessor, winit};
use windows::Win32::Foundation::HWND;

slint::slint! {
    export component Floor inherits Window {
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 360px;
        height: 220px;
    }

    export component Probe inherits Window {
        in property <string> clock;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 360px;
        height: 220px;

        // The body is inset 4px so the window's own edge pixels must be
        // see-through too; win32::sample_alpha reads them.
        Rectangle {
            x: 4px;
            y: 4px;
            width: parent.width - 8px;
            height: 180px;
            border-radius: 14px;
            background: #1e1f24;
        }
        // The tail, under the body's left part.
        Path {
            x: 40px;
            y: 183px;
            width: 28px;
            height: 33px;
            fill: #1e1f24;
            commands: "M 0 0 L 28 0 L 2 33 Z";
        }
        VerticalLayout {
            x: 18px;
            y: 12px;
            width: parent.width - 36px;
            height: 166px;
            spacing: 4px;
            Text { text: "한글 채팅 대기열"; font-size: 18px; color: #f0f0f0; }
            Text { text: "聊天队列"; font-size: 18px; color: #f0f0f0; }
            Text { text: "Charlie"; font-family: "Georgia"; font-size: 20px; color: #f0e0c0; }
            Text { text: "● ◐ ▶ ✓ ⚠ ⏱"; font-size: 18px; color: #9fd0ff; }
            Text { text: root.clock; font-size: 16px; color: #c0c0c0; }
        }
    }
}

const WIDTH: i32 = 360;
const HEIGHT: i32 = 220;
const MARGIN: i32 = 24;

struct Args {
    probe: bool,
    mouse: bool,
    glued: bool,
    scale: bool,
    poke: bool,
    pretend: bool,
    tray: bool,
    second: bool,
    standin: bool,
    gate: bool,
    ui_only: bool,
    seconds: u64,
    cycles: u32,
    /// the panel's run: the host's data folder
    data: Option<PathBuf>,
    /// the panel's run: when the host started it, Unix ms
    since: Option<i64>,
}

fn parse_args() -> Args {
    let mut args = Args {
        probe: false,
        mouse: false,
        glued: false,
        scale: false,
        poke: false,
        pretend: false,
        tray: false,
        second: false,
        standin: false,
        gate: false,
        ui_only: false,
        seconds: 60,
        cycles: 0,
        data: None,
        since: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut number = || it.next().and_then(|v| v.parse::<u64>().ok());
        match arg.as_str() {
            "--floor" => args.probe = false,
            "--probe" => args.probe = true,
            "--mouse" => args.mouse = true,
            "--glued" => args.glued = true,
            "--scale" => args.scale = true,
            "--poke" => args.poke = true,
            "--pretend" => args.pretend = true,
            "--tray" => args.tray = true,
            "--second" => args.second = true,
            "--standin" => args.standin = true,
            "--gate" => args.gate = true,
            "--ui-only" => (args.gate, args.ui_only) = (true, true),
            // the gate's exercise is always on; the flag names it
            "--exercise" => args.gate = true,
            "--seconds" => args.seconds = number().expect("--seconds N"),
            "--cycles" => args.cycles = number().expect("--cycles N") as u32,
            "--since" => args.since = number().map(|v| v as i64),
            other if !other.starts_with("--") && args.data.is_none() => {
                args.data = Some(PathBuf::from(other))
            }
            other => panic!("unknown argument {other}"),
        }
    }
    args
}

fn main() {
    let args = parse_args();
    let mode = if args.data.is_some() {
        "ui"
    } else if args.ui_only {
        "ui-only"
    } else if args.gate {
        "gate"
    } else if args.tray {
        "tray"
    } else if args.mouse {
        "mouse"
    } else if args.scale {
        "scale"
    } else if args.glued {
        "glued"
    } else if args.probe {
        "probe"
    } else {
        "floor"
    };
    // --poke, --pretend, --second and --standin named too: a log line says which run it came from
    let flag = |on: bool, name: &str| {
        if on {
            format!(" {name}")
        } else {
            String::new()
        }
    };
    let tests = format!(
        "{}{}{}{}",
        flag(args.poke, "--poke"),
        flag(args.pretend, "--pretend"),
        flag(args.second, "--second"),
        flag(args.standin, "--standin")
    );
    // The panel runs as long as its host: no run time, so the watchdog's is
    // out of reach (100 years). It logs in its host's data folder, as the
    // host's own logs are, a sample a minute: nothing of it goes elsewhere.
    let (log, seconds, every) = match &args.data {
        Some(data) => (
            data.join("logs").join("overlay-panel.log"),
            100 * 365 * 86_400,
            Duration::from_secs(60),
        ),
        None => (
            selflog::data_dir().join("spike.log"),
            args.seconds,
            Duration::from_secs(10),
        ),
    };
    selflog::start(
        log,
        &format!(
            "{mode}{tests} --seconds {} --cycles {}",
            args.seconds, args.cycles
        ),
        seconds,
        every,
    );

    slint::BackendSelector::new()
        .backend_name("winit".into())
        .renderer_name("software".into())
        .with_winit_window_attributes_hook(|attrs| {
            use winit::platform::windows::WindowAttributesExtWindows;
            selflog::line(&format!(
                "winit attributes: transparent={} visible={}",
                attrs.transparent, attrs.visible
            ));
            // active=false: winit's set_visible then shows with SW_SHOWNOACTIVATE
            // every time; with the default (true) it uses SW_SHOW, which
            // activates (winit window_state.rs, WindowFlags::apply_diff).
            // No drag and drop: skips winit's OleInitialize and RegisterDragDrop.
            // skip_taskbar: otherwise winit calls ITaskbarList::AddTab on create
            // and again whenever Explorer restarts (TaskbarCreated), whatever
            // the window's styles say (winit window.rs, InitData::on_create).
            attrs
                .with_active(false)
                .with_drag_and_drop(false)
                .with_skip_taskbar(true)
        })
        .select()
        .expect("winit backend with the software renderer");

    // Bottom-right of the work area, out of the user's way.
    let work = win32::work_area();
    let (x, y) = (work.right - WIDTH - MARGIN, work.bottom - HEIGHT - MARGIN);

    // Kept alive until the loop ends; dropping a Timer stops it.
    let mut timers = Vec::new();
    if let Some(data) = args.data {
        app::run(data, args.since);
    } else if args.gate {
        gate::run(args.ui_only, args.seconds);
    } else if args.tray {
        tray::run(args.second, args.standin, args.seconds);
    } else if args.mouse {
        mouse::start(work);
        run(args.seconds);
    } else if args.glued || args.scale {
        glue::start(args.scale, args.poke, args.pretend);
        run(args.seconds);
    } else if args.probe {
        han_fallbacks();
        let probe = Probe::new().unwrap();
        probe.set_clock(win32::local_hms().into());
        let weak = probe.as_weak();
        timers.push(repeat(Duration::from_secs(1), move || {
            if let Some(p) = weak.upgrade() {
                p.set_clock(win32::local_hms().into());
            }
        }));
        timers.push(repeat(Duration::from_secs(5), || {
            if let Some(hwnd) = win32::our_hwnd() {
                win32::reassert_topmost(hwnd);
            }
        }));
        let cycles = args.cycles;
        let p = probe.clone_strong();
        show_no_activate(&probe, x, y, move |hwnd| {
            selflog::line(&win32::dwm_evidence(hwnd));
            later(1500, move || alpha_check("start", hwnd));
            later(3000, move || {
                cycle(p, hwnd, 0, cycles, CycleStats::default())
            });
        });
        run(args.seconds);
    } else {
        let floor = Floor::new().unwrap();
        show_no_activate(&floor, x, y, |hwnd| {
            selflog::line(&win32::dwm_evidence(hwnd))
        });
        run(args.seconds);
    }
    drop(timers);
    selflog::finish();
}

/// Left alone, fontique asks DirectWrite for one Han font with no locale and
/// gets Yu Gothic (Japanese), which has no simplified forms: 队 in 聊天队列
/// was drawn as nothing at all, not even a box. A list of our own replaces
/// that pick, since fontique asks the system only for keys it has no list for.
fn han_fallbacks() {
    use slint::fontique_011::fontique::{FallbackKey, Script};
    let mut collection = slint::fontique_011::shared_collection();
    let names = [
        "Malgun Gothic",
        "Microsoft YaHei",
        "Microsoft JhengHei",
        "Yu Gothic",
    ];
    let families: Vec<_> = names
        .iter()
        .filter_map(|name| collection.family_id(name))
        .collect();
    selflog::line(&format!(
        "han fallbacks: {} of {} families found",
        families.len(),
        names.len()
    ));
    collection.set_fallbacks(
        FallbackKey::new(Script::from_bytes(*b"Hani"), None),
        families.into_iter(),
    );
}

fn run(seconds: u64) {
    slint::Timer::single_shot(Duration::from_secs(seconds), || {
        let _ = slint::quit_event_loop();
    });
    slint::run_event_loop_until_quit().unwrap();
}

fn repeat(interval: Duration, f: impl FnMut() + 'static) -> slint::Timer {
    let timer = slint::Timer::default();
    timer.start(slint::TimerMode::Repeated, interval, f);
    timer
}

fn later(ms: u64, f: impl FnOnce() + 'static) {
    slint::Timer::single_shot(Duration::from_millis(ms), f);
}

/// Slint creates every window hidden when the event loop starts (it registers
/// each new adapter for creation, winitwindowadapter.rs). Wait for that, give
/// the HWND the overlay's styles while it is still hidden, and only then show.
fn show_no_activate<C: ComponentHandle + 'static>(
    c: &C,
    x: i32,
    y: i32,
    shown: impl FnOnce(HWND) + 'static,
) {
    c.window().set_position(slint::PhysicalPosition::new(x, y));
    let c = c.clone_strong();
    slint::spawn_local(async move {
        let winit_window = c.window().winit_window().await.expect("winit window");
        let hwnd = win32::hwnd_of(&winit_window);
        selflog::line(&format!(
            "created hidden: visible={} exstyle={:#010x}",
            win32::is_visible(hwnd),
            win32::exstyle(hwnd)
        ));
        win32::make_overlay(hwnd);
        let before = win32::foreground();
        c.show().unwrap();
        let after = win32::foreground();
        selflog::line(&format!(
            "shown: exstyle={:#010x} styles_ok={} foreground {:?} -> {:?} (ours: {})",
            win32::exstyle(hwnd),
            win32::styles_ok(win32::exstyle(hwnd)),
            before.0,
            after.0,
            win32::is_ours(after)
        ));
        shown(hwnd);
    })
    .unwrap();
}

/// Puts a magenta window right behind the probe, reads screen pixels where
/// the probe should be see-through and where it is filled, saves a picture of
/// the area to data/, then removes the magenta window.
fn alpha_check(label: &'static str, hwnd: HWND) {
    let rect = win32::window_rect(hwnd);
    let magenta = win32::magenta_behind(hwnd, rect);
    later(600, move || {
        selflog::line(&format!(
            "alpha check {label}: {}",
            win32::sample_alpha(hwnd, rect)
        ));
        let path = selflog::data_dir().join(format!("probe-{label}.bmp"));
        win32::save_screen_bmp(rect, &path);
        win32::destroy(magenta);
    });
}

#[derive(Default)]
struct CycleStats {
    styles_ok: u32,
    foreground_changed: u32,
    foreground_ours: u32,
}

/// One hide/show cycle a second: hide, 400 ms later show again through
/// Slint (winit's SW_SHOWNOACTIVATE, see main), and read back the extended
/// styles and the foreground window around the show.
fn cycle(p: Probe, hwnd: HWND, n: u32, total: u32, mut stats: CycleStats) {
    if n == total {
        if total > 0 {
            selflog::line(&format!(
                "cycles done: {total}; styles intact {}/{total}; foreground changed {}/{total}; foreground ours {}/{total}; winit style rewrites undone so far {}",
                stats.styles_ok,
                stats.foreground_changed,
                stats.foreground_ours,
                win32::style_fixes()
            ));
            later(1000, move || alpha_check("after-cycles", hwnd));
        }
        return;
    }
    p.hide().unwrap();
    later(400, move || {
        let before = win32::foreground();
        p.show().unwrap();
        let ex = win32::exstyle(hwnd);
        let after = win32::foreground();
        let ok = win32::styles_ok(ex);
        stats.styles_ok += ok as u32;
        stats.foreground_changed += (before != after) as u32;
        selflog::line(&format!(
            "cycle {}: exstyle={ex:#010x} ok={ok} foreground {:?} -> {:?}",
            n + 1,
            before.0,
            after.0
        ));
        later(600, move || {
            // Read again just before the next hide, so a late activation counts too.
            stats.foreground_ours +=
                (win32::is_ours(after) || win32::is_ours(win32::foreground())) as u32;
            cycle(p, hwnd, n + 1, total, stats)
        });
    });
}
