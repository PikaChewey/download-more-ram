# Download More RAM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app + `ram` CLI that triggers the kernel's own memory-pressure response on demand, measures per-app memory given back with phys_footprint, shows distance to the out-of-memory wall, and attributes memory to AI-agent sessions.

**Architecture:** SwiftPM package. `CDarwinMem` (C shims over libproc/sysctl/mach/responsibility SPI) feeds `RAMKit` (pure engine, no AppKit), which is used by `ram` (CLI), `RAMHelper` (root launchd daemon, 3 XPC calls) and `RAMApp` (AppKit status item + SwiftUI panel). `RAMFixtures` provides controlled test processes.

**Tech Stack:** Swift 6.3 (strict concurrency), SwiftPM, Swift Testing, AppKit/SwiftUI, XPC (NSXPCConnection), launchd, macOS 14+ arm64. No third-party dependencies.

**Spec:** `~/Documents/Goals/download-more-ram.md` (binding). Kernel facts: `docs/research/VERIFY.md`.

## Global Constraints

- Deployment target macOS 14, arm64, Swift 6 language mode, no third-party packages.
- Names: product "Download More RAM", CLI `ram`, bundle id `ca.bryanyao.DownloadMoreRAM`, helper label/Mach service `ca.bryanyao.DownloadMoreRAM.helper`.
- Headline metric = net phys_footprint drop of non-busy apps; never "free RAM went up"; never `purge`, never ballooning.
- Busy = |drift| > 15 MB/s or CPU > 50% during the 2 s pre-baseline.
- Relief: CRITICAL + notify-all + purge-all, hold default 10 s (1-30 s allowed), then NORMAL. Helper: >= 20 s between reliefs, <= 30/hour, one at a time.
- Wall thresholds: amber >= 70, red >= 85; autopilot fires at >= 85, ETA < 5 min, or critical > 20 s, max once per 2 min.
- Leak flag: window >= 30 min, Theil-Sen slope > 200 MB/h, growth > 500 MB, Spearman rho > 0.8.
- Safety: never signal other users' or system processes; protected names WindowServer, loginwindow, Finder, Dock, kernel_task, launchd, SystemUIServer, ControlCenter, the frontmost app; kill only on explicit click, SIGTERM via audit token, SIGKILL only on a second click.
- No network, no telemetry. Receipts in `~/Library/Application Support/DownloadMoreRAM/receipts/`.
- Every heavy job via `scripts/with-build-lock.sh`; integration/bench via `scripts/memory-gate.sh` (abort if memorystatus_level < 15, pressure 4, or swap free < 1.5 GB).
- Commits: no Claude attribution lines.

## Review Focus

1. Helper killed or crashing mid-hold: the kernel must not stay in simulated pressure; on restart the helper restores NORMAL (marker file) - owned by Task 7.
2. Processes exiting/spawning during a download (Firefox unloading a tab, an unrelated render finishing): app-level accounting counts exits inside surviving apps, excludes whole-app births/deaths and busy apps - owned by Task 6.
3. Machine already near the wall when a download, bench or test starts: relief must still run (it allocates nothing), bench/tests must refuse via memory-gate - owned by Tasks 6 and 12.
4. No helper and not root: every command and the app degrade to read-only with one clear line on how to enable downloads - owned by Tasks 5, 10, 11.
5. PID reuse between listing and quitting a process: the kill path must verify identity (start time + audit token) and refuse on mismatch - owned by Task 9.

---

### Task 1: Package, C shims, system sampler

**Files:**
- Create: `Package.swift`, `Sources/CDarwinMem/include/cdarwinmem.h`, `Sources/CDarwinMem/cdarwinmem.c`, `Sources/RAMKit/System/Sysctl.swift`, `Sources/RAMKit/System/SystemSample.swift`, `scripts/memory-gate.sh`, `PROGRESS.md`, `.gitignore`, `LICENSE` (MIT, 2026 Bryan Yao)
- Test: `Tests/RAMKitTests/SystemSampleTests.swift`

**Interfaces:**
- Produces: `struct SystemSample: Sendable, Codable { physicalBytes, pageSize, freeBytes, activeBytes, inactiveBytes, speculativeBytes, wiredBytes, purgeableBytes, fileBackedBytes, anonymousBytes, compressorOccupiedBytes, compressedUncompressedBytes: UInt64; swapTotal, swapUsed: UInt64; swapins, swapouts, pageins, compressions, decompressions: UInt64; pressureLevel: PressureLevel; availablePercent: Int; compressorPages, compressorPagesLimit, compressorSegments, compressorSegmentsLimit: UInt64; swapfileCount: Int; vmVolumeFreeBytes: UInt64; timestamp: Date }` with computed `appMemoryBytes` (anonymous - purgeable), `memoryUsedBytes` (app + wired + compressorOccupied), `cachedFilesBytes` (fileBacked + purgeable).
- Produces: `enum PressureLevel: Int, Codable { normal = 1, warn = 2, critical = 4 }`; `enum SystemSampler { static func read() throws -> SystemSample }`; `enum Sysctl { static func int(_:), uint64(_:), swapUsage() }`.

- [ ] **Step 1:** Write `SystemSampleTests`: `readsPlausibleValues` (`physicalBytes == sysctl hw.memsize`, `pageSize == 16384` on arm64, `pressureLevel` decodes, `0...100 ~= availablePercent`, `memoryUsedBytes <= physicalBytes`), `swapUsageMatchesSysctl` (within 64 MB of `vm.swapusage` used).
- [ ] **Step 2:** Run `scripts/with-build-lock.sh swift test --filter SystemSampleTests`; expect build failure (types missing).
- [ ] **Step 3:** Implement shims (`dm_vm_stats(struct dm_vm*)` over `host_statistics64(HOST_VM_INFO64)`, typed sysctl helpers) and `SystemSampler.read()`; swapfile count = files matching `vm.swapfileprefix` + digits; VM volume free via `statfs` on the prefix's directory.
- [ ] **Step 4:** Run the tests; expect PASS.
- [ ] **Step 5:** Commit `feat: package skeleton and system memory sampler`.

### Task 2: Process sampler

**Files:**
- Create: `Sources/RAMKit/Process/ProcessSample.swift`; extend the C shim with `dm_proc_rusage`, `dm_proc_bsdinfo`, `dm_proc_cwd`, `dm_proc_argv`, `dm_responsible_pid`, `dm_proc_coalition`
- Test: `Tests/RAMKitTests/ProcessSampleTests.swift`

**Interfaces:**
- Produces: `struct ProcessRecord: Sendable, Codable, Hashable { pid: Int32; ppid: Int32; uid: UInt32; name: String; path: String?; startTime: UInt64 /* abs µs since epoch */; footprint: UInt64; lifetimeMaxFootprint: UInt64; cpuTimeNs: UInt64; responsiblePid: Int32; coalitionId: UInt64? }` and `ProcessKey { pid, startTime }`.
- Produces: `struct ProcessSnapshot: Sendable, Codable { records: [ProcessRecord]; unreadableCount: Int; timestamp: Date; totalFootprint: UInt64; func record(_ key: ProcessKey) -> ProcessRecord? }`; `enum ProcessSampler { static func snapshot(includePaths: Bool = true) -> ProcessSnapshot; static func argv(pid:) -> [String]?; static func cwd(pid:) -> String? }`.

- [ ] **Step 1:** Tests: `containsSelf` (own pid with footprint > 0, uid == getuid()), `footprintTracksAllocation` (allocate and touch 128 MiB, re-snapshot, delta within 128 MiB +-15%), `countsUnreadable` (`unreadableCount >= 0`, records + unreadable == listed pids), `cwdAndArgvForSelf`.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement with `proc_listallpids`, `proc_pid_rusage(RUSAGE_INFO_V6)`, `proc_pidinfo(PROC_PIDTBSDINFO / PROC_PIDVNODEPATHINFO)`, `KERN_PROCARGS2`, `responsibility_get_pid_responsible_for_pid` via dlsym (missing -> responsiblePid = pid). EPERM records count as unreadable.
- [ ] **Step 4:** Run; PASS; also measure `snapshot()` time on the real machine (< 15 ms target, log it in PROGRESS.md).
- [ ] **Step 5:** Commit `feat: per-process footprint sampler`.

### Task 3: Grouping, formatting, stats

**Files:**
- Create: `Sources/RAMKit/Process/AppGrouper.swift`, `Sources/RAMKit/Util/Format.swift`, `Sources/RAMKit/Util/Stats.swift`
- Test: `Tests/RAMKitTests/AppGrouperTests.swift`, `FormatTests.swift`, `StatsTests.swift`

**Interfaces:**
- Produces: `struct AppGroup: Sendable, Codable, Identifiable { id: Int32 /* responsible pid */; name: String; bundlePath: String?; footprint: UInt64; processCount: Int; members: [ProcessRecord]; kind: AppKind }`, `enum AppKind { app, agentSession, system, other }`; `enum AppGrouper { static func group(_ s: ProcessSnapshot) -> [AppGroup] }` sorted by footprint desc; name from enclosing `.app` bundle `CFBundleName` (fall back to process name).
- Produces: `Format.bytes(_ b: Int64, signed: Bool = false) -> String` ("4.11 GB", "97.3 MB", "-1.20 GB" style, decimal 1000-based like Activity Monitor), `Format.bar(fraction: Double, width: Int) -> String`, `Format.duration(_ s: Double) -> String`.
- Produces: `Stats.theilSenSlope(_ pts: [(Double, Double)]) -> Double?`, `Stats.spearman(_ xs: [Double], _ ys: [Double]) -> Double?`, `Stats.meanSD(_ xs: [Double]) -> (Double, Double)`.

- [ ] **Step 1:** Tests: grouping of a synthetic snapshot (3 Firefox helpers + parent -> one "Firefox" group with summed footprint; Claude Code CLI with children -> one `agentSession` group; bundle name resolution from `/Applications/Firefox.app/Contents/MacOS/firefox`); `Format.bytes(4_110_000_000) == "4.11 GB"`, `Format.bytes(97_300_000) == "97.3 MB"`, `Format.bytes(-1_200_000_000, signed: true) == "-1.20 GB"`; Theil-Sen on y = 2x + noise with one outlier returns 2 +- 0.05; spearman of monotone data == 1.
- [ ] **Step 2:** Run; FAIL. **Step 3:** Implement. **Step 4:** Run; PASS.
- [ ] **Step 5:** Commit `feat: app grouping, formatting and robust stats`.

### Task 4: Trigger encoding and helper policy (pure logic)

**Files:**
- Create: `Sources/RAMKit/Relief/Trigger.swift`, `Sources/RAMKit/Helper/HelperPolicy.swift`, `Sources/RAMKit/Helper/HelperProtocol.swift`
- Test: `Tests/RAMKitTests/TriggerTests.swift`, `HelperPolicyTests.swift`

**Interfaces:**
- Produces: `enum TriggerRequest: Int32 { lowMemoryOne, lowMemoryAll, purgeableOne, purgeableAll, lowMemoryPurgeableOne, lowMemoryPurgeableAll }` and `enum Trigger { static func encode(_ r: TriggerRequest, _ l: PressureLevel) -> Int32; static let sysctlName = "kern.memorypressure_manual_trigger" }` - numeric values exactly as recorded in `docs/research/VERIFY.md` (from xnu `kern_memorystatus.h` / `sys/event.h`).
- Produces: `struct HelperPolicy { mutating func admit(level: PressureLevel, holdMs: Int, now: Date) -> Result<Void, HelperRefusal> }`, `enum HelperRefusal: Error { badLevel, badHold, busy, tooSoon(retryAfter: TimeInterval), hourlyCap }`; `@objc protocol RAMHelperXPC { func relieve(level: Int, holdMs: Int, reply: @escaping (String?) -> Void); func restore(reply: @escaping (String?) -> Void); func status(reply: @escaping (String) -> Void) }`; `HelperConstants.machService`.

- [ ] **Step 1:** Tests: encodings match VERIFY.md table; policy refuses `normal` as a relief level, holds 999 and 30001, a second relief while one runs, one 19 s after the last end (`tooSoon`), the 31st within an hour; admits a valid request.
- [ ] **Step 2-4:** FAIL -> implement -> PASS.
- [ ] **Step 5:** Commit `feat: kernel trigger encoding and helper admission policy`.

### Task 5: Relief backends

**Files:**
- Create: `Sources/RAMKit/Relief/ReliefBackend.swift` (protocol + `DirectSysctlBackend` + `HelperBackend` + `ReliefAvailability.detect()`)
- Test: `Tests/RAMKitTests/ReliefBackendTests.swift`

**Interfaces:**
- Consumes: `Trigger`, `RAMHelperXPC`.
- Produces: `protocol ReliefBackend: Sendable { var name: String { get }; func relieve(level: PressureLevel, holdMs: Int) async throws; func restore() async throws }`; `enum ReliefAvailability { case root, helper(version: String), unavailable(reason: String) }` with `static func detect() async -> ReliefAvailability` and `func backend() -> ReliefBackend?`.
- `DirectSysctlBackend.relieve` writes the encoded CRITICAL value, sleeps `holdMs`, and restores NORMAL in a `defer` that also runs on task cancellation; installs SIGINT/SIGTERM handlers that restore before exiting.

- [ ] **Step 1:** Tests: as non-root, `DirectSysctlBackend().relieve` throws `ReliefError.notPermitted` and performs no write; `detect()` returns `.unavailable` with a reason containing "ram helper install" when the helper is absent and euid != 0; `HelperBackend` against an unreachable Mach name throws `ReliefError.helperUnreachable` within 3 s.
- [ ] **Step 2-4:** FAIL -> implement -> PASS.
- [ ] **Step 5:** Commit `feat: relief backends with guaranteed restore`.

### Task 6: Relief engine and receipts

**Files:**
- Create: `Sources/RAMKit/Relief/ReliefEngine.swift`, `Sources/RAMKit/Relief/Receipt.swift`, `Sources/RAMKit/Relief/Measurement.swift`
- Test: `Tests/RAMKitTests/MeasurementTests.swift`, `ReceiptTests.swift`

**Interfaces:**
- Consumes: `ProcessSampler`, `SystemSampler`, `AppGrouper`, `ReliefBackend`.
- Produces: `struct AppDelta: Codable { name; before; after; delta: Int64; busy: Bool; exitedMembers: Int }`; `struct Receipt: Codable { id; startedAt; durationS; backend; holdMs; machine: MachineInfo; headlineBytes: Int64; grossFreedBytes: Int64; apps: [AppDelta]; excludedBusy: [AppDelta]; newApps: [String]; goneApps: [String]; systemBefore: SystemSample; systemAfter: SystemSample; wallBefore: Double; wallAfter: Double; func markdown() -> String; func save() throws -> URL }`.
- Produces: `struct MachineInfo: Codable { model: String /* hw.model */; chip: String /* machdep.cpu.brand_string */; memoryBytes: UInt64; osVersion: String; static func current() -> MachineInfo }`.
- Produces: `enum Measurement { static func busyGroups(baseline: [ProcessSnapshot]) -> Set<Int32>; static func deltas(before: ProcessSnapshot, after: ProcessSnapshot, busy: Set<Int32>) -> (apps: [AppDelta], excluded: [AppDelta], new: [String], gone: [String]) }`; `actor ReliefEngine { init(backend:, holdMs: Int = 10_000, settleMs: Int = 5_000); func run(progress: @Sendable (ReliefProgress) -> Void) async throws -> Receipt }`, `struct ReliefProgress { elapsed; total; reclaimedSoFar: Int64; rateBytesPerSec: Double; topApps: [AppDelta] }`.

- [ ] **Step 1:** Measurement tests with synthetic snapshots: a group whose footprint drifts 40 MB/s across the baseline is busy and excluded from the headline; a Firefox group losing one exited member (500 MB) counts +500 MB; a brand-new app is listed in `new` and not counted; a group that grew 100 MB subtracts 100 MB from the headline; headline equals sum of non-busy deltas; `grossFreed` equals sum of positive deltas.
- [ ] **Step 2:** Receipt tests: JSON round-trip; `markdown()` contains the headline via `Format.bytes` and one row per app in descending delta order.
- [ ] **Step 3:** Engine test with a fake backend and an injected sampler sequence: progress callbacks are monotone in `elapsed`, final receipt equals `Measurement.deltas` output; a backend throw still yields a thrown error and no receipt.
- [ ] **Step 4:** Implement (sampler injected through a protocol so tests do not touch the system). Run; PASS.
- [ ] **Step 5:** Commit `feat: relief engine with honest app-level measurement and receipts`.

### Task 7: Privileged helper daemon and installer

**Files:**
- Create: `Sources/RAMHelper/main.swift`, `Resources/ca.bryanyao.DownloadMoreRAM.helper.plist`, `Sources/RAMKit/Helper/HelperInstaller.swift`
- Test: `Tests/RAMIntegrationTests/HelperRootTests.swift` (skips unless the helper is installed)

**Interfaces:**
- Consumes: `HelperPolicy`, `Trigger`, `RAMHelperXPC`.
- Produces: daemon listening on `HelperConstants.machService`; on start: if `/var/run/ca.bryanyao.DownloadMoreRAM.holding` exists, write NORMAL and remove it; `relieve` writes the marker, triggers CRITICAL, holds, writes NORMAL, removes the marker (also on SIGTERM); `HelperInstaller.install(helperBinary: URL)` / `uninstall()` as root (copy to `/Library/PrivilegedHelperTools/`, write plist with `KeepAlive` on crash, `launchctl bootstrap system`); exits after 60 s idle (launchd relaunches on demand).

- [ ] **Step 1:** Root tests: relieve(critical, 3000) returns nil error and `kern.memorystatus_vm_pressure_level` reads 4 during the hold and the real level within 2 s after; `kill -9` of the helper mid-hold followed by a status call shows the pressure level back to the real level; 2 reliefs 5 s apart -> second refused with `tooSoon`.
- [ ] **Step 2:** Implement daemon + installer; build; ask Bryan to run `sudo .build/.../ram helper install` once (NEEDS_HUMAN H1).
- [ ] **Step 3:** Run root tests; PASS.
- [ ] **Step 4:** Commit `feat: privileged relief helper with crash-safe restore`.

### Task 8: Fixtures and integration tests

**Files:**
- Create: `Sources/RAMFixtures/main.swift` (`ram-fixture cachehog|dumbhog|leaker|orphan`)
- Test: `Tests/RAMIntegrationTests/FixtureTests.swift`

**Interfaces:**
- Produces: `ram-fixture cachehog --mb N` allocates and touches N MiB, registers `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` and frees the cache on event, printing `freed` to stdout; `dumbhog --mb N` holds; `leaker --mb-per-s R --seconds T`; `orphan --mb N` double-forks a child that holds N MiB and whose parent exits.

- [ ] **Step 1:** No-root tests (behind memory-gate): sampler sees cachehog 256 MiB within +-10%; orphan child has ppid 1 and is classified as orphan (Task 9); leaker's slope detected (Task 10).
- [ ] **Step 2:** Root test (helper installed): cachehog 512 + dumbhog 512, run `ReliefEngine` with hold 3000: cachehog footprint drops >= 90% of 512 MiB; dumbhog within +-5%; receipt lists cachehog with positive delta.
- [ ] **Step 3:** Implement fixtures; run; PASS.
- [ ] **Step 4:** Commit `test: controlled fixture processes and end-to-end relief test`.

### Task 9: Agent attribution, orphans, safe quit

**Files:**
- Create: `Sources/RAMKit/Process/AgentClassifier.swift`, `Sources/RAMKit/Kill/SafeKill.swift`; extend C shim with `dm_signal_audit(pid, idversion, sig)`
- Test: `Tests/RAMKitTests/AgentClassifierTests.swift`, `SafeKillTests.swift`

**Interfaces:**
- Produces: `struct CPUHistory { mutating func add(_ s: ProcessSnapshot); func idleSeconds(_ key: ProcessKey, now: Date) -> Double }` (idle = time since cpuTimeNs last increased by > 1 ms; first sighting counts from that sample).
- Produces: `struct AgentSession: Codable, Identifiable { id: Int32; tool: AgentTool; cwd: String?; label: String; footprint: UInt64; members: [ProcessRecord]; ageS: Double; idleS: Double }`, `enum AgentTool { claudeCode, codex, cursor, gemini, aider, opencode }`; `struct Leftover: Codable { record: ProcessRecord; reason: String; idleS: Double }`; `enum AgentClassifier { static func sessions(_ s: ProcessSnapshot, cpuHistory: CPUHistory) -> [AgentSession]; static func leftovers(_ s: ProcessSnapshot, cpuHistory: CPUHistory, now: Date) -> [Leftover] }`.
- Produces: `enum SafeKill { static func terminate(_ r: ProcessRecord, escalate: Bool) -> Result<Void, KillRefusal> }`, `enum KillRefusal: Error { otherUser, protected, identityChanged, failed(errno) }`.

- Firefox GPU process restart (spec 6): `SafeKill.restartFirefoxGPU(_ r: ProcessRecord)` only for a Firefox `-isForBrowser`-less GPU helper child of firefox, explicit click only, behind the VERIFY result for GPU-process restart safety.
- [ ] **Step 1:** Tests: `claude` binary under `.../claude-code/2.1.299/.../claude` with Blender/ffmpeg children -> one claudeCode session labelled by cwd basename, footprint summed; `python -m http.server 8765` with ppid 1 idle 3 h -> leftover "orphaned http.server, idle 3h"; an `.app` main executable with ppid 1 is never a leftover; SafeKill refuses uid != getuid(), names in the protected list, and a record whose current start time differs (`identityChanged`).
- [ ] **Step 2-4:** FAIL -> implement -> PASS (plus the orphan fixture integration test from Task 8).
- [ ] **Step 5:** Commit `feat: agent session attribution and safe leftover quitting`.

### Task 10: Wall model, leak detector, wall-event log

**Files:**
- Create: `Sources/RAMKit/Wall/WallModel.swift`, `Sources/RAMKit/Leak/LeakDetector.swift`, `Sources/RAMKit/Doctor/WallEventLog.swift`
- Test: `Tests/RAMKitTests/WallModelTests.swift`, `LeakDetectorTests.swift`, `WallEventLogTests.swift` (+ `Tests/RAMKitTests/Fixtures/loginwindow-2026-10-20.log`)

**Interfaces:**
- Produces: `struct WallStatus: Codable { percent: Double; etaSeconds: Double?; limitingFactor: WallFactor; reason: String }`, `enum WallFactor { swap, compressorPages, compressorSegments, disk, none }`; `struct WallModel { mutating func add(_ s: SystemSample); func status() -> WallStatus }` using the formulas recorded in `docs/research/VERIFY.md`.
- Produces: `struct LeakDetector { mutating func add(_ s: ProcessSnapshot); func leaks(now: Date) -> [Leak] }`, `struct Leak: Codable { key: ProcessKey; name; slopeBytesPerHour: Double; growthBytes: Int64; windowS: Double }`.
- Produces: `enum WallEventLog { static func parse(_ text: String) -> [WallEvent]; static func read(days: Int) throws -> [WallEvent] }` (runs `/usr/bin/log show` with a loginwindow + kernel predicate), `struct WallEvent: Codable { start: Date; end: Date?; pausedApps: [String] }`.

- [ ] **Step 1:** Wall tests: a sample equal to the target's 03:40 state (swap 11264M total / ~11 GB used at the swapfile cap, compressor 2.09M/6.45M) reads >= 95 with factor `.swap`; 2 GB swap used of an uncapped swap and 44% available reads < 70; ETA from a linear series of samples growing 140 MB/min toward the cap is within 10% of the analytic answer; flat series -> `etaSeconds == nil`.
- [ ] **Step 2:** Leak tests: 40 samples over 40 min growing 600 MB/h with noise -> one leak with slope 600 +- 60 MB/h; sawtooth GC pattern with no net growth -> none; 20 min window -> none.
- [ ] **Step 3:** Log parse test on the saved real excerpt -> episodes 03:23-03:36 (Firefox) and 03:40-03:59 (ChatGPT), merged across repeated `showLowMemoryPanel` lines.
- [ ] **Step 4:** Implement; run; PASS.
- [ ] **Step 5:** Commit `feat: wall model, leak detector and wall-event history`.

### Task 11: `ram` CLI

**Files:**
- Create: `Sources/RAMCLI/main.swift`, `Sources/RAMCLI/Commands/{Status,Apps,Agents,Download,Doctor,Watch,Bench,HelperCmd,Restore,ReceiptCmd}.swift`, `Sources/RAMCLI/Terminal.swift` (TTY detection, ANSI colors, live progress line)
- Test: `Tests/RAMKitTests/CLIRenderTests.swift` (render functions live in `Sources/RAMKit/CLI/Render.swift` so they are testable)

**Interfaces:**
- Consumes: everything above.
- Produces: commands per spec 5.10; `--json` on every read command; `ram download` renders the live download line `Downloading RAM  ████████░░  2.41 GB  380 MB/s  6s left` then the receipt table; exit codes: 0 ok, 2 usage, 3 relief unavailable (prints the enable line), 4 refused by policy.

- [ ] **Step 1:** Render tests (plain mode): status block contains headroom, pressure word, wall percent, swap line; receipt table rows sorted by delta with signed bytes; unavailable relief message equals `Downloads need the helper: run  sudo ram helper install  (or sudo ram download)`.
- [ ] **Step 2-4:** FAIL -> implement -> PASS; manual run of `ram status` timed (< 150 ms) and logged.
- [ ] **Step 5:** Commit `feat: ram CLI`.

### Task 12: Benchmark harness

**Files:**
- Create: `Sources/RAMKit/Bench/{BenchRunner,Scenarios,Workload}.swift`, `Sources/RAMCLI/Commands/Bench.swift` (wires it), `scripts/bench.sh`, `scripts/make-benchmarks-md.swift`
- Test: `Tests/RAMKitTests/BenchStatsTests.swift`

**Interfaces:**
- Produces: `ram bench real --trials N` (A/B: control window vs relief, alternating order seeded, cooldown 60 s, memory-gated), `ram bench synthetic` (headless Chromium from the Playwright cache with K heavy local tabs + cachehogs + idle node heap; skips with a reason when Chromium is absent), `ram bench perf` (foreground workload: allocate+touch a working set sized to 40% of current headroom, report throughput GB/s, swapins and wall time before/after relief vs control); all write JSON to `bench/results/<timestamp>-<scenario>.json`; `make-benchmarks-md.swift` turns JSON into `docs/BENCHMARKS.md` tables and README snippet.
- Gate: refuse to start (exit 5) when memory-gate fails; abort mid-run if `--abort` gate fails, killing only the bench's own children.

- [ ] **Step 1:** Stats tests: Welch t and effect size on fixed arrays match reference values; gate decision function refuses at level 14 / pressure 4 / swap free 1.4 GB.
- [ ] **Step 2-4:** FAIL -> implement -> PASS.
- [ ] **Step 5:** Run real benches on Bryan's machine (after the helper is installed), save JSON, generate docs.
- [ ] **Step 6:** Commit `feat: reproducible benchmarks with control arms`.

### Task 13: Menu bar app

**Files:**
- Create: `Sources/RAMApp/{main,AppDelegate,AppModel,StatusGlyph,PanelView,DownloadSheet,ReceiptCard,ShareCard,AgentsView,LeftoversView,Autopilot,HelperSetup,Theme,Snapshots}.swift`, `Resources/Info.plist`, `scripts/build.sh` (adapted from Reaper: assemble app with `ram` and `RAMHelper` inside, sign inside-out with watchdog)
- Test: `Tests/RAMKitTests/AutopilotTests.swift` (decision logic in `Sources/RAMKit/Autopilot/AutopilotPolicy.swift`)

**Interfaces:**
- Consumes: RAMKit.
- Produces: LSUIElement app; status glyph fill = 100 - wall%; panel per spec section 7; `--render-ui DIR` writes PNGs of panel states (normal, warn, downloading, receipt, no-helper) for verification; `AutopilotPolicy.decide(status: WallStatus, pressureHistory:, lastRun: Date?, now: Date) -> AutopilotAction` (`.none | .download | .notifyTopConsumers`).

- [ ] **Step 1:** Autopilot tests: fires at wall 85, at ETA 299 s, at critical for 21 s; not within 120 s of the last run; `.notifyTopConsumers` after 2 downloads within 10 min with wall still >= 85.
- [ ] **Step 2-4:** FAIL -> implement -> PASS.
- [ ] **Step 5:** Build the app, render all panel states, inspect PNGs; measure idle CPU/footprint/wakeups for 10 min (spec section 9) and log in PROGRESS.md.
- [ ] **Step 6:** Commit `feat: menu bar app`.

### Task 14: Acceptance, docs, reviews

**Files:**
- Create: `scripts/acceptance.sh`, `TEST_RESULTS.md` (generated), `README.md`, `docs/HOW_IT_WORKS.md`, `docs/SECURITY.md`, `docs/BENCHMARKS.md` (generated), `docs/research/VERIFY.md`, `NEEDS_HUMAN.md`, `LAUNCH.md`

- [ ] **Step 1:** `acceptance.sh` runs criteria 1-9 from spec section 11 and prints exactly one `ACCEPTANCE: n/9 PASS` line.
- [ ] **Step 2:** Write docs; README numbers are pasted only by `make-benchmarks-md.swift`.
- [ ] **Step 3:** Independent Fable review 1 (code + safety: restore paths, kill guards, helper surface). Fix findings; rerun.
- [ ] **Step 4:** Independent Fable review 2 (claims vs evidence: every README/LAUNCH claim traced to a test, bench JSON or source). Fix findings; rerun.
- [ ] **Step 5:** `ACCEPTANCE: 9/9 PASS`; commit `docs: launch materials and acceptance evidence`.
