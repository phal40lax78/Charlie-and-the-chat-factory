# Cuts Charlie and her shotgun out of docs/icon-source.jpg onto
# transparency, as docs/icon-cutout.png, which docs/make-icon.py frames
# into the Marketplace icon. Needs Python with numpy, opencv-python and
# Pillow; run it again only after changing the photo:
#
#     python docs\cut-icon.py
#
# The photo is a video frame: a flat dark purple background, the drawing's
# black outlines nearly as dark, dimmed top rows, a black letterbox below
# row 216 and a grey border in the last two columns. A plain colour key
# eats the outlines, so the steps are:
#  1. Frame: the dimmed rows are un-faded; the letterbox and the grey
#     columns are outside the picture.
#  2. The background's colour, measured locally from pixels close to it.
#  3. A trimap: sure background is near that purple; sure foreground is
#     far from it, or dark with the purple gone - the outlines, the bow
#     tie, the gun; the rest is GrabCut's to decide.
#  4. cv2.grabCut in mask mode.
#  5. Dark, non-purple pixels touching the foreground are kept, so no
#     outline is lost; tiny islands and holes go.
#  6. Soft alpha in a 1 px band either side of the edge, by a guided
#     filter.
#  7. The background unmixed from partly transparent pixels, so no purple
#     halo shows on a light theme.
import os
import numpy as np
import cv2
from PIL import Image

DOCS = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(DOCS, 'icon-source.jpg')
OUT = os.path.join(DOCS, 'icon-cutout.png')
GF_EPS = 2e-4

src = np.asarray(Image.open(SRC).convert('RGB')).astype(np.float32)
H, W, _ = src.shape

# ---- 1. frame ------------------------------------------------------------
LAST_ROW = 216          # rows below it are the letterbox's black
LAST_COL = 317          # columns right of it are the video's grey border
B0 = np.median(src[10:60, 220:310].reshape(-1, 3), axis=0)   # flat background


def unfade_row(y):
    """Row y is the true row faded toward a dark colour K:
    seen = t*true + (1-t)*K, t from the red of the row's background, K =
    (0,0,k) from its blue. Returns the row un-faded, and t."""
    row = src[y]
    bgpx = row[170:310]
    d = np.linalg.norm(bgpx - bgpx.mean(0), axis=1)
    b = np.median(bgpx[d <= np.percentile(d, 60)], axis=0)
    t = max(b[0] / B0[0], 0.05)
    k = np.zeros(3, np.float32)
    if t < 0.98:
        k[2] = max((b[2] - t * B0[2]) / (1 - t), 0)
    return np.clip((row - (1 - t) * k) / t, 0, 255), t


work = src.copy()
fade_t = {}
for y in (0, 1, 2, LAST_ROW):
    work[y], fade_t[y] = unfade_row(y)
# a row faded below t 0.5 un-fades to amplified JPEG noise; nothing of the
# drawing is left there (the bow's tip ends at row 2), so it is outside
FIRST_ROW = min(y for y in (0, 1, 2) if fade_t[y] >= 0.5)
content = np.zeros((H, W), bool)
content[FIRST_ROW:LAST_ROW + 1, :LAST_COL + 1] = True
work[~content] = B0

# ---- 2. the background's colour, locally -----------------------------------
d0 = np.linalg.norm(work - B0, axis=2)
near = ((d0 < 7) & content).astype(np.float32)
num = cv2.GaussianBlur(work * near[..., None], (0, 0), 12)
den = cv2.GaussianBlur(near, (0, 0), 12)[..., None]
Bmap = np.where(den > 0.05, num / np.maximum(den, 1e-6), B0).astype(np.float32)
Bmap[~content] = B0

d = np.linalg.norm(work - Bmap, axis=2)
G, Bc = work[..., 1], work[..., 2]
# purple: the background has blue over green by about 22; black and grey ~0
purple = Bc - G
bgp = Bmap[..., 2] - Bmap[..., 1]

# ---- 3. trimap -----------------------------------------------------------
neutral_dark = (purple < 0.45 * bgp) & (d > 12)
sure_fg = ((d > 45) | neutral_dark) & content
sure_fg = cv2.morphologyEx(sure_fg.astype(np.uint8), cv2.MORPH_OPEN,
                           np.ones((2, 2), np.uint8)).astype(bool) | ((d > 80) & content)
sure_bg = (d < 6) | ~content
# sure-background specks inside the drawing are dark JPEG pixels, not gaps
n, lab, st, _ = cv2.connectedComponentsWithStats(sure_bg.astype(np.uint8), connectivity=4)
for i in range(1, n):
    if st[i, cv2.CC_STAT_AREA] < 4:
        sure_bg[lab == i] = False
sure_bg &= ~sure_fg

gc = np.full((H, W), cv2.GC_PR_BGD, np.uint8)
gc[d > 14] = cv2.GC_PR_FGD
gc[sure_bg] = cv2.GC_BGD
gc[sure_fg] = cv2.GC_FGD

# ---- 4. GrabCut ----------------------------------------------------------
img8 = np.clip(work, 0, 255).astype(np.uint8)[..., ::-1].copy()   # BGR
bgdm = np.zeros((1, 65), np.float64)
fgdm = np.zeros((1, 65), np.float64)
cv2.grabCut(img8, gc, None, bgdm, fgdm, 8, cv2.GC_INIT_WITH_MASK)
fg = (gc == cv2.GC_FGD) | (gc == cv2.GC_PR_FGD)

# ---- 5. outlines kept, islands and holes gone ------------------------------
for _ in range(2):
    grow = cv2.dilate(fg.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    fg |= grow & content & (d > 10) & (purple < 0.7 * bgp)
n, lab, st, _ = cv2.connectedComponentsWithStats(fg.astype(np.uint8), connectivity=8)
keep = np.zeros(n, bool)
keep[1:] = st[1:, cv2.CC_STAT_AREA] >= 30
fg = keep[lab]
n, lab, st, _ = cv2.connectedComponentsWithStats((~fg).astype(np.uint8), connectivity=4)
for i in range(1, n):
    if st[i, cv2.CC_STAT_AREA] <= 3:
        fg[lab == i] = True


# ---- 6. soft alpha in the edge band ------------------------------------------
def box(x, r):
    return cv2.blur(x, (2 * r + 1, 2 * r + 1), borderType=cv2.BORDER_REFLECT)


def guided_filter(I, p, r, eps):
    """Colour guided filter (He et al. 2010). I: HxWx3 in [0,1], p: HxW."""
    mI = box(I, r)
    mp = box(p, r)
    cov_Ip = box(I * p[..., None], r) - mI * mp[..., None]
    var = np.empty((H, W, 3, 3), np.float32)
    for i in range(3):
        for j in range(3):
            var[..., i, j] = box(I[..., i] * I[..., j], r) - mI[..., i] * mI[..., j]
    var += eps * np.eye(3, dtype=np.float32)
    a = np.linalg.solve(var, cov_Ip[..., None])[..., 0]
    b = mp - (a * mI).sum(2)
    return (box(a, r) * I).sum(2) + box(b, r)


# a faded first row keeps only clear, bright drawing
if fade_t[FIRST_ROW] < 0.95:
    fg[FIRST_ROW] &= (d[FIRST_ROW] > 40) & fg[FIRST_ROW + 1]
# the half-faded last row goes on as the one above it: the letterbox cuts
# the picture, so shapes run straight into the bottom edge
fg[LAST_ROW] = fg[LAST_ROW - 1]
# smoothed, to take off the 1 px spurs and notches of JPEG blocking
fg = cv2.GaussianBlur(fg.astype(np.float32), (0, 0), 0.8) > 0.5
k3 = np.ones((3, 3), np.uint8)
inner = cv2.erode(fg.astype(np.uint8), k3).astype(bool)
outer = cv2.dilate(fg.astype(np.uint8), k3).astype(bool)
band = (outer & ~inner) & content

gf = guided_filter((work / 255).astype(np.float32), fg.astype(np.float32), 2, GF_EPS)
alpha = fg.astype(np.float32)
alpha[band] = np.clip(gf[band], 0, 1)
alpha[alpha < 0.06] = 0
alpha[alpha > 0.94] = 1
alpha[~content] = 0

# the colour of a barely-there pixel: the inside's, spread outward, the
# nearest scale winning
wgt = inner.astype(np.float32)
Fcol = work.copy()
done = inner.copy()
for sig in (1.0, 2.0, 4.0):
    num = cv2.GaussianBlur(work * wgt[..., None], (0, 0), sig)
    den = cv2.GaussianBlur(wgt, (0, 0), sig)
    m = ~done & (den > 1e-3)
    Fcol[m] = (num / np.maximum(den, 1e-6)[..., None])[m]
    done |= m

# the drawing where it meets the grey columns goes on to the photo's edge
for x in range(LAST_COL + 1, W):
    alpha[:LAST_ROW + 1, x] = alpha[:LAST_ROW + 1, LAST_COL]
    Fcol[:LAST_ROW + 1, x] = Fcol[:LAST_ROW + 1, LAST_COL]
    work[:LAST_ROW + 1, x] = work[:LAST_ROW + 1, LAST_COL]
# the half-faded last row repeats the one above; un-faded it shows a stripe
alpha[LAST_ROW] = alpha[LAST_ROW - 1]
work[LAST_ROW] = work[LAST_ROW - 1]
Fcol[LAST_ROW] = Fcol[LAST_ROW - 1]
Bmap[LAST_ROW] = Bmap[LAST_ROW - 1]
alpha[LAST_ROW + 1:] = 0
alpha[:FIRST_ROW] = 0

# ---- 7. the background unmixed ---------------------------------------------
a3 = alpha[..., None]
unmix = (work - (1 - a3) * Bmap) / np.maximum(a3, 1e-3)
w = np.clip((alpha - 0.35) / 0.4, 0, 1)[..., None]
col = np.where(a3 >= 1, work, w * unmix + (1 - w) * Fcol)
col = np.clip(col, 0, 255)
col[alpha == 0] = 0

rgba = np.dstack([np.round(col).astype(np.uint8), np.round(alpha * 255).astype(np.uint8)])
Image.fromarray(rgba, 'RGBA').save(OUT)
print('wrote ' + OUT)
