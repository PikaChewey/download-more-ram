# How Download More RAM works

You can't add RAM with software. What you *can* do is get apps to give back memory they're
holding but don't need, find what your tools forgot to close, and see the wall before you hit
it. Everything below is backed by the macOS kernel source (XNU), Chromium, Firefox and WebKit
source, and measurements on a real 16 GB MacBook. Sources and line numbers are in
[research/xnu.md](research/xnu.md) and [research/apps.md](research/apps.md).

## 1. What "out of application memory" really is

When RAM fills up, macOS compresses idle memory, then moves compressed memory to swap files on
disk (`/System/Volumes/VM/swapfile0`, `1`, ...). It adds 1 GB swapfiles as needed, up to 100.

The dialog appears when the kernel's `no_paging_space_action()` runs. That happens when one of
these is true:

- **Swap is nearly full and macOS failed to create another swapfile.** Free swap is under
  32 MB and the most recent swapfile creation failed (or 100 files already exist).
- **The compressor is nearly full.** It has reached 98% of its segment or page limits. Segments
  count compressed memory in RAM *and* in swap. On a 16 GB Mac that ceiling is about 49 GB of
  compressed data.

The kernel then *suspends* (pauses) the largest app that registered to be paused, and asks
loginwindow to show the Force Quit panel. Every 5 seconds it pauses the next one. That is the
"(paused)" next to app names. If one process that didn't register holds more than half of all
compressed memory, it is killed outright instead, with no dialog.

**Free disk space is usually not the cause.** On the author's Mac the dialog appeared with 93 GB
free. Creating `swapfile11` failed once (a transient error), and that alone was enough.

`ram` shows how close you are to each limit ("38% to the wall"), predicts when you'll hit it at
the current rate, and warns the moment swap is full and no new swapfile has appeared for 15 s.
That is the exact state that precedes the panel.

**"Paused" is not as paused as it sounds.** The kernel suspends only the app's main process. On the
author's Mac (2026-10-20, 07:00, on battery) the paused ChatGPT app's Codex helpers kept running
at about 4 cores, and the Discord and Opera renderers at about 1 core each, for over two hours
until someone clicked Resume (load average 10.3 on a 10-core machine). `ram doctor` reports this
("ChatGPT is paused, but its helpers are using 4.0 cores").

It can also tell you **which app macOS will pause first**. Each process's pause registration is
visible to any user (the `PROC_FLAG_PC_SUSP` flag), and the kernel picks the biggest. And it
finds processes macOS paused **and never resumed**. On the author's Mac, Raycast's web-networking
helper was still frozen hours after the panel closed.

## 2. "Downloading RAM": macOS's own memory-pressure signal

macOS tells apps when memory is tight: *warning* means "relax your caches", *critical* means
"drop all caches". Apps subscribe to this signal (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`). macOS
normally sends it only *after* things are already bad.

A root-only kernel switch, `kern.memorypressure_manual_trigger`, sends it on demand. Apple's own
`memory_pressure -S` tool uses it. A download does this:

1. Measures every app for 2 seconds. Apps whose memory is drifting (> 15 MB/s) or that are busy
   (> 50% CPU) are flagged and won't be counted.
2. Writes `(6 << 16) | 4`: notify every subscribed process at *critical* and purge volatile
   memory.
3. Holds it for 10 seconds (Firefox checks every 10 s; Chrome re-notifies every 5 s).
4. Writes `(6 << 16) | 1` to put the kernel back to normal. This always happens: on success,
   on error, on Ctrl-C, and even after a crash, because the helper restores it when it next
   starts. The kernel sets its simulated mode *before* it validates the value, so even a
   rejected write gets a reset.
5. Measures every app again 5 seconds later. The headline is the net drop in phys_footprint,
   the same number Activity Monitor's Memory column shows, summed per app the way the Force
   Quit dialog groups processes.

### Who actually responds (verified in source)

| App type | What happens on the signal |
|---|---|
| Safari, Mail, any app using WKWebView | Drops page, font and style caches; on critical also the back/forward cache, JIT code, and a synchronous garbage collection. Cached web processes exit. |
| Google Chrome, Opera, other Chromium browsers | One background tab is discarded per critical notification (it reloads when you click it). The GPU process drops its caches. |
| Electron apps (Claude, Discord, Slack, VS Code, Codex) | Only the GPU and network processes drop caches. **The page processes never receive the signal on macOS** (Chromium forwards it to renderers only on Android). |
| Firefox (release builds) | **Nothing**, until you change one pref. Firefox has a low-memory tab unloader, but `browser.lowMemoryResponseMask` is 0 outside Nightly. `ram` can turn it on for you (one line in your profile's user.js, undoable). |
| Node.js, Bun (Claude Code, MCP servers, dev servers) | Nothing. They don't listen. |
| The kernel | Purges volatile purgeable memory. Clean, idle background daemons may also exit (launchd restarts them when needed). |
| Any app's malloc heap | Nothing extra on Apple silicon. The default allocator (xzone malloc) already returns freed pages and ignores the signal. |

So the amount you get back depends entirely on what you run. A Mac full of Safari tabs and
Chrome gets a lot. A Mac full of Electron apps and agents gets less from the signal, and more
from the next two levers. Your receipt shows exactly which apps gave memory back.

## 3. The levers that move big numbers

- **Leftovers.** AI agents start MCP servers, dev servers and headless browsers, and don't
  always stop them. An orphan is reparented to launchd (ppid 1) but still points at whoever
  launched it (its *responsible* process). A launchd job, by contrast, is responsible for itself.
  So `ram agents` lists idle orphans like "orphaned http.server :8765 from a Claude Code session
  · idle 3h 52m". Quit sends SIGTERM through an audit token, so a reused pid is never hit.
- **Agent sessions.** Memory is attributed to each Claude Code / Codex / Cursor / Gemini session
  along with everything it started, labelled by its folder, with its last activity taken from
  the session transcript. On the author's Mac that was 24 sessions holding 13.95 GB.
- **Firefox's GPU process.** It can grow to gigabytes (5.3 GB here after 3 days). Firefox is
  built to relaunch it. A restart after 30 s of uptime doesn't count toward its crash limit, and
  WebGL and canvas content resets.

## 4. What it refuses to do (and why other "RAM cleaners" are placebo)

- **No `purge`.** It only flushes the file cache, which macOS reclaims instantly anyway. It
  can't touch app memory, compressed memory or swap, and it makes your next file reads slower.
  Most RAM cleaners are a button for `purge`.
- **No balloon allocation.** Allocating memory to "push out" other memory just forces
  compression and swap, and does it at the moment you can least afford it.
- **"Free RAM" is never the success metric.** Free RAM is wasted RAM. The receipt reports what
  apps gave back.
- **Nothing is killed or paused automatically.** Quitting needs a click. Autopilot only sends
  the memory-pressure signal, and only when you're close to the wall.
- **No network access, no telemetry.**

## 5. Measuring honestly

- Units match Activity Monitor (16 GB of RAM reads "16.00 GB").
- Busy apps, and apps that start or quit mid-download, are listed but not counted. Firefox
  closing one of its own tab processes does count, because the app is still running.
- `ram bench` alternates real downloads with *control* runs (identical timing, no signal) in a
  seeded random order. It reports both arms with Welch's t-test, so natural drift can't pass
  for an effect. The README numbers are generated from those JSON files, never typed by hand.
