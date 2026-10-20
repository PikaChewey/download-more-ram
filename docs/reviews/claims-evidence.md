# Claims review: every public claim against its evidence

Independent review of the public surfaces of Download More RAM before launch: README.md (text, DEMO block,
BENCH block, tables), LAUNCH.md (X thread, Show HN, Reddit), docs/HOW_IT_WORKS.md, docs/SECURITY.md,
docs/BENCHMARKS.md, docs/demo.svg, docs/share-card.png, docs/clip/download.mp4 (+ sidecar) and `ram --help`.
The reviewer did not write any of it and checked it the way a skeptical HN commenter with time would.

Evidence classes, strongest first: files a tool wrote (bench/results, bench/evidence, bench/logs, saved
receipts, macOS JetsamEvent reports, the system log), source code (file:line), primary sources fetched from
apple-oss-distributions/xnu, system_cmds, libmalloc, Chromium, WebKit and mozilla-firefox/firefox (`main`),
then the author's own notes (PROGRESS.md, docs/research/*.md), which are named as such wherever a claim rests
only on them.

What the reviewer ran (all read-only): recounts of the 14 `/Library/Logs/DiagnosticReports/JetsamEvent-*.ips`
files; Welch's t-test recomputed from `arms[]` of the three bench JSON files; headline = sum-of-levers checked
in all 9 saved receipts and both recordings; sha256 of the demo recording against docs/demo-source.json and
docs/clip/download.json; `ffprobe` and nine frames from the clip; the share card; `sysctl` compressor limits;
`nm -u` on loginwindow; `ram doctor --json` (14:40); `/usr/bin/log show` with `WallEventLog.predicate` over
2026-10-20 02:00–13:30 (reviewer capture, 13,555 lines, not committed); `ram --help`. Nothing was modified
except this file.

Units: the app prints binary units labelled GB/MB (1 GB = 2^30 B), like Activity Monitor; all recomputed
numbers below use the same convention.

## Claim table

Where: README · X1–X10 (tweets) · HN (Show HN text) · Reddit (title) · HOW §n (docs/HOW_IT_WORKS.md) ·
SEC (docs/SECURITY.md) · BENCH (docs/BENCHMARKS.md) · SVG (docs/demo.svg) · CARD (docs/share-card.png) ·
CLIP (docs/clip/download.mp4) · HELP (`ram --help`). Paths are relative to the repo root unless absolute.

| # | Claim (quote) | Where | Evidence (path:field/line) | Verdict | Fix |
|---|---|---|---|---|---|
| 1 | "The meme, but it actually works. And it shows receipts." | README | `~/Library/Application Support/DownloadMoreRAM/receipts/*.json` (9); headline == Σ lever bytes in all 5 multi-lever receipts | SUPPORTED | — |
| 2 | "warns you before 'Your system has run out of application memory'" | README | Sources/RAMKit/Wall/WallWarning.swift:5-15 (85 %, ETA ≤ 15 min, or imminent); no recorded warning in bench/ | SUPPORTED (source) | — |
| 3 | SVG alt: "a real recorded run … 921.2 MB back" | README | bench/results/2026-10-20T13-10-demo-recording.json receipt.headlineBytes 965,903,584 = 921.16 MiB; sha256 == docs/demo-source.json | SUPPORTED | — |
| 4 | "Real output, 2026-10-20 13:10 … full log … receipt and frames" | README | bench/logs/demo-download.log: every line of the block appears verbatim; receipt.startedAt 2026-10-20T17:10:58Z (13:10 EDT) | SUPPORTED | — |
| 5 | "$ ram download --levers firefox-gpu" | README, SVG | the 13:10 recording has no `command` key (added later, commit 0a27fd8); scripts/make-demo-svg.py:26-28 rebuilds it from the levers; the real run also carried `--record` | SUPPORTED (reconstructed, same output) | optional: show `--record r.json` |
| 6 | "Downloaded 921.2 MB of RAM in 24s" | README, SVG, CARD, CLIP | receipt.durationS 24.24; levers −5,898,624 + 971,802,208 = 965,903,584 | SUPPORTED | — |
| 7 | "signal −5.6 MB … GPU +926.8 MB … 2.50 GB → 1.48 GB … busy Claude Code −806.5 MB … Swap 13.12 → 13.43 … wall 37 % → 36 %" | README, CARD, CLIP | receipt.levers[0].bytes −5,898,624 (−5.63 MiB); levers[1].bytes 971,802,208 (926.8 MiB) + detail; excludedBusy[0] 8,743,607,080 → 9,589,332,536 (+806.5 MiB); swapUsed 13.120 → 13.435 GiB; wallBefore/After 36.82 / 36.41 | SUPPORTED | — |
| 8 | "macOS killed 6,645 background processes in 11 minutes" | README, X4 | recount of the 9 `JetsamEvent-2026-10-16-04*.ips`: 6,645 entries with `reason` (6,644 distinct pids), 04:02:13–04:12:58 EDT (10 m 45 s); all 215 killed names are daemons/XPC helpers; bench/evidence/2026-10-20T13-45-crisis-reports.json jetsam[0] | SUPPORTED | — |
| 9 | "(Oct 16, 4 AM; cfprefsd alone 491 times)" | README, X4 | recount: cfprefsd 491 kills; report dates 04:02–04:13 local | SUPPORTED | — |
| 10 | "the Claude app and what its agent sessions launched held 45.5 GB" | README, X4 | JetsamEvent-2026-10-16-040546.ips coalition 40775, 133 live members, Σ rpages × 16 KiB = 48,886,661,120 B = 45.53 GiB (grouping per Sources/RAMKit/Doctor/JetsamReports.swift:105-115; oldest member is Claude) | SUPPORTED | — |
| 11 | "35.7 GB of it in 23 python3.12 processes" | README, X4 | same coalition: 23 × python3.12 = 38,367,641,600 B = 35.73 GiB | SUPPORTED | — |
| 12 | "macOS writes a report for every memory crisis" | README | 14 JetsamEvent files, all dated Oct 16–17; the three Oct 20 wall hits (doctor.json events[3-5]) left none | OVERSTATED | M2 |
| 13 | "`ram doctor` reads them and names who filled memory" | README | JetsamReports.swift; `ram doctor --json` at 14:40: jetsam section identical to the evidence file | SUPPORTED | — |
| 14 | "16 copies of the same MCP server, 3.15 GB" | README, X5 | bench/evidence/2026-10-20T13-18-agents.json duplicates[0]: count 16, sessions 11, bytes 3,386,536,288 = 3.154 GiB (doctor.json fixes[0].estimateBytes 2.96 GiB is the saving, one copy stays) | SUPPORTED | — |
| 15 | "Every Claude Code session starts its own copy of every stdio MCP server you configure globally" | README, X5 | observed 16 copies / 11 sessions (13:18) and 14 / 11 (14:40 re-run); Sources/RAMKit/Process/ClaudeMCPConfig.swift:3; no Anthropic doc cited | SUPPORTED (observation) | optional: cite the Claude Code MCP scope docs |
| 16 | "Firefox's GPU process had grown to 7.15 GB in just under 4 days" | README, X6 | bench/results/2026-10-20T12-42-firefox-gpu-restart.json gpuProcessBefore "7.15 GB (uptime 3d 23h)" is a hand-written string (committed 12:44, eed9d32); bench/logs/firefox-gpu-restart.log holds only the AFTER samples | OVERSTATED (provenance) | M1 |
| 17 | "One restart (Firefox relaunches it itself): 6.02 GB back" | README, X6 | same JSON: firefoxBefore 19,706,451,968 − firefoxAfter60s 13,246,742,216 = 6,459,709,752 B = 6.016 GiB; that is the Firefox group, the GPU process itself went 7.15 → 1.68 GB (5.47); the log's Firefox total swings 13.14 → 13.96 → 13.25 GB inside the same minute | OVERSTATED (precision, provenance) | M1 |
| 18 | "macOS 'paused' six apps … frozen for over 2 hours (Claude, Firefox, ChatGPT, Opera GX, Discord, Raycast) … about 6 CPU cores on battery" | README | only PROGRESS.md:31-32 (committed 10:03); no `top`/doctor capture exists; system log (loginwindow, 2026-10-20): "Firefox is low mem paused" 03:33–03:34, "ChatGPT is low mem paused" 03:52–03:59, no app named in the 04:49 episode (panel open 04:49:18–10:28:29); doctor.json events[3-5] pausedApps = [Firefox], [ChatGPT], [] | UNSUPPORTED / contradicted | H1 |
| 19 | "`ram resume` makes the same call as the panel's Resume button" | README | Sources/CDarwinMem/cdarwinmem.c:323-327 (proc_clear_vmpressure); `nm -u` on loginwindow imports `_proc_clear_vmpressure` | SUPPORTED | — |
| 20 | "The wall was hit 6 times in a week" | README | doctor.json events (6: Oct 16 ×3, Oct 19/20 ×3); reproduced at 14:40; raw loginwindow `showLowMemoryPanel` lines 03:23, 03:40, 04:49 on Oct 20 | SUPPORTED | — |
| 21 | "swapfiles it adds 1 GB at a time" | README, HOW §1 | xnu osfmk/vm/vm_compressor_backing_store_internal.h MAX_SWAP_FILE_SIZE 1 GiB (macOS); /System/Volumes/VM/swapfile0-8 are 1,073,741,824 B each | SUPPORTED | — |
| 22 | "swap is nearly full and macOS fails to add the next swapfile" | README, X2, HOW §1 | xnu vm_compressor_backing_store.c vm_swap_low_on_space(): free < hiwater/8 AND (last create failed after last success OR files == config max) | SUPPORTED | — |
| 23 | "compressor hits its ceiling (about 49 GB of compressed data on a 16 GB Mac)" | README, HOW §1 | `sysctl vm.compressor.segment.limit` 805,810 × 64 KiB (C_SEG_BUFSIZE_ARM_SWAP, xnu vm_compressor.c) = 49.2 GiB; 98 % = 48.20 GB (doctor.json wall.reason) | SUPPORTED | — |
| 24 | "pauses your biggest app every 5 seconds until you click Resume" | README, X2 | xnu kern_memorystatus.c no_paging_space_action_throttle_delay_ns = 5 s; kern_proc.c proc_dopcontrol on the largest not-yet-acted registrant; Resume resumes one process, the 5 s loop continues while swap stays low | IMPRECISE | L18 |
| 25 | "this Mac hit the wall with tens of gigabytes free" | README, X2 | receipts systemBefore.vmVolumeFreeBytes 78.0 GiB (13:10) / 70.9 GiB (14:08); docs/research/xnu.md:38 "93 GB" at 04:38 (note) | SUPPORTED | — |
| 26 | "sends macOS's own critical memory-pressure signal for 10 s (the root-only switch behind `memory_pressure -S`)" | README, X7, HN | Sources/RAMKit/Relief/Trigger.swift; Sources/RAMKit/Bench/Bench.swift:25 (default 10 s); Sources/RAMApp/AppModel.swift:293; system_cmds memory_pressure.c (request 6, reset NORMAL); kern_memorystatus_notify.c sysctl without CTLFLAG_ANYBODY | SUPPORTED | — |
| 27 | "pulls the levers you allow, one at a time, each measured on its own" | README, X7 | Sources/RAMKit/Relief/Levers.swift:145-211 (own before/after per lever) | SUPPORTED | — |
| 28 | "The receipt's headline is exactly the sum of the levers" | README | all 5 multi-lever receipts and both recordings: headlineBytes == Σ levers[].bytes | SUPPORTED | — |
| 29 | "Anything that ends a process needs your yes; nothing runs on its own" | README | Levers.swift:25 needsConsent; Sources/RAMCLI/main.swift:183-213 asks only for leftovers/archived; `--levers firefox-gpu` restarts the GPU process with no prompt; app "Always" levers run inside autopilot downloads (AppModel.swift:536-541) | IMPRECISE | L4 |
| 30 | "'38% to the wall' … time until you hit it … 'growing: Firefox +1.08 GB/min (plugin-container ×38)'" | README | bench/evidence/2026-10-20T13-46-watch.txt 1:47:30 PM | SUPPORTED | — |
| 31 | "which app macOS will pause first" | README, X9 | Sources/RAMKit/Wall/WallModel.swift:142-162; doctor.json insights.nextToPauseApp | SUPPORTED | — |
| 32 | "a warning the moment swap is full and no new swapfile appears" | README | WallModel.swift:33-34, 102-119 (15 s); WallWarning.swift:23 | SUPPORTED | — |
| 33 | "Memory per Claude Code / Codex / Cursor / Gemini session with its real title" | README | Sources/RAMKit/Process/AgentTool.swift:5-41; AgentClassifier.swift:30-64 (title from the Claude app's session record); evidence shows only Claude Code and Codex sessions | SUPPORTED (Cursor/Gemini by source only) | — |
| 34 | "Firefox's low-memory tab unloader (shipped off outside Nightly: `browser.lowMemoryResponseMask = 0`)" | README, X9, HOW §2 | mozilla-firefox/firefox browser/app/profile/firefox.js: 3 under NIGHTLY_BUILD, else 0 | SUPPORTED | — |
| 35 | "Autopilot: When you're heading for the wall, it downloads RAM before macOS starts pausing apps" | README | Sources/RAMKit/Autopilot/AutopilotPolicy.swift:14-19 (85 %, ETA < 5 min, imminent, critical 20 s); AppModel.swift:644-651 → download (signal + Always levers); no autopilot run in any file; the README's own bench says the signal alone is not significant here | MISLEADING | M3 |
| 36 | "Safari, Mail, WKWebView apps: Drop caches, JIT code, back/forward cache; synchronous GC" | README, HOW §2 | WebKit Source/WebCore/page/MemoryRelease.cpp releaseCriticalMemory: BackForwardCache pruneToSizeNow(0), pruneLiveResourcesToSize(0), deleteAllCode, garbageCollectNow | SUPPORTED | — |
| 37 | "Chrome, Opera, Brave, Edge: Discard one background tab per critical notification" | README, HOW §2, SEC | Chromium urgent_page_discarding_policy.cc: DiscardAPage per event at the critical threshold (non-ChromeOS); Opera/Brave/Edge defaults not checked | IMPRECISE | L9 |
| 38 | "Electron: GPU + network caches only; page processes never hear it on macOS" | README, HOW §2, X8 | Chromium content/browser/renderer_host/render_process_host_impl.cc OnMemoryPressure forwards only under `#if BUILDFLAG(IS_ANDROID) \|\| BUILDFLAG(IS_CASTOS)` | SUPPORTED | — |
| 39 | "Node / Bun: Nothing; the levers are what works" | README, HOW §2, X8 | no pressure handler in Node or Bun (absence; docs/research/apps.md) | SUPPORTED (by absence) | — |
| 40 | "the signal on its own is not significant" | README, X8 | bench/results/2026-10-20T12-44-09-real.json summaries[0].welch.p 0.1466 (recomputed 0.147) | SUPPORTED | — |
| 41 | "the pressure-aware test process returned all 112 MB … nothing in the control runs … the one that ignores pressure returned nothing in either" | README | bench/results/2026-10-20T13-14-02-synthetic.json arms[].fixtures: cachehog 119,210,464 → 1,753,496 in every relief arm (112.0 MiB), 16 KiB in control; dumbhog 16 KiB in both | SUPPORTED | — |
| 42 | "A fresh 1 GB allocation was not measurably faster after the signal (0.12 s either way, p = 0.50)" | README | bench/results/2026-10-20T13-48-19-perf.json notes[0] "allocate and write 437 MiB"; arms[].workload.sizeMB 437; seconds 0.123 vs 0.118, p 0.502 | WRONG (size) | H2 |
| 43 | BENCH block (6 lines) | README | Welch recomputed from arms[].headlineBytes / workload: real t 1.79 p 0.147; synthetic 0.76 / 0.520; cachehog p < 0.001; perf 1.46 / 0.211, 0.72 / 0.502, −0.31 / 0.764; machine fields match | SUPPORTED | M6 (disclosure) |
| 44 | "Generated by `ram bench report` from bench/results/" | README, BENCH | Sources/RAMKit/Bench/BenchReport.swift; `ram bench report` in HELP | SUPPORTED | — |
| 45 | Install: "builds, signs, puts the app in /Applications and `ram` in ~/.local/bin … sudo … once" | README | scripts/install.sh:6-19; scripts/build.sh:57-59 (codesign); SEC | SUPPORTED | — |
| 46 | Commands block | README | `build/Products.noindex/bin/ram --help` (same commands and flags, README is a subset) | SUPPORTED | — |
| 47 | "No `purge` … No balloon allocations" | README, HOW §4, X10 | no purge/mmap/balloon call anywhere in Sources (only the RAMFixtures hogs for the bench) | SUPPORTED | — |
| 48 | "Nothing is killed or paused without a click" | README, X10 | Sources/RAMKit/Kill/SafeKill.swift is the only signaller; needsConsent levers; CLI prompt; app Always toggle (see L4) | SUPPORTED | — |
| 49 | "No network, no telemetry" | README, SEC, HN, X10 | grep: no URLSession / NWConnection / socket in Sources | SUPPORTED | — |
| 50 | "four calls: send the signal (warn or critical, 1–30 s, at most 30 per hour), restore normal, report status, resume" | README, SEC, HN | Sources/RAMKit/Helper/HelperProtocol.swift:5-15; HelperPolicy.swift:28-30 | SUPPORTED | — |
| 51 | "restores normal pressure on every path, including Ctrl-C, crashes and SIGKILL" | README, SEC, HN | Sources/RAMKit/Relief/ReliefBackends.swift:17-48; cdarwinmem.c:335-397 (23 signals); Sources/RAMHelper/main.swift:174-179 (orphan markers at start); Sources/RAMKit/Helper/HelperInstaller.swift:42-46 (RunAtLoad, KeepAlive/SuccessfulExit) | SUPPORTED | — |
| 52 | FAQ: "Firefox is built to relaunch it; WebGL and canvas … A restart after 30 s of uptime does not count toward Firefox's crash limit" | README, HOW §3 | StaticPrefList.yaml: layers.gpu-process.stable.min-uptime-ms 30000, stable.frame-threshold 10, max_restarts 6; gfx/ipc/GPUProcessManager.cpp resets the counter only if IsProcessStable (uptime AND declared stable); Sources/RAMKit/Levers/FirefoxLevers.swift:12,107-109 checks uptime only | IMPRECISE | L8 |
| 53 | "Apple silicon, macOS 14 or later. Built and tested on macOS 26.5 (MacBook M5, 16 GB)" | README | Package.swift:13 `.macOS(.v14)`; receipts machine {Apple M5, Mac17,2, 17,179,869,184 B, macOS 26.5.2}; nothing was tested below 26.5 | IMPRECISE | L13 |
| 54 | "MIT License" | README | LICENSE | SUPPORTED | — |
| 55 | "said … 6 times this week" | X1 | events on Fri Oct 16 (3) and Oct 19/20 (3) | IMPRECISE | L3 |
| 56 | "the 18 s clip rendered from a real recording" | X1, LAUNCH | `ffprobe` docs/clip/download.mp4: 18.000 s, 540 frames, 1080×1350; docs/clip/download.json sha256 == the 13:10 recording | SUPPORTED | — |
| 57 | "At 4:49 AM it paused ChatGPT, Firefox, Discord and Opera. Two hours later … ~6 CPU cores. On battery." | X3 (its source line cites `top` + doctor at 07:00, which were not saved) | see #18: loginwindow named ChatGPT at 03:52 and Firefox at 03:33, nothing at 04:49; Discord and Opera never | UNSUPPORTED / contradicted | H1 |
| 58 | "+478 MB on average vs −72 MB … p = 0.15, n = 5" | X8 | real.json summaries[0]: 501,704,899 B (478.5 MiB) vs −75,477,883 B (−72.0 MiB), p 0.147 | SUPPORTED | M6 (disclosure) |
| 59 | "Clip (18 s, 1:1, rendered offscreen …)" | LAUNCH | docs/clip/download.json size 1080x1350 (4:5); commit 46e1a66 | IMPRECISE (stale) | L1 |
| 60 | "`kern.memorypressure_manual_trigger`, what Apple's `memory_pressure -S` uses" | HN | system_cmds memory_pressure/memory_pressure.c; kern_memorystatus_notify.c | SUPPORTED | — |
| 61 | "measures per app (phys_footprint, busy apps excluded, control runs + Welch's t-test)" | HN | cdarwinmem.c:135-148 (ri_phys_footprint); Sources/RAMKit/Relief/Measurement.swift:36-62; Bench.swift; Sources/RAMKit/Util/Stats.swift:92-105 | SUPPORTED | — |
| 62 | "restores … (signal guard, per-process markers, launchd relaunch) … limits XNU checks … resumes apps the kernel paused … attributes memory to AI agent sessions" | HN | #51, #23, #19, #33 | SUPPORTED | — |
| 63 | "My Mac paused 6 apps … their helpers kept burning 6 cores" | Reddit | see #18 | UNSUPPORTED / contradicted | H1 |
| 64 | "adds 1 GB swapfiles as needed, up to 100" | HOW §1 | xnu vm_compressor_backing_store.c VM_MAX_SWAP_FILE_NUM 100 on macOS | SUPPORTED | — |
| 65 | "The dialog appears when the kernel's `no_paging_space_action()` runs" | HOW §1 | kern_memorystatus.c memstat_perform_no_paging_space_action: the low-swap note is sent when no_paging_space_action returns true | SUPPORTED | — |
| 66 | "Free swap is under 32 MB and the most recent swapfile creation failed (or 100 files already exist)" | HOW §1 | vm_swapfile_hiwater_segs = MIN_SWAP_FILE_SIZE (256 MiB on macOS) / chunk; low = hiwater / 8 = 32 MiB | SUPPORTED | — |
| 67 | "98% of its segment or page limits … Segments count compressed memory in RAM and in swap" | HOW §1 | vm_compressor.c c_segments_nearing_limit = limit × 98 / 100; `vm.compressor.segment.total` 246,696 (15 GiB) exceeds what fits in RAM, so swapped segments are counted | SUPPORTED | — |
| 68 | "suspends the largest app that registered … asks loginwindow … Every 5 seconds it pauses the next one" | HOW §1 | kern_proc.c proc_dopcontrol: P_PCSUSP → task_suspend; 5 s throttle; Sources/RAMKit/Doctor/WallEventLog.swift:10-11 (loginwindow lines) | SUPPORTED | L10 (wording) |
| 69 | "didn't register … more than half of all compressed memory … killed outright instead, with no dialog" | HOW §1 | kern_proc.c: npcs_max_size > 50 % of compressed pages → SIGKILL and `return false`, so no low-swap note | SUPPORTED | — |
| 70 | "Swap had stopped at 11 swapfiles because creating the next one (`swapfile11`) failed, and that alone is enough" | HOW §1 | the state (11 files, 93 GB free) is only in docs/research/xnu.md:38 and PROGRESS.md:33; the inference holds (panel at 11 files ⇒ a failed creation; the compressor ceiling was at ~36 %) | IMPRECISE | L11 |
| 71 | "warns the moment swap is full and no new swapfile has appeared for 15 s" | HOW §1 | WallModel.swift:34 stuckAfterS 15; xnu vm_swapfile_creation_delay_ns 15 s | SUPPORTED | — |
| 72 | "'Paused' is not as paused as it sounds … Codex helpers … about 4 cores, Discord and Opera renderers about 1 core each, for over two hours … load average 10.3 on a 10-core machine" | HOW §1 | PROGRESS.md only (see #18); Sources/RAMKit/Doctor/Diagnosis.swift:27 (a code comment, not data) | UNSUPPORTED | H1 |
| 73 | "`ram doctor` reports this ('ChatGPT is paused, but its helpers are using 4.0 cores')" | HOW §1 | Sources/RAMKit/CLI/Render.swift:199 format string; Diagnosis.swift:51-57 (the message exists; the quoted instance was never captured) | SUPPORTED (message) | H1 (number) |
| 74 | "Each process's pause registration is visible to any user (the `PROC_FLAG_PC_SUSP` flag)" | HOW §1 | Sources/RAMKit/Process/ProcessSample.swift:44,51 (0x400 / 0x1000); doctor.json nextToPause.bsdFlags 0x1404410 carries 0x400 | SUPPORTED | — |
| 75 | "Raycast's web-networking helper was still frozen hours after the panel closed" | HOW §1 | docs/research/xnu.md:27 (author note "VERIFIED"), NEEDS_HUMAN.md H5; no tool output | UNSUPPORTED (note only) | M5 |
| 76 | "Measures every app for 2 seconds … drifting (> 15 MB/s) or busy (> 50% CPU)" | HOW §2 | Sources/RAMKit/Relief/ReliefEngine.swift:70-71 (3 samples, 1 s apart); Measurement.swift:36,38 | SUPPORTED | — |
| 77 | "Writes `(6 << 16) \| 4` … `(6 << 16) \| 1` … sets its simulated mode before it validates the value" | HOW §2 | Trigger.swift:3-31; kern_memorystatus_notify.c: `memorystatus_manual_testing_on = TRUE` before the EINVAL checks | SUPPORTED | — |
| 78 | "Holds it for 10 seconds (Firefox checks every 10 s; Chrome re-notifies every 5 s)" | HOW §2 | xpcom/base/AvailableMemoryWatcherMac.cpp browser.lowMemoryPollingIntervalMS 10000; Chromium components/memory_pressure/memory_pressure_voter.h kCriticalPressureCooldown 5 s | SUPPORTED | — |
| 79 | "Measures every app again 5 seconds later … phys_footprint … the way the Force Quit dialog groups processes" | HOW §2 | settleMs 5_000 (Sources/RAMCLI/main.swift:216, AppModel); Sources/RAMKit/Process/AppGrouper.swift (responsible pid) | SUPPORTED | — |
| 80 | "Firefox (release builds): Nothing, until you change one pref … 0 outside Nightly … one line in user.js, undoable" | HOW §2 | firefox.js; FirefoxLevers.swift:61-86 | SUPPORTED | — |
| 81 | "The kernel: Purges volatile purgeable memory. Clean, idle background daemons may also exit" | HOW §2, SEC, README | kern_memorystatus_notify.c: request 6 purges; memstat_kill_idle_process up to 100 per notification; demo receipts goneApps 73 / newApps 71 | IMPRECISE (they are killed) | L17 |
| 82 | "Any app's malloc heap: Nothing extra on Apple silicon (xzone malloc … ignores the signal)" | HOW §2 | libmalloc src/malloc.c: the handler calls pressure_relief on every zone; that xzone's hook is a no-op rests on docs/research/xnu.md §4 only (xzone source not located) | IMPRECISE (unverified) | cite the libmalloc file:line or soften |
| 83 | "An orphan is reparented to launchd (ppid 1) but still points at whoever launched it" | HOW §3 | cdarwinmem.c:276-294 (responsibility_get_pid_responsible_for_pid); AgentClassifier.swift:248-271 | SUPPORTED | — |
| 84 | "lists idle orphans like 'orphaned http.server :8765 … idle 3h 52m'" | HOW §3 | Tests/RAMKitTests/AgentClassifierTests.swift:38, Sources/RAMApp/SampleData.swift:207 (a fixture, presented as an example) | SUPPORTED (example) | — |
| 85 | "Quit sends SIGTERM through an audit token, so a reused pid is never hit" | HOW §3, SEC | cdarwinmem.c:312-320 proc_signal_with_audittoken (pid + idversion); SafeKill.swift:49-63 | SUPPORTED | — |
| 86 | "`CLAUDE_CODE_HOST_SESSION_ID` … Only that one variable is read from the process environment" | HOW §3 | ProcessSample.swift:185-187 (reads one name); callers AgentClassifier.swift:24, AppModel.swift:168 pass only that name | SUPPORTED | — |
| 87 | "On the author's Mac that was 24 sessions holding 13.95 GB" | HOW §3 | PROGRESS.md task 9 only; doctor.json agentCount 13 / agentBytes 17,663,213,880 (16.45 GiB) at 13:18 | UNSUPPORTED (PROGRESS only) | M4 |
| 88 | "It can grow to gigabytes (5.3 GB here after 3 days)" | HOW §3 | docs/research/apps.md (note: 5.36 GB); the results file says 7.15 GB at 3 d 23 h | IMPRECISE (two numbers) | M1 |
| 89 | "Most RAM cleaners are a button for `purge`" | HOW §4, README | docs/research/apps.md prior art (eclecticlight 2024-07-06) | SUPPORTED (cited) | — |
| 90 | "Autopilot only sends the memory-pressure signal, and only when you're close to the wall" | HOW §4 | AppModel.swift:536-541: autopilot downloads also run the levers you set to Always | IMPRECISE | M3 |
| 91 | "Units match Activity Monitor (16 GB of RAM reads '16.00 GB')" | HOW §5 | Sources/RAMKit/Util/Format.swift:5-14 (1024-based, labelled GB/MB) | SUPPORTED | — |
| 92 | "`ram bench` alternates … in a seeded random order … Welch's t-test" | HOW §5 | Bench.swift:184-185, 235; logs order c,r,r,c,r,c,r,c,r,c; Stats.swift:92-105 | SUPPORTED | — |
| 93 | "The README numbers are generated from those JSON files, never typed by hand" | HOW §5 | true for the BENCH block; the findings list at the top of README is typed from the evidence files | IMPRECISE | L12 |
| 94 | "Four XPC calls … No file paths, no shell, no arbitrary sysctl" | SEC | HelperProtocol.swift; RAMHelper/main.swift (only Trigger.write and proc_clear_vmpressure) | SUPPORTED | — |
| 95 | Rate limits: hold 1–30 s; one at a time; 20 s between; 30 per hour; restore once per 5 s; resume 20 per 10 s; own processes unless root | SEC | HelperPolicy.swift:28-30, 34-45; RAMHelper/main.swift:72, 93-105; Sources/RAMKit/Wall/Resume.swift:28-36 | SUPPORTED | — |
| 96 | "Caller check: … only accepts callers signed by the same team … fails closed" | SEC | RAMHelper/main.swift:161-192 | SUPPORTED | — |
| 97 | "a hold always runs to its end (even if the client goes away)" | SEC | RAMHelper/main.swift:56-63 (detached Task, not tied to the connection) | SUPPORTED | — |
| 98 | "every catchable terminating signal (SIGTERM, SIGINT, …) runs a signal-safe guard" | SEC | cdarwinmem.c:335-397 | SUPPORTED | — |
| 99 | "per-process marker in /var/run … launchd relaunches it after any unsuccessful exit and at boot" | SEC | Sources/RAMKit/Relief/HoldMarkers.swift; RAMHelper/main.swift:174-179; HelperInstaller.swift:42-46 | SUPPORTED | — |
| 100 | "every call is logged with the caller's pid" | SEC | RAMHelper/main.swift:50,53,79,101,108,111; `status()` (117-127) logs nothing | IMPRECISE | L6 |
| 101 | "it exits after 60 s idle" | SEC | RAMHelper/main.swift:195 | SUPPORTED | — |
| 102 | "It copies `ram-helper` from next to the `ram` you ran" | SEC | HelperInstaller.swift:57-75 | SUPPORTED | — |
| 103 | "Under `sudo`, files written on your behalf … with your own uid … seteuid" | SEC | Sources/RAMKit/Relief/Receipt.swift:151-156 (RealUser); RAMCLI/main.swift:252 | SUPPORTED | — |
| 104 | "Only your own processes … never /System, /usr/libexec, /usr/sbin, never a protected list" | SEC | SafeKill.swift:31-46; AppGrouper.swift:84-87 | SUPPORTED | — |
| 105 | "and in the app never the frontmost app" | SEC | SafeKill.check takes `frontmostPid` but no caller passes it (grep: none); LiveLeverActions.terminate (Levers.swift:68) calls SafeKill.terminate without it | WRONG (not implemented) | H3 |
| 106 | "The CLI quits only a pid you type, or the processes a lever you named picks (`--levers leftovers,archived`), which it lists first and asks about" | SEC | RAMCLI/main.swift:183-213, 265-271 | SUPPORTED | L4 (firefox-gpu) |
| 107 | "Identity is checked by start time and signalled through an audit token" | SEC | SafeKill.swift:44, 52-57 | SUPPORTED | — |
| 108 | "SIGTERM first; SIGKILL only on a second, explicit click" | SEC | no `escalate: true` anywhere in Sources; the app has no SIGKILL path; the only SIGKILL is `ram quit <pid> --force` (RAMCLI/main.swift:268) | WRONG (no such click) | H3 |
| 109 | "appends one marked line (`browser.lowMemoryResponseMask = 3`). Undo removes exactly that line" | SEC | FirefoxLevers.swift:61-86: a marker comment plus the `user_pref` line (two lines); undo removes both | IMPRECISE | L7 |
| 110 | "Receipts stay in ~/Library/Application Support/DownloadMoreRAM/ … Share cards never include session names, folders or paths" | SEC | Receipt.save; Sources/RAMApp/ShareCard.swift:6-7,17; docs/share-card.png inspected; public JSON files carry no paths or titles | SUPPORTED | — |
| 111 | Method paragraph (relief/control arms, seeded order, cooldown, phys_footprint, busy exclusion, Welch) | BENCH | Bench.swift; Measurement.swift | SUPPORTED | — |
| 112 | real / synthetic / perf tables | BENCH | recomputed from arms (#43) | SUPPORTED | — |
| 113 | "Best relief arm (trial 5): +1.54 GB net; Claude Code +1.56 GB …" (and perf "trial 3 … Claude Code +539.9 MB") | BENCH, README | real.json arms[8].topApps[0]: id 77197, 10,067,155,704 → 8,395,643,448, exitedMembers 1, newMembers 1 (the agent session that was running Blender: a child process exiting counts as "returned"); the same session supplies the perf best arm (exitedMembers 1); without trial 5 the real relief mean is +204 MB | MISLEADING (undisclosed) | M6 |
| 114 | perf section | BENCH | perf.json; the first perf attempt at 13:21 aborted at trial 3 ("wait 1s between downloads", bench/logs/bench-synthetic-perf.log) and was redone at 13:48, unmentioned | IMPRECISE (disclosure) | L15 |
| 115 | SVG progress frames and receipt lines | SVG | all 33 frames come from the 13:10 recording; receipt lines match; "Claude +38" is a 70-char truncation of "+384 KB" (make-demo-svg.py:64) | IMPRECISE (cosmetic) | L2 |
| 116 | "921.2 MB back", two lever rows, "Apple M5 · 16 GB · macOS 26.5.2 swap 13.12 GB → 13.43 GB wall 37% → 36%" | CARD | receipt fields (#7) | SUPPORTED | — |
| 117 | "19 apps gave back 16.5 MB on the signal · others grew 22.1 MB · in 24s" | CLIP (11 s) | Sources/RAMApp/DownloadSheet.swift:208-255 (rows merged by name): 19 positive rows; grossFreedBytes 17,268,640 = 16.47 MiB; grew 22.09 MiB | SUPPORTED | — |
| 118 | "not counted: Claude Code (busy, grew 806.5 MB) · 71 started and 73 quit"; "compressed 3.94 GB → 3.65 GB" | CLIP | excludedBusy; newApps 71, goneApps 73; compressorOccupiedBytes 4,234,788,864 → 3,913,957,376 | SUPPORTED | — |
| 119 | Menu-bar "37%", "Where your RAM is 37.97 GB · All 149", progress "−22.3 MB · 3.8 MB/s · 2s left" | CLIP (0.2 s, 5 s) | wallBefore 36.8 → "37%"; 148 counted apps + 1 busy = 149; progress values are recording frames (the CLI clamps negatives to 0, the clip shows them signed) | SUPPORTED | — |
| 120 | End card "free · native" | CLIP | LICENSE (MIT); Swift/AppKit sources | SUPPORTED | — |
| 121 | docs/demo-source.json sha256 | docs | shasum of the 13:10 recording matches; docs/clip/download.json carries the same hash | SUPPORTED | — |
| 122 | The hero numbers use the larger of two multi-lever runs (921.2 MB at 13:10 vs 570.9 MB at 14:08) | README, CARD, CLIP | bench/results/2026-10-20T14-08-demo-recording.json, bench/logs/demo-download-final.log; not mentioned anywhere public | IMPRECISE (disclosure) | L14 |
| 123 | HELP text (commands, flags, "Every read command takes --json") | HELP | RAMCLI/main.swift cases 105-392; `--json` seen for status/apps/agents/download/doctor/receipt (not checked for every read command) | SUPPORTED | — |

Counts: SUPPORTED 91 · IMPRECISE 18 · OVERSTATED 3 · MISLEADING 2 · UNSUPPORTED 6 · WRONG 3 (123 claims).

## High findings (fix before launch)

**H1. The "paused six apps / 6 cores / 2 hours" story has no tool evidence and the system log contradicts its
shape** (README bullet 4; X3; Reddit title; HOW_IT_WORKS §1 "'Paused' is not as paused as it sounds";
rows 18, 57, 63, 72, 73). The only source is PROGRESS.md:31-32, a note committed at 10:03. The cited
`top` and `ram doctor` output from 07:00 was never saved. loginwindow's own log for 2026-10-20 names Firefox as
paused at 03:33–03:34 (panel 03:23–03:36), ChatGPT at 03:52–03:59 (panel 03:40–03:59), and no app at all in the
04:49 episode (panel open 04:49:18–10:28:29); Discord, Opera GX, Claude and Raycast never appear.
bench/evidence/2026-10-20T13-18-doctor.json events[3-5] say the same ([Firefox], [ChatGPT], []). The three
surfaces also disagree with each other (six apps in README and Reddit, four in X3). Fix accepted:
(a) rewrite the bullet to what the files show, e.g. "**The panel came up three times in one night** (3:23,
3:40 and 4:49 AM on Oct 20); the kernel paused Firefox, then ChatGPT; the last panel stayed up until 10:28
([evidence](bench/evidence/2026-10-20T13-18-doctor.json))"; X3 and the Reddit title likewise (Reddit: "My 16 GB
Mac hit 'out of application memory' six times in a week. I read the kernel source and built a fix."), and
save the loginwindow capture (`log show --last 7d --style compact --predicate '<WallEventLog.predicate>'`)
to bench/evidence; (b) the helper-burn sentence may return only with a saved capture of the 07:00 output
(bench/evidence/2026-10-20T07-00-paused-helpers.txt, from scrollback or the session transcript) linked next
to it; otherwise drop "six apps", "over 2 hours", "about 6 CPU cores", "about 4 cores", "1 core each" and
"load average 10.3" everywhere, or mark them "from my notes at the time, not captured".

**H2. "A fresh 1 GB allocation" is wrong** (README honest-numbers paragraph; row 42). The perf workload was
437 MiB (bench/results/2026-10-20T13-48-19-perf.json notes[0], arms[].workload.sizeMB; BENCHMARKS.md says so on
the same page). Fix accepted: "A fresh 437 MB allocation (the harness sizes it to a quarter of what macOS can
still hand out) was not measurably faster after the signal (0.12 s either way, p = 0.50)".

**H3. Two SECURITY.md guarantees are not in the code** (rows 105, 108): "in the app never the frontmost app"
(SafeKill.check has a `frontmostPid` parameter, but no caller anywhere passes it) and "SIGTERM first; SIGKILL
only on a second, explicit click" (no `escalate: true` exists; the app has no SIGKILL path; the only SIGKILL is
`ram quit <pid> --force`). Practical exposure is small (the app's quit targets are orphaned servers and the
head processes of archived CLI sessions), but the sentences describe behaviour that does not exist. Fix
accepted: either implement it (AppModel passes `NSWorkspace.shared.frontmostApplication?.processIdentifier`
through LeverActions into `SafeKill.terminate(_:escalate:frontmostPid:)`, with a test), or reword:
"The app only ever sends SIGTERM; the only SIGKILL is `ram quit <pid> --force`, which you type", and delete the
frontmost clause.

## Medium findings

**M1. Firefox GPU restart: the 'before' half is hand-written and the number carries false precision**
(README bullet 3; X6; HOW_IT_WORKS §3; rows 16, 17, 88). bench/results/2026-10-20T12-42-firefox-gpu-restart.json
was typed by the author (prose strings, committed 12:44); bench/logs/firefox-gpu-restart.log contains only
the 5/15/30/60 s AFTER samples; "6.02 GB" is the Firefox group (19.71 → 13.25 GB), not the GPU process
(7.15 → 1.68 GB), and the group swung 13.14 → 13.96 → 13.25 GB within that minute. HOW_IT_WORKS cites a
different figure (5.3 GB after 3 days, from a research note). Fix accepted: "One restart and Firefox's
footprint fell by about 6 GB (19.7 → 13.2 GB; the GPU process 7.15 → 1.68 GB)"; add a `provenance` field to
the JSON ("before: copied by hand from `ram status --json` at 12:42; after: bench/logs/firefox-gpu-restart.log")
or save the before output if it exists; align HOW_IT_WORKS §3 to the same run (7.15 GB, 3 d 23 h).

**M2. "macOS writes a report for every memory crisis"** (README; row 12). JetsamEvent reports exist only for
the Oct 16/17 kill storms; the three Oct 20 wall hits left none. Fix accepted: "macOS writes a report when it
has to kill processes to cope (JetsamEvent); three of this week's six wall hits left none, so `ram doctor`
reads the reports and the log".

**M3. Autopilot's promise is not earned by any file** (README table; HOW_IT_WORKS §4; rows 35, 90). The code
sends the signal plus any lever set to Always at ≥ 85 %, ETA < 5 min, imminent, or 20 s of critical pressure
(AutopilotPolicy.swift:14-19, AppModel.swift:536-555, 644-651); no autopilot run is recorded, and the
README's own benchmark says the signal alone is not significant on this Mac. "Downloads RAM before macOS
starts pausing apps" reads as a guarantee. Fix accepted: "When the wall is near (85 %, or under 5 minutes away
at the current rate) it sends the signal plus any lever you set to Always, and tells you who is growing; on an
Electron-heavy Mac expect the signal part to be small (see the honest numbers)". HOW_IT_WORKS §4: "Autopilot
only sends the memory-pressure signal and the levers you set to Always, …".

**M4. "24 sessions holding 13.95 GB"** (HOW_IT_WORKS §3; row 87) exists only in PROGRESS.md (task 9); the saved
evidence has 13 sessions / 16.45 GB at 13:18. Fix accepted: use the evidence-file numbers with the link, or
save the earlier `ram agents --json` capture (redacted like the existing one).

**M5. "Raycast's web-networking helper was still frozen hours after the panel closed"** (HOW_IT_WORKS §1;
row 75) rests on docs/research/xnu.md:27 and NEEDS_HUMAN.md H5, both author notes. Fix accepted: save a capture
(`ram --json` or the 12:42 `ram resume` output showing the PA_SUSP helper) to bench/evidence and link it, or
write "(from my notes: …)", or drop the sentence.

**M6. The best relief arms are a child process exiting, not disclosed** (BENCHMARKS.md "Best relief arm"
lines; README/X8 "+478 MB"; rows 43, 58, 113). In real.json the +1.54 GB arm is one agent session (id 77197,
the one running Blender) with exitedMembers 1 / newMembers 1; the method counts an exited child as memory
returned (HOW_IT_WORKS §5 says so, BENCHMARKS.md does not), and the same session supplies the perf best arm.
Without trial 5 the real relief mean is +204 MB. Fix accepted: `ram bench report` appends "(a child process
exited)" to any best-arm app with exitedMembers > 0, and the README honest-numbers paragraph adds one sentence:
"The real-bench mean is dominated by one trial in which an agent session's child process exited during the
window; that counts as returned memory (HOW_IT_WORKS §5)."

## Low findings (fix wording)

- L1 LAUNCH.md "Clip (18 s, 1:1" → "4:5 (1080×1350)" (docs/clip/download.json).
- L2 docs/demo.svg "Claude +38" → widen the detail line or end it with "…" (make-demo-svg.py:64 cuts at 70 chars).
- L3 X1 "6 times this week" → "6 times in a week" (events span Fri Oct 16 and Oct 19/20).
- L4 README "Anything that ends a process needs your yes" / SECURITY: say that naming `--levers firefox-gpu` is the yes (no prompt, RAMCLI/main.swift:183), and that levers set to Always run inside autopilot downloads.
- L6 SECURITY "every call is logged" → "every call that changes anything is logged" (`status()` is not).
- L7 SECURITY "appends one marked line" → "two lines (a marker comment and the pref); undo removes both".
- L8 README FAQ / HOW §3 "after 30 s of uptime" → "after 30 s and ten painted frames" (Firefox stable.min-uptime-ms 30000 + stable.frame-threshold 10), or check both in FirefoxLevers.restartGPU.
- L9 README / HOW §2 "Chrome, Opera, Brave, Edge" → "Chrome (and Chromium browsers that keep its default)"; only Chromium was checked.
- L10 HOW §1 "suspends only the app's main process" → "suspends the process that registered (usually the app's main process), one every 5 s".
- L11 HOW §1 swapfile11: say "must have failed" and note the 11-files / 93 GB state is from notes; the compressor path was at ~36 %, so the inference stands.
- L12 HOW §5 "The README numbers are generated" → "The BENCH block is generated; the findings above it are typed from the evidence files".
- L13 README "macOS 14 or later" → "should run on macOS 14+ (Package.swift); tested only on 26.5".
- L14 README/CARD/CLIP: mention that a second multi-lever run the same day returned 570.9 MB (bench/logs/demo-download-final.log), or link both recordings.
- L15 BENCHMARKS.md: one line that the 13:21 perf attempt aborted at trial 3 (helper spacing) and was redone at 13:48 (bench/logs/bench-synthetic-perf.log).
- L17 HOW §2 / SECURITY / README "idle daemons may also exit" → "are killed by the kernel (idle-exit, up to 100 per notification) and relaunched by launchd on demand" (the demo runs saw 73 quit / 71 start).
- L18 README / X2 "every 5 seconds until you click Resume" → "one registered process every 5 seconds while swap stays full; Resume un-pauses one, the loop keeps going".
- Row 82: cite the libmalloc file:line for xzone's pressure_relief, or soften to "the default allocator already returns freed pages".
- Row 5 (optional): the demo command shown is reconstructed from the receipt's levers; the real run also had `--record`.

Skeptic's notes that are not findings: the demo is a real recording (hash-matched) and the clip's numbers
all reproduce from it; the 6,645 / 491 / 45.5 GB / 35.7 GB crisis figures reproduce exactly from the raw
JetsamEvent files; every BENCH number reproduces from `arms[]`; headline == sum of levers holds in every
receipt; no network code exists; the four-call helper, its rate limits and its restore paths are exactly as
documented; public JSON files contain no session titles or home paths.

Status: OPEN (3 high, 6 medium)
Reviewer: independent claims review, 2026-10-20 14:50 EDT
