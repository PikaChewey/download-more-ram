# How apps respond to macOS memory pressure (research, 2026-10-20)

Sources: current `main` of Chromium, Firefox (mozilla-firefox/firefox, searchfox), WebKit, apple-oss-distributions
xnu + system_cmds, plus read-only checks on the target Mac (MacBook M5 16 GB, macOS 26.5.2, Firefox 158,
Claude Code 2.1.303). Shipping versions can lag `main`. Quotes under 15 words.

## Kernel trigger (summary; details in xnu.md)

- `kern.memorypressure_manual_trigger`: `CTLTYPE_INT | CTLFLAG_WR | CTLFLAG_LOCKED | CTLFLAG_MASKED`, root-only
  ([kern_memorystatus_notify.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c)).
  Value = `(request << 16) | level`; `memory_pressure -S` uses request 6 (`TEST_LOW_MEMORY_PURGEABLE_TRIGGER_ALL`)
  ([memory_pressure.c](https://github.com/apple-oss-distributions/system_cmds/blob/main/memory_pressure/memory_pressure.c)).
- Request 6: sets manual testing mode, overrides the reported pressure level until NORMAL is written, purges
  purgeable VM objects (strength `memorystatus_purge_on_critical` = 8 here), then notifies every registered
  process. Manual mode skips the normal 25 s inter-notification resting periods.
- Apple's level semantics ([memorystatus_notify.md](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md)):
  Warning = relax caching; Critical = drop all caches; LOW_SWAP fires when the compressor is exhausted (root only).

## Chromium / Electron (the important finding)

- Detection: browser process, `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` (WARN|CRITICAL|NORMAL), reads
  `kern.memorystatus_vm_pressure_level`; WARN→moderate, CRITICAL→critical
  ([system_memory_pressure_evaluator_mac.cc](https://source.chromium.org/chromium/chromium/src/+/main:components/memory_pressure/system_memory_pressure_evaluator_mac.cc)).
  Re-notifies every 5 s while the vote persists ([memory_pressure_voter.h](https://source.chromium.org/chromium/chromium/src/+/main:components/memory_pressure/memory_pressure_voter.h)).
- **Renderers on macOS never receive OS memory pressure**: `RenderProcessHostImpl::OnMemoryPressure` forwards only
  on Android/CastOS ([render_process_host_impl.cc](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/renderer_host/render_process_host_impl.cc));
  children only get it via the browser, which forwards (non-Android) to the GPU process and network service only
  ([browser_child_process_host_impl.cc](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/browser_child_process_host_impl.cc)).
  So V8 GC, Blink MemoryCache, Skia/font caches in renderers do NOT fire from our trigger.
- What does respond on macOS:
  - Google Chrome: `UrgentPageDiscardingPolicy` (enabled by default on desktop except Linux) discards one eligible
    tab per critical notification ([urgent_page_discarding_policy.cc](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc)).
  - GPU process: critical clears Skia surface cache + `freeGpuResources()`; moderate scratch only
    ([shared_context_state.cc](https://source.chromium.org/chromium/chromium/src/+/main:gpu/command_buffer/service/shared_context_state.cc)).
  - Network service / browser caches (SSL session cache, in-memory HTTP cache, blob storage) via `kStatefulMemoryPressure`.
- Electron: inherits the content-layer monitor (GPU + network purge) but has no tab discarding and exposes no
  memory-pressure event to apps ([power-monitor.md](https://github.com/electron/electron/blob/main/docs/api/power-monitor.md)).
- Magnitude: no published macOS measurement (measure it ourselves).

## Firefox on macOS

- Watcher ([AvailableMemoryWatcherMac.cpp](https://searchfox.org/firefox-main/source/xpcom/base/AvailableMemoryWatcherMac.cpp)):
  responds at critical (warn if `browser.lowMemoryResponseOnWarn`), polls every 10 s while critical; response =
  unload one tab (LRU, not playing media) else fire internal memory-pressure flush.
- **Release builds do nothing**: `browser.lowMemoryResponseMask` is 3 on Nightly, 0 otherwise (0 = telemetry only)
  ([firefox.js](https://searchfox.org/firefox-main/source/browser/app/profile/firefox.js)). VERIFIED on the target:
  Firefox 158 ships `pref("browser.lowMemoryResponseMask", 0)` and neither profile overrides it. Setting 3 takes
  effect immediately via about:config (or at next start via user.js).
- Tabs must be inactive >= 10 min (`browser.tabs.min_inactive_duration_before_unload` = 600000).
- GPU process: default on macOS since Firefox 146; hosts WebRender, WebGL, canvas, WebGPU. Killing it is
  designed-for: Firefox relaunches (`about:support` "Terminate GPU Process" calls `terminateGPUProcess()`);
  `layers.gpu-process.max_restarts` = 6 but only crashes within 30 s uptime / < 10 frames count as unstable
  ([GPUProcessManager.cpp](https://searchfox.org/firefox-main/source/gfx/ipc/GPUProcessManager.cpp)). Side effect:
  WebGL contexts/canvases reset, windows repaint. Observed here: "Firefox GPU Helper" 5.36 GB footprint.

## WebKit / Safari / WKWebView

[MemoryPressureHandlerCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/cocoa/MemoryPressureHandlerCocoa.mm):
WARN → non-critical release (font/glyph caches, dead resources, style sheet cache); CRITICAL → also back/forward
cache, live memory cache, JIT code, synchronous GC, `releaseFastMallocFreeMemory()`, IOSurface pool
([MemoryRelease.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/MemoryRelease.cpp)). Cached/
prewarmed WebContent processes exit. Raycast's WebKit was seen responding in this Mac's log at 03:40.

## Node.js / Bun / Claude Code

- Node and Bun do not handle memory pressure. Never send SIGUSR1 (opens Node's inspector: local code execution).
- Claude Code 2.1.303 here is a Bun-compiled Mach-O; idle sessions measured 255–418 MB each, plus their own MCP
  servers (14 `rea mcp` Node processes here). Getting that memory back means quitting orphans/idle sessions.

## Known memory problems (users report)

Claude Code [#4953](https://github.com/anthropics/claude-code/issues/4953), [#11315](https://github.com/anthropics/claude-code/issues/11315),
[#18859](https://github.com/anthropics/claude-code/issues/18859); orphaned MCP servers [#1935](https://github.com/anthropics/claude-code/issues/1935)
(open since 2025-06); Claude Desktop [#56577](https://github.com/anthropics/claude-code/issues/56577) (73.6 GB on a 16 GB MBP);
Codex [#17832](https://github.com/openai/codex/issues/17832) (213 orphaned Playwright MCP pairs, 13.6 GB);
Cursor forum (98 GB with 6 background agents on a 16 GB Mac); Firefox GPU bugs 1971159, 2052035.

## Prior art

- Memory Clean 3, CleanMyMac "Free Up", Nektony Memory Cleaner: `purge` / allocate-and-free. Howard Oakley:
  cleaners "mainly wrap the purge command" ([eclecticlight 2024-07-06](https://eclecticlight.co/2024/07/06/do-we-still-need-to-manage-memory-in-macos/)).
- **WonderBox** (jasonwong1991, 425 stars, created 2026-09-20): root helper writes the manual trigger (request 6,
  critical, hold, reset) then runs `/usr/sbin/purge`. **SwapWatch** (1 star): `memory_pressure -S` via sudoers +
  per-app phys_footprint + leak flags. ram-dl (171 stars): network block device as swap (Linux).
- Nobody found showing distance to the out-of-memory wall, attributing memory to agent sessions, or giving
  per-app receipts with exclusions.

## Claims we can make / must not make

Can: same kernel path as `sudo memory_pressure -S -l critical`; always reset; WebKit purges + GCs; Chrome discards
one background tab per critical notification; Electron GPU/network caches purge; Firefox release needs
`browser.lowMemoryResponseMask=3`; Firefox's GPU process is designed to be relaunched; Node/Bun ignore pressure.

Must not: "forces every app to release memory"; "makes Chrome/Electron GC"; "Firefox unloads tabs" without the pref
caveat; Chrome Memory Saver's 40%/10 GB; "adds RAM / defragments / clears inactive memory"; running `purge` under the
kernel-native banner; "safe to kill Firefox's GPU process at any time" (say: designed to be relaunched, WebGL/canvas
reset); stating Claude Code "is Bun" as Anthropic's claim; any number from this Mac as "typical".
