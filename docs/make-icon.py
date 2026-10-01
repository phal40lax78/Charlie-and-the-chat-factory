# Makes extension/icon.png, the Marketplace icon, from docs/icon-cutout.png
# - Charlie cut out of docs/icon-source.jpg by docs/cut-icon.py. The inside
# is transparent, so the icon takes the theme's colour. A dark rounded
# frame keeps its shape, and the same stroke runs around Charlie, a
# sticker's outline: it covers the cutout's ragged edge with a smooth one,
# the edge redrawn as a curve so it runs like a drawn line, its sharp
# turns - the bangs' spikes, the notch at the shoulder - kept sharp.
# Her head, hair and all, fills two thirds of the icon's width, a sixth
# left of centre, the bow's tip near the top; the frame cuts off what
# falls outside.
# 256 px: the Marketplace wants at least 128 and never an SVG. Needs
# Python with numpy, opencv-python and Pillow, as cut-icon.py does. Run it
# again after changing the cutout:
#
#     python docs\make-icon.py
import base64
import io
import os
import numpy as np
import cv2
from PIL import Image, ImageDraw

DOCS = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(DOCS, 'icon-cutout.png')
OUT = os.path.join(os.path.dirname(DOCS), 'extension', 'icon.png')
N = 256
SS = 4                      # drawn at 4x, then scaled down: smooth edges
FRAME = (19, 10, 30)        # the photo's background, which filled the icon before
STROKE = 6                  # the frame's width, and the outline's
RADIUS = 48
HEAD = (62, 190)            # her head with its hair, at its widest, in the photo's columns
HEAD_SHARE = 2 / 3          # of the icon's width the head spans
HEAD_CENTRE = 1 / 3         # where across the icon the head's centre sits: left of the middle, for the shotgun
BOW_ROW = 2                 # the photo's row of the bow's tip, her top
TOP_GAP = 14                # icon pixels from the icon's top to the bow's tip
LINE = 2.0                  # the drawing's own black edge line, in photo pixels
SMOOTH = 6.0                # the edge's smoothing along itself, in icon pixels: 8 blunts the hair's tuft
CORNER_SPAN = 4             # icon pixels either side a turn is measured over
CORNER_ANGLE = 150          # degrees: a turn this sharp is a corner, kept...
CORNER_SMOOTH = 1.5         # ...by smoothing it over this few icon pixels

cut = Image.open(SRC).convert('RGBA')
scale = HEAD_SHARE * N / (HEAD[1] - HEAD[0])
w, h = round(cut.width * scale * SS), round(cut.height * scale * SS)
x0 = round((HEAD_CENTRE * N - (HEAD[0] + HEAD[1]) / 2 * scale) * SS)
y0 = round((TOP_GAP - BOW_ROW * scale) * SS)
big = N * SS
# The outline covers the drawing's own black line, which grows with the
# scale, so the dark band is the frame's width wherever it runs: that
# part of the stroke lies inside the silhouette, the rest outside.
INSIDE = min(LINE * scale, STROKE - 1)

art = Image.new('RGBA', (big, big), (0, 0, 0, 0))
art.alpha_composite(cut.resize((w, h), Image.LANCZOS), (max(x0, 0), max(y0, 0)),
                    (max(-x0, 0), max(-y0, 0)))

# the frame's centre line bounds the drawing, so it ends under the frame
inside = Image.new('L', (big, big), 0)
c = STROKE * SS / 2
ImageDraw.Draw(inside).rounded_rectangle([c, c, big - 1 - c, big - 1 - c], (RADIUS - STROKE / 2) * SS, fill=255)
inside = np.asarray(inside, np.float32) / 255

def smooth_shape(mask, sigma):
    """mask with each of its edges drawn again as a curve: the edge's
    points, a pixel apart, averaged along it over sigma pixels. A blur
    cut at half rounds a bump off only as far as it blurs, and leaves
    the rest as a wobble; averaging along the edge takes the wobble out
    and keeps the shape's corners where they bend slowly."""
    cs, hier = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    def average(q, sigma):
        r = int(3 * sigma)
        k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
        k /= k.sum()
        return np.stack([np.convolve(np.pad(q[:, i], r, mode='wrap'), k, 'valid') for i in (0, 1)], 1)
    span = int(CORNER_SPAN * SS)
    out = []
    for c in cs:
        p = c[:, 0, :].astype(np.float64)
        closed = np.vstack([p, p[:1]])
        s = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(closed, axis=0).T))])
        t = np.arange(0, s[-1], 1.0)
        if len(t) < 8:              # a speck: gone, as a blur would take it
            continue
        q = np.stack([np.interp(t, s, closed[:, i]) for i in (0, 1)], 1)
        # how sharply the edge turns at each point, from the points span
        # before and after it: 0 on a gentle curve, 1 at a tip or a notch.
        # There the short average takes over, and near it, so the tip
        # stays a tip and the curve eases into it.
        n = len(q)
        if n > 4 * span:
            a, b = np.roll(q, span, 0) - q, np.roll(q, -span, 0) - q
            cos = (a * b).sum(1) / np.maximum(np.hypot(*a.T) * np.hypot(*b.T), 1e-6)
            c0, c1 = np.cos(np.radians(CORNER_ANGLE + 30)), np.cos(np.radians(CORNER_ANGLE))
            w = np.clip((cos - c0) / (c1 - c0), 0, 1)
            w = np.clip(average(np.stack([w, w], 1), span)[:, 0] * 2, 0, 1)[:, None]
            q = average(q, sigma) * (1 - w) + average(q, CORNER_SMOOTH * SS) * w
        else:
            q = average(q, sigma)
        out.append(np.round(q).astype(np.int32).reshape(-1, 1, 2))
    # each edge filled and laid over the others by XOR: a hole inside an
    # outer edge comes out a hole, whichever edges were dropped as specks
    res = np.zeros_like(mask)
    for c in out:
        one = np.zeros_like(mask)
        cv2.fillPoly(one, [c], 1)
        res ^= one
    return res


# Charlie's silhouette, smoothed: the cutout's alpha, cut at half, its
# edge then drawn as a curve. In icon pixels, not the photo's: scaled up,
# the JPEG's steps are as big as the scale.
a = np.asarray(art.getchannel('A'), np.float32) / 255
sil = smooth_shape((cv2.GaussianBlur(a, (0, 0), SS) > 0.5).astype(np.uint8), SMOOTH * SS)


def disk(r):
    r = int(round(r))
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))


# the outline: STROKE wide, INSIDE of it over the drawing's edge; its
# outer edge drawn as a curve too, so the notches the widening leaves
# where the shape bends in come out round
outer = smooth_shape(cv2.dilate(sil, disk((STROKE - INSIDE) * SS)), SMOOTH * SS)
inner = cv2.erode(sil, disk(INSIDE * SS))
line = cv2.GaussianBlur((outer & ~inner & 1).astype(np.float32), (0, 0), 0.5 * SS) * inside

# the drawing clipped to the smoothed silhouette's inside, then the
# outline over it, then the frame over both
rgba = np.asarray(art, np.float32) / 255
alpha = rgba[..., 3] * cv2.GaussianBlur(sil.astype(np.float32), (0, 0), 0.5 * SS) * inside
col = rgba[..., :3]
fc = np.array(FRAME, np.float32) / 255
out_a = line + alpha * (1 - line)
out_c = (fc * line[..., None] + col * (alpha * (1 - line))[..., None]) / np.maximum(out_a, 1e-6)[..., None]
img = Image.fromarray(np.dstack([np.clip(out_c, 0, 1), np.clip(out_a, 0, 1)[..., None]]).__mul__(255).round().astype(np.uint8), 'RGBA')
ImageDraw.Draw(img).rounded_rectangle([0, 0, big - 1, big - 1], RADIUS * SS, outline=FRAME + (255,), width=STROKE * SS)

# scaled down with premultiplied colour, so no dark fringe at the edges
p = np.asarray(img, np.float32) / 255
p[..., :3] *= p[..., 3:]
p = cv2.resize(p, (N, N), interpolation=cv2.INTER_AREA)
p[..., :3] /= np.maximum(p[..., 3:], 1e-6)
icon = Image.fromarray((np.clip(p, 0, 1) * 255).round().astype(np.uint8), 'RGBA')
icon.save(OUT)
print('wrote ' + OUT)

# The same icon at 48 px, as base64 in src/icon.ps1, for the Windows tray
# and the overlay's windows. In a .ps1 because every way the tool is
# installed - install.ps1, the extension's payload - copies src/*.ps1 and
# nothing else. 48 covers the tray's icon up to 300% scaling.
TRAY = 48
buf = io.BytesIO()
icon.resize((TRAY, TRAY), Image.LANCZOS).save(buf, 'PNG', optimize=True)
b64 = base64.b64encode(buf.getvalue()).decode('ascii')
PS1 = os.path.join(os.path.dirname(DOCS), 'src', 'icon.ps1')
with open(PS1, 'w', newline='\n') as f:
    f.write('# Charlie-and-the-chat-factory, src/icon.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1\n'
            '# in its turn, never on its own - see the list there.\n'
            '#\n'
            '# Charlie, extension/icon.png at %d px, as a PNG in base64. Written by\n'
            '# docs/make-icon.py - run that, never edit this by hand.\n'
            '$script:ChatIconPng = @\'\n%s\n\'@\n'
            % (TRAY, '\n'.join(b64[i:i + 76] for i in range(0, len(b64), 76))))
print('wrote ' + PS1)
