<h1 align="center">Download More RAM</h1>

<p align="center"><b>The meme, but it actually works. And it shows receipts.</b><br>
A native macOS menu bar app + <code>ram</code> CLI that gets your apps to give memory back, finds what your AI
agents left running, and warns you before "Your system has run out of application memory".</p>

<p align="center"><img src="docs/demo.svg" alt="ram download: a real recorded run, the kernel signal then a Firefox GPU restart, 921.2 MB back" width="760"></p>

<!-- DEMO:BEGIN -->
<!-- Filled with the output of a real `ram download` on the author's Mac. -->
<!-- DEMO:END -->

## What it found on the author's 16 GB MacBook (one day, 2026-10-20)

- **macOS killed 6,645 background processes in 11 minutes** (Oct 16, 4 AM; cfprefsd alone 491 times) while the
  Claude app and what its agent sessions launched held 45.5 GB, 35.7 GB of it in 23 python3.12 processes.
  macOS writes a report for every memory crisis; `ram doctor` reads them and names who filled memory
  ([evidence](bench/evidence/2026-10-20T13-45-crisis-reports.json)).
- **16 copies of the same MCP server, 3.15 GB.** Every Claude Code session starts its own copy of every stdio
  MCP server you configure globally. `ram agents` lists them and `ram doctor` names the config to change
  ([evidence](bench/evidence/2026-10-20T13-18-agents.json)).
- **Firefox's GPU process had grown to 7.15 GB in just under 4 days.** One restart (Firefox relaunches it itself):
  6.02 GB back ([measurement](bench/results/2026-10-20T12-42-firefox-gpu-restart.json)).
- **macOS "paused" six apps at the memory wall and left them frozen for over 2 hours** (Claude, Firefox, ChatGPT,
  Opera GX, Discord, Raycast) while their helper processes kept burning about 6 CPU cores on battery.
  `ram resume` makes the same call as the panel's Resume button.
- **The wall was hit 6 times in a week.** `ram doctor` reads the system log and lists every time
  ([evidence](bench/evidence/2026-10-20T13-18-doctor.json)).

## Why your Mac says it ran out of memory (it's not what you think)

macOS compresses idle memory, then pages it out to swapfiles it adds 1 GB at a time. The "out of application
memory" panel appears when **swap is nearly full and macOS fails to add the next swapfile**, or when the
compressor hits its ceiling (about 49 GB of compressed data on a 16 GB Mac). The kernel then **pauses your
biggest app every 5 seconds** until you click Resume. Free disk space is usually not the problem: the panel showed
up here with 93 GB free. [The kernel source, line by line →](docs/HOW_IT_WORKS.md)

## What it does

| | |
|---|---|
| **Downloads RAM** | `ram download` sends macOS's own *critical* memory-pressure signal for 10 s (the root-only switch behind Apple's `memory_pressure -S`), then pulls the levers you allow, one at a time, each measured on its own. The receipt's headline is exactly the sum of the levers. |
| **Levers** | Firefox GPU process restart · quit leftover servers your agents forgot · quit agent sessions you archived that are still running · resume apps macOS paused. Anything that ends a process needs your yes; nothing runs on its own. |
| **Explains past crises** | Reads the reports macOS writes when it runs out of memory (`JetsamEvent`): who held the memory and how many background processes the kernel killed to cope. |
| **Shows the wall** | "38% to the wall" from the limits the kernel actually checks, the time until you hit it, which app is pushing you there right now ("growing: Firefox +1.08 GB/min (plugin-container ×38)", [recorded](bench/evidence/2026-10-20T13-46-watch.txt)), which app macOS will pause first, and a warning the moment swap is full and no new swapfile appears. |
| **Agents** | Memory per Claude Code / Codex / Cursor / Gemini session with its real title, archived-but-running sessions, duplicate MCP servers, orphaned dev servers. |
| **Firefox** | Turns on Firefox's low-memory tab unloader (shipped **off** outside Nightly: `browser.lowMemoryResponseMask = 0`). |
| **Autopilot** | When you're heading for the wall, it downloads RAM before macOS starts pausing apps. |

## Who actually responds to the signal (read from source, not vibes)

| App type | On the signal |
|---|---|
| Safari, Mail, WKWebView apps | Drop caches, JIT code, back/forward cache; synchronous GC |
| Chrome, Opera, Brave, Edge | Discard one background tab per critical notification; GPU caches |
| Electron (Claude, Discord, Slack, VS Code) | GPU + network caches only; **page processes never hear it on macOS** |
| Firefox (release) | Nothing, until `ram firefox unloader on` |
| Node / Bun (agents, MCP servers) | Nothing; the levers are what works |

## The honest numbers

On a Mac full of Electron apps and agents, the signal on its own is not significant: most of those
processes never hear it (table above). Processes that do listen give back everything they can: the
pressure-aware test process returned all 112 MB of its cache in every relief run and nothing in the
control runs, while the one that ignores pressure returned nothing in either. The gigabytes come from
the levers and the findings at the top.

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
- **Nothing is killed or paused without a click.**
- **No network, no telemetry.**

## Safety

The root helper accepts four calls: send the signal (warn or critical, 1–30 s, at most 30 per hour), restore
normal, report status, and resume a process the kernel paused at the wall. It restores normal pressure on every
path, including Ctrl-C, crashes and SIGKILL. What a download costs (apps drop caches, Chromium discards a background
tab, idle daemons exit and relaunch) is listed in [docs/SECURITY.md](docs/SECURITY.md).

## FAQ

**Is this a RAM cleaner?** No. It never purges caches itself; it asks apps through the kernel's own signal and
reports per app what came back, including when nothing did.

**Why is the signal's number small on my Mac?** If you mostly run Electron apps and agents, most of them can't hear
the signal (see the table). The levers and the agent insights are where the gigabytes are.

**Is restarting Firefox's GPU process safe?** Firefox is built to relaunch it; WebGL and canvas content on open
pages resets. A restart after 30 s of uptime does not count toward Firefox's crash limit.

**Intel?** Apple silicon, macOS 14 or later. Built and tested on macOS 26.5 (MacBook M5, 16 GB).

MIT License.
