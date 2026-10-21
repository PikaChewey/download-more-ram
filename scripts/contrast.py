#!/usr/bin/env python3
"""WCAG contrast for every text token, light and dark, from DESIGN.md's token table (columns: token | dark | light).

The panel's background is translucent: the tint sits over the window material, which takes colour from the
wallpaper. So each text token is checked on the tint composited over two backdrops per mode (the usual
material and a worst case with the wallpaper bleeding through), and on a tile (surface over that). The
primary capsule (capsule text on an ink fill) is checked too. Exits 1 if any pair is below 4.5:1."""
import re, sys

text = open("DESIGN.md").read()
cell = r"`(#[0-9A-Fa-f]{6})`(?:\s*at\s*(\d+)%)?"
rows = re.findall(r"^\|\s*([a-z0-9-]+)[^|]*\|\s*" + cell + r"\s*\|\s*" + cell + r"\s*\|", text, re.M)
tok = {}
for name, dark, dark_a, light, light_a in rows:
    tok[name] = {"dark": (dark, int(dark_a or 100) / 100), "light": (light, int(light_a or 100) / 100)}

# The material under the tint: the usual popover material, and a worst case (the dark material over a white
# window, the light material over a black one).
BACKDROPS = {"dark": [("material", "#2B2D33"), ("white window", "#4A4C52")],
             "light": [("material", "#E4E7EC"), ("black window", "#B4B8C0")]}
TEXT = ["ink", "ink-2", "ink-3", "frost", "amber", "ember"]


def rgb(h):
    return [int(h[i:i + 2], 16) for i in (1, 3, 5)]


def over(fg, alpha, bg):
    f, b = rgb(fg), rgb(bg)
    return "#" + "".join(f"{round(alpha * x + (1 - alpha) * y):02X}" for x, y in zip(f, b))


def lum(h):
    c = [x / 255 for x in rgb(h)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


missing = [t for t in ["tint", "surface", "capsule"] + TEXT if t not in tok and t != "capsule"]
if missing:
    print("missing tokens in DESIGN.md:", ", ".join(missing))
    sys.exit(1)

bad = n = 0
for mode in ("dark", "light"):
    for label, backdrop in BACKDROPS[mode]:
        canvas = over(*tok["tint"][mode], backdrop)
        surface = over(*tok["surface"][mode], canvas)
        for bg_name, bg in (("panel", canvas), ("tile", surface)):
            for t in TEXT:
                r = ratio(tok[t][mode][0], bg); n += 1
                ok = r >= 4.5; bad += 0 if ok else 1
                print(f"{'ok ' if ok else 'LOW'} {mode:5} {t:6} on {bg_name:5} over {label:11} ({bg}) {r:5.2f}:1")
        # Pills: coloured text on its own 14% tint over the panel ("wall in ~7 min" in ember).
        for t in ("ink-2", "frost", "ember"):
            fg = tok[t][mode][0]
            pill = over(fg, 0.14, canvas)
            r = ratio(fg, pill); n += 1
            ok = r >= 4.5; bad += 0 if ok else 1
            print(f"{'ok ' if ok else 'LOW'} {mode:5} {t:6} pill        over {label:12} ({pill}) {r:5.2f}:1")
    # The primary capsule: capsule text on an ink fill.
    cap = {"dark": "#141416", "light": "#F4F3EF"}[mode]
    r = ratio(cap, tok["ink"][mode][0]); n += 1
    ok = r >= 4.5; bad += 0 if ok else 1
    print(f"{'ok ' if ok else 'LOW'} {mode:5} capsule text on ink fill {r:5.2f}:1")
print(f"contrast: {n - bad}/{n} text pairs >= 4.5:1")
sys.exit(1 if bad else 0)
