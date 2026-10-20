#!/usr/bin/env python3
"""Renders docs/demo.svg (an animated terminal) from a recording made with
`ram download --record recording.json`. Every number comes from that real run.

    python3 scripts/make-demo-svg.py recording.json docs/demo.svg [--speed 1.0]
"""
import html, json, sys

def gib(b):
    v = abs(b); s = "-" if b < 0 else ""
    if v >= 1024**3 * 0.9995: return f"{s}{v/1024**3:.2f} GB"
    if v >= 1024**2 * 0.9995: return f"{s}{v/1024**2:.1f} MB"
    return f"{s}{v/1024:.0f} KB"

def bar(frac, width=24):
    full = int(max(0, min(1, frac)) * width)
    return "█" * full + "░" * (width - full)

rec = json.load(open(sys.argv[1]))
out = sys.argv[2]
speed = float(sys.argv[sys.argv.index("--speed") + 1]) if "--speed" in sys.argv else 1.0
frames, r = rec["frames"], rec["receipt"]

W, LH, PAD = 760, 20, 18
lines_static = []  # (y, text, cls)
# Recordings made before `command` was saved: rebuild it from the levers that ran.
_levers = [l["kind"] for l in rec["receipt"].get("levers") or [] if l["kind"] != "signal"]
type_cmd = rec.get("command") or ("ram download" + (" --levers " + ",".join(_levers) if _levers else ""))
t_cmd = 0.9                      # typing finishes
t0 = t_cmd + 0.4                 # first progress frame
y = PAD + 30
header_y = y + LH
prog_y = header_y + LH * 1.5

# Progress frames: one text element per frame, shown from its time to the next frame's time.
prog = []
for i, f in enumerate(frames):
    start = t0 + f["t"] / speed
    end = t0 + (frames[i + 1]["t"] / speed if i + 1 < len(frames) else f["t"] / speed + 0.6)
    label = {"baseline": "Measuring baseline", "holding": "Downloading RAM", "settling": "Downloading RAM", "done": "Downloaded RAM"}[f["phase"]]
    if f.get("lever"):
        label = f["lever"] + "…"
    frac = f["elapsed"] / f["total"] if f["total"] else 1
    amount = "" if f["phase"] == "baseline" else f"  {gib(max(0, f['reclaimed']))}"
    rate = f"  {gib(int(f['rate']))}/s" if f["phase"] in ("holding", "settling") and not f.get("lever") else ""
    left = max(0, f["total"] - f["elapsed"])
    prog.append((start, end, f"{label:<18} {bar(frac)}{amount}{rate}  {round(left)}s left"))
speed_note = f'<text class="t dim" x="{W - PAD}" y="{PAD + 12}" text-anchor="end">{speed:g}x speed</text>' if speed != 1 else ""

t_done = prog[-1][1] if prog else t0
apps = [a for a in r["apps"] if a["before"] - a["after"] > 0][:6]
mx = max([a["before"] - a["after"] for a in apps] or [1])
receipt_lines = [(f"✓ Downloaded {gib(r['headlineBytes'])} of RAM in {round(r['durationS'])}s", "ok"), ("", "")]
levers = r.get("levers") or []
if len(levers) > 1:
    # One line per lever, each measured on its own; the headline is their sum.
    lmx = max([l["bytes"] for l in levers if l.get("bytes")] or [1])
    for l in levers:
        b = l.get("bytes")
        amount = ("+" if (b or 0) >= 0 else "") + gib(b) if b is not None else "—"
        bar = "█" * max(1, round(14 * b / lmx)) if b and b > 0 else ""
        receipt_lines.append((f"  {l['title'][:30]:<30} {amount:>10}  {bar}", "app"))
    if levers[0].get("detail"):
        receipt_lines.append((f"    signal: {levers[0]['detail'][:70]}", "dim"))
else:
    for a in apps:
        d = a["before"] - a["after"]
        receipt_lines.append((f"  {a['name'][:22]:<22} {('+' + gib(d)):>10}  {'█' * max(1, round(14 * d / mx))}", "app"))
sb, sa = r["systemBefore"], r["systemAfter"]
receipt_lines.append(("", ""))
receipt_lines.append((f"  Swap {gib(sb['swapUsed'])} → {gib(sa['swapUsed'])} · {r['machine']['chip']} · {r['machine']['memoryBytes'] // 1024**3} GB", "dim"))
receipt_lines.append(("  measured with phys_footprint, Activity Monitor's number", "dim"))

H = int(prog_y + LH * (len(receipt_lines) + 2) + PAD)
total = t_done + 1.0 + 0.15 * len(receipt_lines) + 4.0   # hold the final frame, then loop

def vis(start, end):
    a, b = start / total * 100, end / total * 100
    return f"0%,{a:.3f}%{{opacity:0}} {a:.3f}%,{b:.3f}%{{opacity:1}} {b:.3f}%,100%{{opacity:0}}"

css, body = [], []
css.append(f"""
  .t {{ font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; fill: #d7dbe0; white-space: pre; }}
  .dim {{ fill: #8b929b; }} .ok {{ fill: #7ee787; font-weight: 600; }} .app {{ fill: #d7dbe0; }} .prompt {{ fill: #7ee787; }}
  .f {{ opacity: 0; animation-duration: {total:.2f}s; animation-iteration-count: infinite; animation-timing-function: step-end; }}
""")
# Typing the command
for i in range(1, len(type_cmd) + 1):
    s, e = 0.05 + i * (t_cmd / len(type_cmd)), (0.05 + (i + 1) * (t_cmd / len(type_cmd))) if i < len(type_cmd) else total
    name = f"c{i}"
    css.append(f"@keyframes {name} {{ {vis(s, e)} }} .{name} {{ animation-name: {name}; }}")
    body.append(f'<text class="t f {name}" x="{PAD}" y="{y}"><tspan class="prompt">$ </tspan>{html.escape(type_cmd[:i])}</text>')
css.append(f"@keyframes hd {{ {vis(t0 - 0.2, total)} }} .hd {{ animation-name: hd; }}")
body.append(f'<text class="t dim f hd" x="{PAD}" y="{header_y}">macOS memory-pressure signal (critical, {r["holdMs"] // 1000}s) via {html.escape(r["backend"])}, measured with phys_footprint</text>')
for i, (s, e, text) in enumerate(prog):
    name = f"p{i}"
    end = e if i + 1 < len(prog) else total
    css.append(f"@keyframes {name} {{ {vis(s, end)} }} .{name} {{ animation-name: {name}; }}")
    body.append(f'<text class="t f {name}" x="{PAD}" y="{prog_y}">{html.escape(text)}</text>')
for i, (text, cls) in enumerate(receipt_lines):
    if not text: continue
    s = t_done + 0.3 + 0.15 * i
    name = f"r{i}"
    css.append(f"@keyframes {name} {{ {vis(s, total)} }} .{name} {{ animation-name: {name}; }}")
    body.append(f'<text class="t {cls} f {name}" x="{PAD}" y="{prog_y + LH * (i + 1.5)}">{html.escape(text)}</text>')

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="ram download: a real run downloading {gib(r['headlineBytes'])} of RAM">
<style>{''.join(css)}</style>
<rect width="{W}" height="{H}" rx="10" fill="#0d1117"/>
<circle cx="20" cy="16" r="5" fill="#ff5f57"/><circle cx="38" cy="16" r="5" fill="#febc2e"/><circle cx="56" cy="16" r="5" fill="#28c840"/>
{speed_note}
{''.join(body)}
</svg>
"""
open(out, "w").write(svg)
print(f"wrote {out}: {len(prog)} frames, {total:.1f}s loop, headline {gib(r['headlineBytes'])}")
