# DESIGN — Download More RAM

Binding for every surface (menu bar item, panel, download sheet, receipt, share card, demo clip).
Sources: 15 X posts read 2026-10-20 (dates and engagement confirmed via api.fxtwitter.com; raw notes in the
research pass), Bryan's house style (`~/Documents/VS Code/Projects/insomnia/docs/design.md`, Tutto, Reaper).
**When X trends and the house style disagree, the house style wins.**

## 1. References

| # | Post | Date | Reach | Takeaway used here |
|---|---|---|---|---|
| 1 | [Claude Status Bar](https://x.com/mickces/status/2068774236194300210) | 2026-06-21 | 1,447 likes · 144K views | Open on the real menu bar; praised as "this restrained"; repliers asked 3x about multiple sessions |
| 2 | [Vitals for Mac](https://x.com/attacomsian/status/2103103182213972383) | 2026-09-24 | 519 · 147K | Problem line as the first frame; one giant numeral per beat; "thinks in apps, not processes" |
| 3 | [Pulse](https://x.com/localhost_5173/status/2108859236990198145) | 2026-10-10 | 646 · 25K | Dot-matrix progress/sparklines; near-black, calm |
| 4 | [BlitzClean](https://x.com/virgilerietsch/status/2107463995070291985) | 2026-10-06 | 979 · 158K | RAM by app and AI agent; red only on the bad numbers; AI-video tells criticised |
| 5 | [Mole](https://x.com/HiTw93/status/2053834228165673459) | 2026-05-11 | 2,433 · 516K | Destructive one-click actions called "a bit dangerous"; wants impact-sorted results |
| 6 | [Onlight](https://x.com/jamesm/status/2101286767131513088) | 2026-09-19 | 326 · 29K | Only UI complaint in the set: "Doesn't look native to macOS… overdesign" |
| 7 | [Cloud-bill menu bar](https://x.com/sudo_overflow/status/2089622151804735672) | 2026-08-18 | 953 · 79K | Big light numeral, smaller decimals, "● live · 4s ago" |
| 8 | [Janus](https://x.com/RamitWasTaken/status/2104248845471470001) | 2026-09-27 | 516 · 83K | Colour only on state; "No server, no telemetry" sells |
| 10 | [Menu blink](https://x.com/gabriell_lab/status/2104946256950813044) | 2026-09-29 | 939 · 42K | 90 ms unhighlight/re-highlight before closing = native feel |
| 11 | [Tear-off ticket](https://x.com/cabralorenzo/status/2112158571974754507) | 2026-10-19 | 1,821 · 46K | One physical beat; "either tear like paper or be gooey" (commit to one metaphor) |
| 12 | [loading.dev](https://x.com/jakubkrehel/status/2112204760606802214) | 2026-10-19 | 679 · 19K | Black-on-white dot-matrix indicators |
| 14 | [Kaptea onboarding](https://x.com/angeloldesigns/status/2109987027320254906) | 2026-10-13 | 169 · 8K | Onboarding modal called "Monstrous… completely blocking their work" |
| 15 | [steipete: "I smell a leak."](https://x.com/steipete/status/2049290265026773172) | 2026-04-29 | 7,778 · 883K | The exact out-of-memory panel; top reply "You may need to download more RAM." |

## 2. Principles

1. **The first frame is the real menu bar showing the real number** (#1, #7; problem-first #2, #4). "38%" is the hook.
2. **One hero numeral per view, tabular, neutral until it matters** (#2, #3, #4, #7). Colour appears only for memory
   coming back (accent) and for the wall itself (red) (#1, #4, #8).
3. **Native beats designed** (#6, #1, #14): system type, template icon, no onboarding, no glass.
4. **The download is a loader with a payoff** (#3, #12, #4, #10): dot-matrix chips fill like a RAM stick while real
   measured gigabytes count up; the receipt "prints" once (#11), one metaphor only.
5. **Rows are apps and sessions, never pids** (#2, #4, #1): icon + title + size, sorted by size, scales to 30 sessions.

## 3. Tokens

Neutrals are ink at four opacities over an opaque canvas; one accent; one status red. No gradients, no blur.

| Role | Light | Dark | Use |
|---|---|---|---|
| canvas | `#FFFFFF` | `#161616` | panel, sheet, receipt background |
| surface | `#F4F4F4` | `#202020` | rows on hover, button fill |
| hairline | `#E3E3E3` | `#2E2E2E` | 0.5 pt dividers |
| ink | `#111111` | `#F2F2F2` | primary text, hero numeral |
| ink-2 | `#5C5C5C` | `#A8A8A8` | secondary text |
| ink-3 | `#6E6E6E` | `#8F8F8F` | tertiary text (still >= 4.5:1) |
| accent | `#0F7B4F` | `#3DDC97` | memory coming back: download chips, positive deltas, payoff numeral |
| danger | `#C4291C` | `#FF6B5E` | the wall only: >= 85%, imminent, paused-apps line |

Contrast: every text token on canvas and surface >= 4.5:1 in both modes (checked by `scripts/contrast.py`).

Type: SF Pro (system) for everything; SF Mono only for live numbers in the download sheet and receipt. Sizes:
hero 56 pt semibold tabular; title 13 pt semibold; body 12 pt; small 11 pt. Units are ink-2 at body size.

Spacing on a 4 pt grid (4, 8, 12, 16, 24). Radii: 6 (controls), 10 (panel), 12 (sheet, receipt).

Motion: springs with no bounce (response 0.30 s, damping 1.0); entrances 200 ms, exits 0.6x; the Download button
blinks off/on for 90 ms before the sheet opens; nothing animates at rest; Reduce Motion = cross-fades only.

## 4. Icon

Menu bar: a template DIMM (rounded body, four chips, pin row with key notch) at 16 pt, alpha only, never tinted.
Chips fill with the wall percent (0-4). At the wall (>= 85% or imminent) the body gains a small notch cut-out: state
is shape, not colour. Optional text "38%" (<= 6 chars, monospaced digits), off by default (menu bars are full).
App icon: the light DIMM with a downward arrow on a graphite tile (`Resources/AppIcon.icns`).

## 5. Panel layout (360 pt, opaque)

1. Hero: "38%" + "to the wall" (ink-2), thin bar, one reason line, ETA or "not climbing". Red only >= 85%.
2. Paused line (only when macOS paused apps): "macOS paused 5 apps · their helpers burn 6.0 cores" + `Resume`.
3. The one primary action: **Download More RAM** (or "Install helper to download" when unavailable).
4. Levers ("Also available"): one row per offer with its measured estimate and a `Do it` / remembered toggle.
5. Where your RAM is: top 5 rows (apps and agent sessions with real titles), "All" to expand.
6. Footer: Autopilot toggle, helper dot, `…` menu (% in menu bar, at login, quit). No explanatory text.

## 6. Hero moment (18 s clip, 4:5, from a real recording)

Cold open, because feeds autoplay muted and people scroll on: 0 s the panel is already open on the real numbers ·
0.25 s press blink · 0.7 s sheet counting (the signal; the 2 s baseline is measured but not shown) · 5.6 s levers
land · 6.6 s payoff "921.2 MB back" · 8.6-14.4 s receipt prints, lever rows · 14.4 s panel closes, lower number
in the bar · 15-18 s end card "Download More RAM · free · native". 1080x1350 with the 360 pt panel drawn at 2.6x,
so it fills the width and 11 pt text is 29 px (readable in a phone feed). Rendered offscreen from the recorded
progress frames (no screen recording, no stock sounds).

## 7. Anti-goals

Bryan: hint or fluff text, overdesign, glass/blur, blue accents, orange+green together, per-second animation while
idle, anything that is not native-feeling. Commenters: web-flavoured menu bar UI (#6), onboarding modals (#14),
bloat, `curl | bash` installs, destructive actions one click away without saying what happens (#5), AI-video tells
(#4), unhandled multiple sessions (#1), crowded menu bars, half-committed skeuomorphism (#11).

## 8. House style shared with sibling projects

Same family as Insomnia, Tutto and Reaper: monochrome instrument feel, opaque canvas, hairlines, SF Pro, template
menu bar glyph drawn in code, `--render-ui DIR` offscreen renders for every state, near-zero idle cost.
