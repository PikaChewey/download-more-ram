<h1 align="center">Download More RAM</h1>

<p align="center"><b>The meme, but it actually works. And it shows receipts.</b><br>
A native macOS menu bar app + <code>ram</code> CLI that gets your apps to give memory back, finds what your AI
agents left running, and warns you before "Your system has run out of application memory".</p>

<p align="center"><img src="docs/demo.svg" alt="ram download: a real recorded run, the kernel signal then a Firefox GPU restart, 921.2 MB back" width="760"></p>

<!-- DEMO:BEGIN -->
Real output, 2026-10-20 13:10 on the author's Mac ([full log](bench/logs/demo-download.log), [receipt and frames](bench/results/2026-10-20T13-10-demo-recording.json)):

```
$ ram download --levers firefox-gpu --record bench/results/2026-10-20T13-10-demo-recording.json
Downloading RAM — macOS memory-pressure signal (critical, 10s) via helper, measured with phys_footprint
✓ Downloaded 921.2 MB of RAM in 24s
  macOS memory-pressure signal          -5.6 MB  Firefox +13.5 MB, Claude Code +704 KB, Claude Code +608 KB, Claude +384 KB
  Restart Firefox's GPU process       +926.8 MB  GPU process 2.50 GB → 1.48 GB
  not counted (busy): Claude Code -806.5 MB
  Swap 13.12 GB → 13.43 GB · pressure warning → warning · wall 37% → 36%
  Measured with phys_footprint (Activity Monitor's Memory column); busy apps and apps that started/quit are not counted.
```
A second recorded run that afternoon returned 570.9 MB ([log](bench/logs/demo-download-final.log)).
<!-- DEMO:END -->

## What it found on the author's 16 GB MacBook (one week in October 2026)

- **macOS killed 6,645 background processes in 11 minutes** (Oct 16, 4 AM; cfprefsd alone 491 times) while the
  Claude app and what its agent sessions launched held 45.5 GB, 35.7 GB of it in 23 python3.12 processes.
  macOS writes a report (JetsamEvent) when it has to kill processes to cope; three of this week's six wall
  hits left none, so `ram doctor` reads both those reports and the system log, and names who filled memory
  ([evidence](bench/evidence/2026-10-20T13-45-crisis-reports.json)).
- **16 copies of the same MCP server, 3.15 GB.** Every Claude Code session starts its own copy of every stdio
  MCP server you configure globally. `ram agents` lists them and `ram doctor` names the config to change
  ([evidence](bench/evidence/2026-10-20T13-18-agents.json)).
- **Firefox's GPU process had grown to 7.15 GB in just under 4 days.** One restart (Firefox relaunches it itself)
  and Firefox's footprint fell by about 6 GB, 18.35 → 12.34 GB; the GPU process went 7.15 → 1.68 GB
  ([measurement](bench/results/2026-10-20T12-42-firefox-gpu-restart.json),
  [raw output](bench/evidence/2026-10-20T12-42-firefox-gpu-restart-output.txt)).
- **The out-of-memory panel came up three times in one night** (10:50 PM, 3:40 AM and 4:49 AM; the last stayed up
  until 10:28 AM), and macOS paused Firefox, then ChatGPT ([panel log](bench/evidence/2026-10-20-loginwindow-panels.txt)).
  At 6:44 AM `ram doctor` found six apps the kernel had partly paused and never resumed; at 10:01 five were still
  paused and their helper processes were using 6 CPU cores between them
  ([6:44](bench/evidence/2026-10-20T06-44-doctor.txt), [10:01](bench/evidence/2026-10-20T10-01-doctor-paused.txt)).
  `ram resume` makes the same call as the panel's Resume button.
- **The wall was hit 6 times in a week.** `ram doctor` reads the system log and lists every time
  ([evidence](bench/evidence/2026-10-20T13-18-doctor.json)).

## Why your Mac says it ran out of memory (it's not what you think)

macOS compresses idle memory, then pages it out to swapfiles it adds 1 GB at a time. The "out of application
memory" panel appears when **swap is nearly full and macOS fails to add the next swapfile**, or when the
compressor hits its ceiling (about 49 GB of compressed data on a 16 GB Mac). The kernel then **starts pausing
apps, one every 5 seconds while swap stays full** (the biggest that registered for it first); Resume un-pauses
them, but the loop keeps going until memory frees up. Free disk space is usually not the problem: this Mac hit the
wall with tens of gigabytes free. [The kernel source, line by line →](docs/HOW_IT_WORKS.md)

## What it does

| | |
|---|---|
| **Downloads RAM** | `ram download` sends macOS's own *critical* memory-pressure signal for 10 s (the root-only switch behind Apple's `memory_pressure -S`), then pulls the levers you allow, one at a time, each measured on its own. The receipt's headline is exactly the sum of the levers. |
| **Levers** | Firefox GPU process restart · quit leftover servers your agents forgot · quit agent sessions you archived that are still running · resume apps macOS paused. Each lever runs only when you name it (`--levers`) or click it; quitting leftovers or archived sessions lists them first and asks. Levers you mark *Always* in the app also run inside autopilot downloads. |
| **Explains past crises** | Reads the reports macOS writes when it runs out of memory (`JetsamEvent`): who held the memory and how many background processes the kernel killed to cope. |
| **Shows the wall** | "38% to the wall" from the limits the kernel actually checks, the time until you hit it, which app is pushing you there right now ("growing: Firefox +1.08 GB/min (plugin-container ×38)", [recorded](bench/evidence/2026-10-20T13-46-watch.txt)), which app macOS will pause first, a warning the moment swap is full and no new swapfile appears, and a notification when the wall is minutes away that names who is growing. |
| **Agents** | Memory per Claude Code / Codex / Cursor / Gemini session with its real title, archived-but-running sessions, duplicate MCP servers, orphaned dev servers. |
| **Firefox** | Turns on Firefox's low-memory tab unloader (shipped **off** outside Nightly: `browser.lowMemoryResponseMask = 0`). Firefox reads it at launch, and `ram doctor` tells you when it is still waiting for a restart. |
| **Autopilot** | When the wall is near (85%, or under 5 minutes away at the current rate) it sends the signal plus any lever you set to *Always*. On an Electron-heavy Mac expect the signal part to be small (see the honest numbers). |

## Who actually responds to the signal (read from source, not vibes)

| App type | On the signal |
|---|---|
| Safari, Mail, WKWebView apps | Drop caches, JIT code, back/forward cache; synchronous GC |
| Chrome (and Chromium browsers that keep its default) | Discard one background tab per critical notification; GPU caches |
| Electron (Claude, Discord, Slack, VS Code) | GPU + network caches only; **page processes never hear it on macOS** |
| Firefox (release) | Nothing, until `ram firefox unloader on` |
| Node / Bun (agents, MCP servers) | Nothing; the levers are what works |

## The honest numbers

On a Mac full of Electron apps and agents, the signal on its own is not significant: most of those
processes never hear it (table above). Processes that do listen give back everything they can: the
pressure-aware test process returned all 112 MB of its cache in every relief run and nothing in the
control runs, while the one that ignores pressure returned nothing in either. The real-bench mean is
dominated by one trial in which an agent session's child process exited during the window, which the method
counts as returned memory ([BENCHMARKS.md](docs/BENCHMARKS.md)). A fresh 437 MB allocation (the harness sizes
it to a quarter of what macOS can still hand out) was not measurably faster after the signal (0.12 s either
way, p = 0.50), so this is not a speed-up button. The gigabytes come from the levers and the findings at the
top.

<!-- BENCH:BEGIN -->
- **real** · net bytes returned: relief +478.5 MB vs control -72.0 MB (n = 5, p = 0.147) on Apple M5 · 16 GB
- **synthetic** · net bytes returned: relief +56.5 MB vs control -42.8 MB (n = 3, p = 0.520) on Apple M5 · 16 GB
- **synthetic** · cachehog bytes returned: relief +112.0 MB vs control +16 KB (n = 6, p < 0.001) on Apple M5 · 16 GB
- **perf** · net bytes returned: relief +200.8 MB vs control -488.8 MB (n = 5, p = 0.211) on Apple M5 · 16 GB
- **perf** · workload seconds: relief 0.12 s vs control 0.12 s (n = 5, p = 0.502) on Apple M5 · 16 GB
- **perf** · workload swapouts: relief 6674 vs control 7953 (n = 5, p = 0.764) on Apple M5 · 16 GB

_Generated by `ram bench report` from `bench/results/`; method and every run in [docs/BENCHMARKS.md](docs/BENCHMARKS.md)._
<!-- BENCH:END -->

## Install

```bash
git clone https://github.com/PikaChewey/download-more-ram && cd download-more-ram
scripts/install.sh                  # builds, signs, puts the app in /Applications and `ram` in ~/.local/bin
sudo ~/.local/bin/ram helper install  # once: the only step that needs your password
ram doctor
```

## Commands

```
ram                         memory, swap, distance to the wall, top apps
ram doctor [--fast]         wall history, who filled memory in each crisis, fixes ranked by size
ram download [--levers firefox-gpu,leftovers,archived,resume]
                            the kernel's memory-pressure signal + the levers you allow, with a receipt
ram download --dry-run      the same measurement without the signal: your Mac's natural drift
ram agents                  agent sessions, duplicate servers, leftovers
ram resume                  resume apps macOS paused at the wall
ram firefox unloader on     let Firefox unload idle tabs under memory pressure
ram watch [--autopilot]     live distance to the wall and who is growing; --autopilot downloads before the wall
ram bench real              relief vs control runs with Welch's t-test
```

## What it won't do

- **No `purge`.** It only flushes the file cache, which macOS reclaims on its own anyway. Most "RAM cleaners" are
  a button for it.
- **No balloon allocations, no "free RAM" bragging.** Free RAM is wasted RAM.
- **Nothing is killed or paused unless you asked:** a click, a lever you named, or one you set to *Always*.
- **No network, no telemetry.**

## Safety

The root helper accepts four calls: send the signal (warn or critical, 1–30 s, at most 30 per hour), restore
normal, report status, and resume a process the kernel paused at the wall. It restores normal pressure on every
path, including Ctrl-C, crashes and SIGKILL. What a download costs (apps drop caches, Chrome discards a background
tab, the kernel stops idle daemons and launchd relaunches them on demand) is listed in [docs/SECURITY.md](docs/SECURITY.md).

## FAQ

**Is this a RAM cleaner?** No. It never purges caches itself; it asks apps through the kernel's own signal and
reports per app what came back, including when nothing did.

**Why is the signal's number small on my Mac?** If you mostly run Electron apps and agents, most of them can't hear
the signal (see the table). The levers and the agent insights are where the gigabytes are.

**Why doesn't Activity Monitor's "Memory Used" drop?** On a Mac that is already compressing, most of what an
idle process holds is compressed data. In a verified run of the installed app, the receipt said 2.80 GB back and
the compressor's data fell 3.04 GB in the same 24 s, yet "Memory Used" rose 0.34 GB: that data had been packed
about 4.9:1, and the RAM that did come back was taken by other processes within seconds
([numbers](bench/evidence/2026-10-21-app-verify-receipt-window.txt)). What you get back is room: 2.9 GB less
memory demand for the kernel to keep compressed.

**Can I check that it works on my Mac?** `scripts/verify-app.sh` measures a control window, then has the installed
app do exactly what its button does, and checks the helper's log for the app's own pid
([a run on the author's Mac](bench/results/2026-10-21T14-07-34-app-verify.json)).

**Is restarting Firefox's GPU process safe?** Firefox is built to relaunch it; WebGL and canvas content on open
pages resets. `ram` only restarts a GPU process that has been up for more than 30 s; Firefox counts a restart
against its crash limit only when the process had not yet been stable (30 s up and ten frames painted).

**Intel? Older macOS?** Apple silicon. It should run on macOS 14 or later (Package.swift), but it has only been
tested on macOS 26.5 (MacBook M5, 16 GB).

MIT License.
