"""Build the built-in default skin (skins/default/) from nothing but code.

The default mascot is a plain round badge with two dot eyes, drawn here with
PIL, so the public repo holds no third-party art. One sprite atlas per mood,
24 frames of 320x256 at 15 fps (a 1.6 s loop), 6 frames per row.

Usage: python -I -X utf8 skins/tools/make_default.py
Writes skins/default/{skin.json,lines.json,moodmap.json,voice.md,LICENSE,
moods/<mood>.png,moods/<mood>.json}. Run it again after an edit: it
replaces the files. The format is docs/skin-pack.md.
"""
import json
import math
import os
import shutil

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "skins", "default")

FW, FH = 320, 256          # one frame, atlas pixels
SS = 4                     # supersampling factor for the drawing
FRAMES, FPS, COLS = 24, 15, 6
MOODS = ["idle", "ready", "pleased", "sad", "smug", "angry", "scared"]

INK = (35, 48, 60, 255)            # dots, brows, mouth
EDGE = (62, 84, 104, 255)          # outline
SHADOW = (0, 0, 0, 60)
BODY = {                            # body tint per mood
    "idle": (206, 222, 236), "ready": (206, 224, 238), "pleased": (214, 230, 236),
    "sad": (192, 206, 222), "smug": (208, 222, 234), "angry": (232, 202, 198),
    "scared": (214, 226, 238),
}


def s(v):
    return int(round(v * SS))


def line(d, pts, w, fill=INK):
    d.line([(s(x), s(y)) for x, y in pts], fill=fill, width=s(w), joint="curve")
    r = s(w) / 2
    for x, y in (pts[0], pts[-1]):  # round caps
        d.ellipse([s(x) - r, s(y) - r, s(x) + r, s(y) + r], fill=fill)


def arc_pts(cx, cy, rx, ry, a0, a1, n=14):
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def dot(d, x, y, rx, ry, fill=INK):
    d.ellipse([s(x - rx), s(y - ry), s(x + rx), s(y + ry)], fill=fill)


def blink_open(t, at):
    """1 = open, 0 = shut; a short blink centred on loop position `at`."""
    d = abs(((t - at + 0.5) % 1.0) - 0.5)
    return 1.0 if d > 0.045 else max(0.08, d / 0.045)


def frame(mood, i):
    t = i / FRAMES
    img = Image.new("RGBA", (FW * SS, FH * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    tau = 2 * math.pi * t
    cx = 160.0
    bob, sx, sy = 0.0, 0.0, 1.0
    if mood == "idle":
        bob = 3.0 * math.sin(tau)
    elif mood == "ready":
        bob = 2.0 * math.sin(2 * tau)
    elif mood == "pleased":
        bob = -6.0 * abs(math.sin(2 * tau))
    elif mood == "sad":
        bob = 5.0 + 1.5 * math.sin(tau)
        sy = 0.97
    elif mood == "smug":
        bob = 1.5 * math.sin(tau)
    elif mood == "angry":
        sx = 2.2 * math.sin(tau * 6)
        bob = 1.0 * math.sin(tau * 3)
    elif mood == "scared":
        sx = 1.8 * math.sin(tau * 8)
        bob = 1.0 * math.sin(tau * 4)
    cx += sx
    cy = 132.0 + bob
    bw, bh = 150.0, 128.0 * sy
    top, bot = cy - bh / 2, cy + bh / 2

    # ground shadow stays put while the body bobs
    sh = 1.0 - 0.12 * (bob / 6.0)
    d.ellipse([s(160 - 62 * sh), s(238), s(160 + 62 * sh), s(250)], fill=SHADOW)

    # body: a rounded orb with a lighter belly sheen
    body = BODY[mood] + (255,)
    d.rounded_rectangle([s(cx - bw / 2), s(top), s(cx + bw / 2), s(bot)], radius=s(60), fill=body, outline=EDGE, width=s(4))
    sheen = tuple(min(255, c + 22) for c in BODY[mood]) + (255,)  # solid: PIL draws replace pixels, they do not blend
    d.ellipse([s(cx - bw / 2 + 16), s(top + 10), s(cx - bw / 2 + 56), s(top + 34)], fill=sheen)

    ey = cy - 12
    ex = (cx - 34, cx + 34)
    my = cy + 26

    if mood in ("idle", "ready", "sad", "angry", "smug", "scared"):
        o = blink_open(t, 0.55 if mood == "idle" else 0.3)
    else:
        o = 1.0

    if mood == "idle":
        for x in ex:
            dot(d, x, ey, 9, 9 * o)
        line(d, [(cx - 12, my), (cx + 12, my)], 4)
    elif mood == "ready":
        for x in ex:
            dot(d, x, ey, 9.5, 9.5 * o)
        line(d, arc_pts(cx, my - 8, 16, 11, 25, 155), 4)
    elif mood == "pleased":
        for x in ex:
            line(d, arc_pts(x, ey + 7, 11, 11, 205, 335), 4.5)
        d.chord([s(cx - 20), s(my - 12), s(cx + 20), s(my + 14)], 0, 180, fill=INK)
    elif mood == "sad":
        for x in ex:
            dot(d, x, ey + 3, 9, 9 * o)
        line(d, [(ex[0] - 12, ey - 14), (ex[0] + 10, ey - 20)], 3.5)
        line(d, [(ex[1] - 10, ey - 20), (ex[1] + 12, ey - 14)], 3.5)
        line(d, arc_pts(cx, my + 12, 14, 9, 205, 335), 4)
        ty = ey + 14 + 30 * ((t * 2) % 1.0)  # a tear that falls twice a loop
        a = int(255 * (1 - ((t * 2) % 1.0)))
        d.ellipse([s(ex[1] + 2), s(ty), s(ex[1] + 10), s(ty + 12)], fill=(120, 170, 220, a))
    elif mood == "smug":
        for x in ex:
            dot(d, x, ey, 9.5, 9.5 * o)
            d.rectangle([s(x - 12), s(ey - 12), s(x + 12), s(ey - 1)], fill=body)   # lid
            line(d, [(x - 12, ey - 1), (x + 12, ey - 1)], 3)
        line(d, [(cx - 14, my + 2), (cx + 4, my + 4), (cx + 18, my - 6)], 4)
    elif mood == "angry":
        for x in ex:
            dot(d, x, ey + 3, 8.5, 8.5 * o)
        line(d, [(ex[0] - 14, ey - 18), (ex[0] + 12, ey - 8)], 5)
        line(d, [(ex[1] + 14, ey - 18), (ex[1] - 12, ey - 8)], 5)
        line(d, [(cx - 14, my + 6), (cx - 7, my), (cx, my + 6), (cx + 7, my), (cx + 14, my + 6)], 4)
    elif mood == "scared":
        for x in ex:
            dot(d, x, ey, 13, 13 * o, fill=(250, 252, 255, 255))
            d.ellipse([s(x - 13), s(ey - 13 * o), s(x + 13), s(ey + 13 * o)], outline=INK, width=s(3))
            dot(d, x + 1.5 * math.sin(tau * 2), ey, 3.5, 3.5 * o)
        line(d, [(ex[0] - 12, ey - 24), (ex[0] + 10, ey - 28)], 3.5)
        line(d, [(ex[1] - 10, ey - 28), (ex[1] + 12, ey - 24)], 3.5)
        d.ellipse([s(cx - 8), s(my - 2), s(cx + 8), s(my + 16)], fill=INK)
        sw = (t * 2) % 1.0  # a sweat drop that runs down the side
        d.ellipse([s(cx + 56), s(top + 18 + 24 * sw), s(cx + 66), s(top + 34 + 24 * sw)], fill=(120, 170, 220, int(255 * (1 - sw * 0.6))))
    return img.resize((FW, FH), Image.LANCZOS)


def atlas(mood):
    rows = math.ceil(FRAMES / COLS)
    sheet = Image.new("RGBA", (COLS * FW, rows * FH), (0, 0, 0, 0))
    for i in range(FRAMES):
        sheet.paste(frame(mood, i), ((i % COLS) * FW, (i // COLS) * FH))
    return sheet


# ---- lines: plain readouts, no persona. Metadata (names, holds, ranks) are the
# engine's event table; only the texts are the pack's.
EVENTS = [
    # n, id, name, trig, mood, hold, pri, cd, freq, sample slots, killer pool, extras
    (1, "start", "Chat starts work", "State becomes working", "ready", "4s", "P3", "3 min per chat, 10 min global", "35% chance. Coalesce starts within 30 s", {}, ["{project} started."], [("COALESCED", ["{count} chats started."])]),
    (2, "m5", "Job hits 5 min", "Working 5 min or more", "ready", "3s", "P3", "Once per job", "30% chance. Skipped if #3 is also due", {"minutes": 5}, ["{project}: {minutes} minutes."], []),
    (3, "m20", "Job hits 20 min", "Working 20 min or more", "ready", "3s", "P3", "Once per job", "60% chance", {"minutes": 20}, ["{project}: {minutes} minutes."], []),
    (4, "m30", "Job hits 30 min", "Working 30 min or more", "sad", "4s", "P2", "Once per job", "Always. No time lines after this; badge only", {"minutes": 30}, ["{project}: {minutes} minutes."], []),
    (5, "wait", "Chat waits on you", "Waiting state, no prompt", "ready", "until handled", "P1", "Once per entry", "One re-nag after 10 min, then badge only", {"minutes": 12}, ["{project} is waiting."], [("RE-NAG, 10 MIN", ["{project} is still waiting."])]),
    (6, "perm", "Asks permission", "Permission prompt open", "ready", "until handled", "P1", "Once per entry", "As #5", {}, ["{project} needs permission."], []),
    (7, "ques", "Asks a question", "Question prompt open", "ready", "until handled", "P1", "Once per entry", "As #5", {}, ["{project} has a question."], []),
    (8, "done", "Chat finishes", "Working becomes done", "pleased", "5s", "P2", "2 min global", "Once per chat. Coalesce: {count} chats finished", {"minutes": 18}, ["{project} finished."], [("COALESCED", ["{count} chats finished."])]),
    (9, "allidle", "All chats idle", "None working for 5 min", "idle", "", "P4", "Once per idle stretch", "Max 3 a day", {}, ["All chats are idle."], []),
    (10, "u75", "Usage 75%", "Provider window at 75% or more", "ready", "3s", "P3", "Once per window per provider", "Always, unless capped", {"percent": 76}, ["{provider}: {percent}% used."], []),
    (11, "u90", "Usage 90%", "Provider window at 90% or more", "sad", "4s", "P2", "Once per window per provider", "Always", {"percent": 91}, ["{provider}: {percent}% used."], []),
    (12, "cut", "Limit hit (cut off)", "A chat cut off by the limit", "sad", "6s", "P1", "Once per window per provider", "Coalesce all cut-off chats into one line", {}, ["{chat} was cut off by {provider}. Resets at {reset_time}."], [("COALESCED", ["{count} chats were cut off. Resets at {reset_time}."])]),
    (13, "reset", "Limit resets", "Window rolls over", "pleased", "5s", "P2", "Once per window", "Only if #11 or #12 fired in that window", {"percent": 4, "hours": 4}, ["{provider} window has reset."], []),
    (14, "queue", "Queued prompt sends", "Queue item delivered", "pleased", "3s", "P3", "5 min", "50% chance", {"count": 2}, ["{project}: queued prompt sent."], []),
    (15, "resume", "Auto-continue resumes", "Cut-off chat resumed", "pleased", "5s", "P2", "Per resume", "Coalesce resumes within 60 s", {}, ["{project} resumed."], []),
    (16, "reload", "VS Code reload needed", "Reload flag set", "sad", "4s", "P1", "Once per flag", "One re-nag at 30 min, then badge only", {"minutes": 30}, ["Reload needed. {minutes} minutes ago."], []),
    (17, "crash", "Crash / stop", "Chat process died", "sad", "8s", "P1", "Once per chat", "Always", {"time": "14:37"}, ["{project} stopped at {time}."], []),
    (18, "o529", "529 overloaded", "Provider returns 529", "sad", "4s", "P2", "15 min per provider", "Retries in that window are silent", {}, ["{provider} is overloaded."], []),
    (19, "poke", "Hover / click the mascot", "1.5 s hover dwell, or a click", "pleased", "2s", "P4", "Hover 10 min, click 60 s", "3 quick clicks get one escalation line, then 5 min silence", {}, ["{waiting} chats are waiting."], [("AFTER 3 QUICK CLICKS", ["{waiting} chats are still waiting."])]),
    (20, "drag", "Dragged", "On drop", "sad", "2s, then idle", "P4", "10 min", "Max 4 a day", {}, ["Position saved."], []),
    (21, "morning", "First launch of the day", "First start after 05:00", "ready", "4s", "P3", "Once per day", "Always", {"time": "08:55", "percent": 12, "count": 2}, ["Started at {time}."], []),
    (22, "late", "Late night", "First input after 23:30 (configurable)", "idle", "dimmed", "P4", "Once per night", "Fires as quiet hours begin, then quiet", {"time": "23:47"}, ["It is {time}."], []),
    (23, "del", "Chat deleted", "Chat removed from tracking", "sad", "3s", "P3", "5 min", "Coalesce deletes within 30 s", {}, ["{chat} deleted."], []),
    (24, "back", "Long idle, on your return", "No chats and no input for 2 h", "idle", "", "P4", "Once per stretch", "Fires when you return, not into an empty room. Max 2 a day", {"hours": 3}, ["Away for {hours} hours."], []),
    ("+", "mute", "Mute", "User mutes the mascot", "sad", "2s", "", "n/a", "One line, then silence", {}, ["Muted."], []),
    ("+", "unmute", "Unmute", "User unmutes", "pleased", "2s", "", "n/a", "One line", {}, ["Unmuted."], []),
    ("+", "sulk", "Unmute after 3+ mutes today", "Third unmute in a day", "sad", "3s", "", "n/a", "The sulk payoff", {}, ["Unmuted."], []),
]
# no "fail" event: the default skin does not comment on failed tasks, and the
# engine stays silent for an event a pack leaves out.

STATUS = {
    "mood": "ready",
    "opening": "Opening {chat}.",
    "opened": "{chat} opened.",
    "denied": "{chat} cannot be opened from here.",
    "deleted": "{chat} deleted.",
    "answer": "{chat}: answered.",
    "lock": {"on": "Locked.", "off": "Unlocked.", "drag": "Locked. Unlock to move."},
    "relocation": "Moved to the top.",
    "brain": {
        "drop": {"killer": "Brain unreachable. Using rules."},
        "back": "Brain: {where}.",
        "start": "Brain: {where}.",
        "stop": "Brain: Off.",
        "latency": "Brain: {where}. {ms} ms.",
    },
    "usage": {"asking": "Checking usage.", "done": "Usage updated at {time}."},
    "queue": {"yes": "{count} chats queued.", "no": "Not queued.", "cont": "{chat}: will continue.", "nocont": "{chat}: will not continue."},
    "reload": {"yes": "{window}: reload requested.", "no": "Reload postponed."},
    "console": "Console opened.",
    "crash": {"on": "Auto-restart on.", "off": "Auto-restart off."},
}

VOICE_MD = """# Default skin voice

The default skin has no character. It states facts and stops.

- One short sentence per line, a full stop at the end. No jokes, no asides.
- Say what happened and to what: "{project} finished." "{provider}: {percent}% used."
- No second person, no blame, no praise, no questions.
- Numbers and names come from slots; never write one into the text.
- Slots are the engine's list in docs/skin-pack.md. A line with a slot the
  engine cannot fill is left out of the draw, so keep every line to slots that
  its event can supply.
- A writer making a new pack copies this folder, renames `id` in skin.json,
  replaces the mood atlases and rewrites lines.json. Sections left out
  (talk, hum, pacifist, conversations) make the mascot silent there.
"""


def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, "moods"))
    for m in MOODS:
        sheet = atlas(m)
        sheet.save(os.path.join(OUT, "moods", m + ".png"), optimize=True)
        write_json(os.path.join(OUT, "moods", m + ".json"),
                   {"frames": FRAMES, "fps": FPS, "w": FW, "h": FH, "cols": COLS, "play": "loop"})
        print(m, sheet.size, os.path.getsize(os.path.join(OUT, "moods", m + ".png")), "bytes")

    write_json(os.path.join(OUT, "skin.json"), {
        "format": 1,
        "id": "default",
        "name": "Default",
        "version": "1.0.0",
        "author": "Hae-chan Hong",
        "voice": "OVERLAY",
        "tags": ["neutral", "en"],
        "mascot": {"w": FW // 2, "h": FH // 2, "scale": 2, "anchor": [80, 124]},
        "colours": {"accent": "#5EF6FF", "box": "#0E0E17", "ink": "#E2DCCF", "gold": "#F0B537"},
        "moods": MOODS,
        "tray": {"mood": "ready", "frame": 0, "crop": [80, 60, 160, 160]},   # the badge, square
        "fallback": {"smug": "ready", "angry": "ready", "scared": "ready", "pleased": "ready", "sad": "idle"},
        "modes": ["killer"],
        "maxChars": 95,
    })

    events = []
    for n, id_, name, trig, mood, hold, pri, cd, freq, sample, pool, extras in EVENTS:
        e = {"n": n, "id": id_, "name": name, "trig": trig, "mood": mood, "hold": hold, "pri": pri,
             "cd": cd, "freq": freq, "s": sample, "killer": pool}
        if extras:
            e["extra"] = [{"lb": lb, "killer": pl} for lb, pl in extras]
        events.append(e)
    write_json(os.path.join(OUT, "lines.json"), {"events": events, "status": STATUS})

    write_json(os.path.join(OUT, "moodmap.json"),
               {"sections": {"events": "ready", "status": "ready"}, "locked": [], "phrases": []})
    with open(os.path.join(OUT, "voice.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write(VOICE_MD)
    shutil.copyfile(os.path.join(ROOT, "LICENSE"), os.path.join(OUT, "LICENSE"))


if __name__ == "__main__":
    main()
