#!/usr/bin/env python3
"""WCAG contrast for every text token against canvas and surface, light and dark, from DESIGN.md's token table.
Exits 1 if any pair is below 4.5:1. Prints one line per pair and a summary line."""
import re, sys
text = open("DESIGN.md").read()
rows = re.findall(r"\|\s*([a-z0-9-]+)\s*\|\s*`(#[0-9A-Fa-f]{6})`\s*\|\s*`(#[0-9A-Fa-f]{6})`\s*\|", text)
tok = {name: (light, dark) for name, light, dark in rows}
def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
texts = [t for t in ("ink", "ink-2", "ink-3", "accent", "danger") if t in tok]
bad, n = 0, 0
for mode, i in (("light", 0), ("dark", 1)):
    for bg in ("canvas", "surface"):
        for t in texts:
            r = ratio(tok[t][i], tok[bg][i]); n += 1
            ok = r >= 4.5; bad += 0 if ok else 1
            print(f"{'ok ' if ok else 'LOW'} {mode:5} {t:7} on {bg:7} {r:5.2f}:1")
print(f"contrast: {n - bad}/{n} text pairs >= 4.5:1")
sys.exit(1 if bad else 0)
