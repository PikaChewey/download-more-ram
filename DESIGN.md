# DESIGN — Download More RAM (v2, "thermostat for memory")

Binding for every surface: menu bar item, panel, download, receipt, share card, demo clip.
Replaces v1 (monochrome hairlines), which the owner rejected outright on 2026-10-21. Source: 44 X posts read
2026-10-21, every date and engagement figure confirmed via api.fxtwitter.com, 22 reply threads read, 35 clips
frame-sheeted (`docs/research/x-ui-2026-10-21.md`, rows numbered as there; frames in `docs/research/x-ui-2026-10-21/`).

## 1. References (the rows this design takes from)

| # | Post | Date | Likes / views | Taken |
|---|---|---|---|---|
| 1 | [AC remote as a menu-bar app](https://x.com/icanberk/status/2109031477484937571) | 2026-10-10 | 22,933 / 2.18M | Dark instrument popover off the item; one rendered object on top; one light hero numeral with a small unit; a row of tiles; the item speaks (`23°`) |
| 2 | [Apartment in a popover](https://x.com/0xProbabillity/status/2109978137794883621) | 2026-10-13 | 6,633 / 372K | The object reacts (lamps glow when clicked); big radius; tint marks "on" |
| 3 | [Blue Star AC via MCP](https://x.com/the_mcnaveen/status/2109599383717335207) | 2026-10-12 | 4,968 / 326K | The panel's tint is the state (slate cool, ember hot) |
| 5 | [Claude Status Bar](https://x.com/mickces/status/2068774236194300210) | 2026-06-21 | 1,447 / 144K | Restraint in the bar praised: glyph + a few characters |
| 6 | [ActivityLine](https://x.com/JakeManger/status/2095119830429098491) | 2026-09-02 | 364 / 85K | App rows with real icons and one number; size-as-pride ("2.3 MB is wild") |
| 8 | [Pulse](https://x.com/localhost_5173/status/2108859236990198145) | 2026-10-10 | 645 / 25K | Dot-matrix texture for live memory data; light numerals with small units |
| 9 | [Vitals](https://x.com/attacomsian/status/2103103182213972383) | 2026-09-24 | 519 / 147K | "Thinks in apps"; a sentence that says what to stop and what it frees |
| 14 | [WakeBee](https://x.com/AdityaShips/status/2110024210349502974) | 2026-10-13 | 509 / 48K | Same popover grammar works for a plain utility; one start button |
| 17 | [Live progress bar mod](https://x.com/kirillvserditov/status/2105790255144063241) | 2026-10-01 | 1,804 / 159K | Textured fill whose colour is the stage; a chip rides the fill edge |
| 18 | [Metalforge progress](https://x.com/sucodeee/status/2092222674478993525) | 2026-08-25 | 2,871 / 226K | One saturated hue per fill; big number at the right |
| 22 | [Run Receipt](https://x.com/kail_designs/status/2069383972854149358) | 2026-06-23 | 1,490 / 146K | Thermal receipt as the shareable object ("share invoices like this") |
| 30 | [shadcn: Liquid Glass on the Mac](https://x.com/shadcn/status/2096797264370950464) | 2026-09-07 | 1,681 / 159K | "Some of the glass, almost none of the liquid"; work UI must feel instant |
| 31 | [shadcn: count the animations](https://x.com/shadcn/status/2096648867567608084) | 2026-09-06 | 2,961 / 390K | Animate only what communicates what just happened |
| 37 | [steipete: "I smell a leak."](https://x.com/steipete/status/2049290265026773172) | 2026-04-29 | 7,776 / 883K | The out-of-memory panel is a shared experience: the clip's context |
| 40 | [DDR5 up another 10-15%](https://x.com/Pirat_Nation/status/2112725810008506604) | 2026-10-21 | 5,680 / 381K | Today's hook: RAM is expensive; download it instead |

## 2. Principles

1. **One object, one number.** The panel is an instrument: a RAM stick drawn as a grid of dot cells and one light
   numeral. Everything else is quieter (1, 2, 3, 8, 14).
2. **Temperature is the state, and it never lies.** Frost when far from the wall, amber on the way, ember at the
   wall (3, 17). The tint follows the measured distance to the wall only; a download does not fake a cool-down.
3. **The stick is the download.** Pressing Download More RAM fills the stick's cells left to right in frost while the
   numeral counts measured megabytes: the joke, made literal and honest (17, 18).
4. **The bar speaks, briefly.** The item is the `memorychip` symbol plus `38%`; during a download it counts the
   measured amount; at the wall the chip turns ember like a low battery (1, 5).
5. **Instant and still.** The panel opens in one frame; nothing moves at rest; motion only reports progress or a
   state change, 120-200 ms, eased, no bounce (30, 31).
6. **The receipt is the souvenir.** The result is a printed thermal receipt, as a share card, not as live UI (22).

## 3. Tokens

The panel is dark-first: a system material (`.hudWindow`) under a charcoal tint, so text contrast never depends
on the wallpaper. Light mode keeps the same structure on warm paper. Reduce Transparency: the tint goes opaque.

| Role | Dark | Light | Use |
|---|---|---|---|
| tint (over the material) | `#121214` at 72% | `#F4F3EF` at 78% | the panel |
| surface | `#FFFFFF` at 6% | `#000000` at 4% | tiles, rows on hover, the stick's board |
| stroke | `#FFFFFF` at 9% | `#000000` at 8% | tile and stick outlines |
| ink | `#F5F5F3` | `#141414` | numerals, names |
| ink-2 | `#B4B4AF` | `#45453F` | labels, sublines |
| ink-3 | `#979792` | `#5E5E58` | quiet values, unlit dots |
| frost (cool, good, "back") | `#9ED8FF` | `#1D5F8C` | amounts back, the download fill, a far wall |
| amber (on the way) | `#F2B45A` | `#8A5000` | 60-84% |
| ember (the wall) | `#FF6B47` | `#9C2B08` | >= 85% or imminent, paused apps |

Contrast (computed by `scripts/contrast.py`; every text pair must be >= 4.5:1): all six text tokens on the panel and
on a tile, in both modes, with the tint composited over the usual material and over a worst case (the dark material
over a white window, the light one over a black window), plus the capsule's text on its ink fill. 50/50 pass. No green
anywhere (the owner rejected orange next to green), no system blue: frost is the cool end of the temperature scale.

Temperature ramp: wall % 0-55 frost, 55-85 frost → amber, 85-100 amber → ember (interpolated in OKLab-ish sRGB).

Type: SF Pro for UI, SF Pro Light for the big numerals, SF Mono only for small data (amounts in lists, rate, the
system line) and the printed receipt. hero 60 pt light (unit at 40%), payoff 52 pt light, counter 44 pt light with
tabular digits (it becomes the payoff, so it shares its face), title 13 pt semibold, body 13 pt, label 11 pt medium
(ink-2, +0.2 tracking), small 11 pt, mono 12 pt.
Spacing 4 pt grid (4, 8, 12, 16, 20). Radii: panel 20, tile 14, button capsule, rows 10, stick board 8, dot 1.5.

Motion: open/close 120 ms ease-out (the panel itself appears in one frame); page change 180 ms ease-out cross-fade
with 6 pt rise; cells light 8 ms apart as progress advances; numeral counts with numericText; button press 90 ms;
nothing animates at rest; Reduce Motion: cross-fades only, cells jump.

## 4. Menu bar item

`memorychip` (SF Symbol, template, 14 pt) + `38%` (12 pt monospaced digits), text on by default, hideable in `…`.
While downloading: `memorychip.fill` + the measured amount counting (`+921 MB`), 2 Hz, from the engine's events.
At the wall (>= 85% or imminent): `memorychip.fill` in ember (non-template), the only time the item has colour,
like a low battery.

## 5. Panel (360 pt wide)

1. Header: `Memory` label · `16 GB` (ink-3; the chip in its tooltip) on the left; `…` menu on the right: the helper's state
   (`Helper 1.1.0 installed`, or install/update), `Always run with downloads ▸` (one toggle per lever), menu-bar %,
   launch at login, quit.
2. The stick: 328 x 64 pt, 8 chips of 4 x 4 dot cells (128 cells, 128 MB each on 16 GB) above an edge connector
   printed inside the board's bottom strip, with the key notch cut into its edge (one object; a separate pin row
   read as a second, meaningless bar to the outside judge). At rest the first
   `wall %` of cells are lit in the temperature colour, the rest are ink-3 at 22%.
3. Hero: `38%` (light 60 pt) + caption `to the out-of-memory wall`; on the right a pill that names what it measures
   (`steady`, `wall in ~24 min`, ember `wall any second`).
4. Banners when needed: paused apps (ember tint: `macOS paused 3 apps · their helpers burn 6.0 cores` + `Resume`, a
   tinted secondary capsule with an ink label, never a second ink capsule), interrupted hold.
5. Primary button: full-width capsule, 44 pt, `↓ Download More RAM` (ink on dark = white capsule, black text);
   `Install helper to download` when there is no helper.
6. Lever tiles in Control Center's grammar, only for levers with something to give back (Firefox GPU · Leftover
   servers · Archived sessions; paused apps have the banner): two per row, an odd last tile full width; none at all
   on a calm Mac (the best space under the button is never spent on `none`). Icon in a 28 pt circle, label, measured
   estimate. Click arms the tile (`Restart it?` / `Quit 2?`) for 3 s; a second click runs a download with that lever.
   Right-click or the `…` menu: `Always run with downloads`; an always-on lever's circle fills in frost, the way
   Control Center shows a toggle that is on.
7. Where it is: label + total, top 4 rows (icon 20 pt, name, subline, size), `All 16`, duplicate-server row.
8. Footer: Autopilot switch (frost tint); the helper shows here only when it needs a click (`Update helper` /
   `No helper` / `Helper silent`).

Numbers: every amount in the panel, the download page and the receipt rows is SF Pro with tabular digits (frost
when it is memory back). SF Mono is kept for the receipt's one system line and the printed receipt on the share card.

## 6. Download and receipt

Download: `Downloading RAM` + phase pill in plain words (`baseline…`, `asking apps…`, `settling…`, `restarting…`,
`quitting…`, `done`); the stick fills in frost with a bright write-head cell at the edge; the counter (`+921.2 MB`,
44 pt light with a 20 pt unit, frost when positive); rate and time left; the apps giving memory back; levers landing
with their measured bytes.
Receipt (in the panel): `+2.80 GB` payoff (light 52 pt, frost) `back in 24 s`; one line per lever; one quiet line
`wall 37% → 36% · swap 13.1 → 13.4 GB`; `Share receipt` (primary) and `Done`. When nothing came back the title reads
`Finished`, there is nothing to share, and `Done` is the primary. Details (not counted, method) sit behind a
disclosure so the slip stays short.
Share card (1200 x 675): a paper thermal receipt on charcoal: mono, dashed rules, `DOWNLOAD MORE RAM`, date and
machine, one line per lever, `TOTAL 2.80 GB BACK`, the wall before → after; beside it the hook, `+2.80 GB` in frost
over `of RAM downloaded` (the joke the card exists for; the receipt carries the measurement), the lit stick, the
repo URL.

## 7. Hero clip (18 s, 4:5, from a real recording)

0.0 the real menu bar: chip + `38%`, the panel already open, warm · 0.25 press · 0.7-5.6 the stick fills in frost,
the counter climbs, the bar counts `+… MB` with the chip blinking at 2 Hz · 5.6-6.6 lever tiles land · 6.6 payoff ·
8.6-14.4 the receipt · 15-18 end card. Drawn at 2.6x, top-aligned on a dark cool desk: the menu bar is always in
shot and the main page runs off the bottom into a fade; pages hand over in sequence (out 0.12 s, in 0.18 s with a
6 pt rise) while the panel's height eases to the next page, never two big numbers on screen at once. Captions <= 5 words per beat. Post copy carries the price hook (40) and the restraint lines
(binary size, no telemetry, measured with phys_footprint).

## 8. Anti-goals

The owner: anything like v1 (grey hairline lists, the generic black bar button, debug-looking lever rows, a text
wall), orange next to green, unreadable icons, hint or fluff text. Commenters: glass or motion that costs time (30,
31); the notch as home and a crowded bar; AI-made or fake recordings; ambiguous percentages (say what the number
is); one-click destructive actions (tiles arm first); copycat smell (the stick and the temperature carry identity,
not the AC layout verbatim); half-committed metaphors; bloat; rows that VoiceOver reads as one blob.

## 9. House style kept

Native SwiftUI/AppKit, SF Symbols, system type, idle cost near zero, `--render-ui DIR` renders every state in
light and dark, nothing animates at rest, every number from a measurement.
