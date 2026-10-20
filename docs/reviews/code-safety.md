# Review 1: code and safety (independent Fable 5.1 reviewer, 2026-10-20)

Scope: Sources/CDarwinMem, Sources/RAMKit, Sources/RAMHelper, Sources/RAMCLI, Sources/RAMFixtures, scripts, tests.
Baseline: `swift test -j 2` 85 tests passing. Status column is updated as fixes land (fixed = code + test).

Status: all findings addressed
restore paths: verified

(Re-review 2026-10-20, below: no open or partial high/medium findings. Three low findings from review 1
remain open/partial (#13, #21, #22) and the re-review adds low/info findings only. The one thing that is
not a code finding but matters right now: the helper installed on this Mac is still v1.0.0, so none of the
helper-side fixes are in effect until `sudo ram helper install` is run from the signed build.)

| # | Sev | Area | Finding (file) | Fix | Status |
|---|---|---|---|---|---|
| 1 | high | restore | `--hold` unvalidated on the sudo/direct path: negative/huge values trap after the CRITICAL write, kernel left at 4 (`RAMCLI/main.swift` download+bench, `ReliefBackends.swift` UInt64(holdMs)) | validate against HelperPolicy.holdRange in CLI and in DirectSysctlBackend before the write; UInt64(clamping:) | fixed: `InputLimits.holdSeconds` 1–30 (Bench.swift:24-28) in download (main.swift:170-173) and bench (:410); `DirectSysctlBackend.validate` runs before the marker, the arm and the write (ReliefBackends.swift:20, 48-52); `UInt64(clamping:)` (:40). Test ReviewFixTests.holdIsValidatedBeforeTheWrite |
| 2 | high | restore | guard covers only SIGINT/TERM/HUP; SIGQUIT, SIGPIPE (`sudo ram download \| head`), SIGTRAP/ABRT/SEGV/BUS/ILL, SIGALRM, SIGUSR1/2, SIGXCPU kill the holder with manual mode on (`cdarwinmem.c` dm_restore_guard_arm) | arm for every catchable terminating signal; ignore SIGPIPE in the CLI | fixed: 20 signals incl. QUIT, ILL, TRAP, ABRT, EMT, FPE, BUS, SEGV, SYS, PIPE, ALRM, XCPU, XFSZ, VTALRM, PROF, USR1/2 (cdarwinmem.c:333-336); CLI ignores SIGPIPE (main.swift:8) and an ignored disposition is left alone (cdarwinmem.c:376). Test guardCoversSignalsAndRefusesSecondHold. Stop signals are not covered: new R-2 (low) |
| 3 | medium | restore | `KeepAlive.Crashed` does not relaunch after SIGKILL; marker sits until next XPC launch/reboot (`HelperInstaller.swift`) | `KeepAlive {SuccessfulExit: false}` | fixed in code: HelperInstaller.swift:44-48. No test asserts the plist text. The plist installed on this Mac (12:38) still says `Crashed: true` and the installed binary (10:15) is v1.0.0: reinstall |
| 4 | medium | restore | single global marker clobbered by overlapping holders (helper + sudo CLI) (`ReliefBackends.swift`, helper) | per-pid markers, recovery globs them; delete only own | fixed: `<prefix>.<pid>` holding "pid startTime" (HoldMarkers.swift:17-24); the holder removes only the path it wrote (ReliefBackends.swift:35, 43); helper startup, helper `restore` and `ram restore` remove `orphaned()` only (RAMHelper/main.swift:78, 173; ReliefBackends.swift:59); uninstall removes all (HelperInstaller.swift:94). Test holdMarkersTellLiveFromOrphaned |
| 5 | medium | restore | DirectSysctlBackend.relieve not serialized in-process; second arm/disarm leaves the first hold unguarded | serialize (global lock/actor) or refcount the guard | fixed: `dm_restore_guard_arm` returns EBUSY while armed (cdarwinmem.c:358) and `relieve` throws `.refused` without touching the kernel (ReliefBackends.swift:22-26). Test guardCoversSignalsAndRefusesSecondHold. Side effect on the live hold's marker: new R-1 (low) |
| 6 | low | restore | ENOENT (missing oid) poisons the marker forever | treat ENOENT like EPERM | fixed: `nothingSet = err == EPERM \|\| err == ENOENT` (ReliefBackends.swift:32-35); every other errno (incl. EINVAL, flag already set) still gets the NORMAL write. Not unit-testable without root; read |
| 7 | low | restore | spurious "interrupted download" warning during a live hold / after a guarded SIGINT | unlink marker in handler; check marker pid liveness before warning | fixed: handler unlinks after a successful restore (cdarwinmem.c:350); `interruptedHoldDetected` = `HoldMarkers.orphaned()` (ReliefBackends.swift:160), liveness by pid + start time (HoldMarkers.swift:47-51). Test holdMarkersTellLiveFromOrphaned |
| 8 | low | abuse | helper `restore()` unlimited; each call re-notifies every process | rate-limit (<= 1/s) or no-op when nothing held | fixed in code: one restore per 5 s (RAMHelper/main.swift:68-76). No test (helper process) |
| 9 | high* | privilege | root `chown()` follows symlinks in `RealUser.giveBack`; `--record`, `bench --out` also write as root (`Receipt.swift`) | drop privileges (seteuid/setegid to SUDO_UID/GID) around user-file writes or lchown + O_NOFOLLOW | fixed: `RealUser.asUser` (Receipt.swift:159-167) setegid then seteuid, restored in a defer; wraps receipts (:101), `--record` (main.swift:204) and bench results (:431); no chown remains. Test asUserIsAPassThroughWithoutSudo covers the non-sudo path only |
| 10 | medium | privilege | `applyCallerRequirement` fails open silently if Sec* calls fail (`RAMHelper/main.swift`) | fail closed + log, or bake the team id at build time | fixed in code: `callerPolicy()` returns `.refuseAll` on any Sec* failure and the listener then rejects every connection (RAMHelper/main.swift:32-36, 156-166, 184-186); team-signed builds set the requirement, ad hoc builds accept local callers (documented SECURITY.md:16-18) |
| 11 | low | privilege | `resumePaused` no caller-uid check / rate limit | require same uid as the target unless root; rate-limit | fixed in code: caller's `effectiveUserIdentifier` must own the target unless root; 20 per 10 s (RAMHelper/main.swift:86-105) |
| 12 | low | privilege | installer copies ram-helper from argv[0]'s directory; createDirectory inherits umask | document; set 0755 root:wheel explicitly | fixed: explicit 0755/0644 root:wheel on directory, binary and plist (HelperInstaller.swift:72-80); documented (:57-59, SECURITY.md:35-38) |
| 13 | low | build | build.sh per-binary ad hoc fallback can mix signatures | choose identity once; re-sign all or fail | partial: the three CLI products are re-signed ad hoc together if any of them failed (build.sh:70-78), but the app-bundle stage (:80-94) ignores `SIGN_FAILED`: a failed re-sign of `Contents/Helpers/ram` or of the bundle leaves a mixed/unsigned bundle and the script still exits 0 printing "signed with: identity". Fix: after the app stage, `(( SIGN_FAILED )) && exit 1` (or redo the bundle ad hoc) |
| 14 | low | policy | HelperPolicy uses wall-clock Date (clock step blocks downloads) | monotonic clock | fixed: `monotonicNow()` from `systemUptime` feeds admit/finished, the restore limiter and the resume limiter (RAMHelper/main.swift:20, 47, 60, 70, 91) |
| 15 | medium | insight | `nextToPause` ignores throttle/kill registrants and PA_THROTTLE; 50% SIGKILL rule not reported (`WallModel.swift`) | candidate = max compressed over any pcontrol && !(flags & 0x1800); report action | fixed: unregistered process holding > 50% of compressed memory is reported as killed outright, else the largest registrant with PA bits clear with its own action (WallModel.swift:147-158); `Render.actionVerb` shows pauses/kills/throttles. Test nextVictimFollowsTheKernelsRules |
| 16 | low | kill | CLI never passes frontmostPid; same-uid /System processes killable by explicit pid (`SafeKill.swift`) | add isSystemPath to check; pass frontmost where possible | fixed: `AppGrouper.isSystemPath` refused in `SafeKill.check` (SafeKill.swift:42; /System, /usr/libexec, /usr/sbin, /sbin, /Library/Apple); the CLI has no frontmost notion (documented). Test systemBinariesAreProtected |
| 17 | low | leftovers | "idle <age>" label wrong when recently active (lifetime rule) | skip lifetime rule when cpuFraction > activeFraction | fixed: `activeNow` forces idle 0 (AgentClassifier.swift:252-254). Test recentlyActiveOrphanIsNotIdle |
| 18 | low | kill | `--quit-archived` trusts exec-time env id | also require quiet CPU / idle | fixed: `safeToQuitArchived` needs archived + CPU <= 1% + no activity for 30 min (AgentClassifier.swift:271-276), used by the CLI (main.swift:131) and the lever (Levers.swift:92, 147, 155). Test archivedSessionsMustAlsoBeQuiet |
| 19 | medium | wall | stuckSwap can flag imminent on a quiescent system (no swapouts) -> false red + autopilot | require swapouts to increase across the window | fixed: `stuckSwap` returns nil unless swapouts grew across the under-hiwater run (WallModel.swift:105-116). Tests quietSwapIsNotImminent, swapStuckFullIsImminent |
| 20 | low | bench | bench hog sizing not from headroom; no swap-free rule; `--cooldown -1` / `--trials -1` trap | validate inputs; size from headroom | fixed: `InputLimits.int` ranges (trials 1–50, cooldown 20–600, hogs 1–8, mb bounded) and `cappedMB` = min(request, headroom/4) with per-hog headroom (Bench.swift:23-40; main.swift:409-428). Test benchInputsAreBounded |
| 21 | low | measure | member exits inside surviving apps always count; sameApp passes when head unreadable | document; control arm corrects; tighten sameApp | open (low): Measurement.swift is unchanged since 384d700 (`sameApp` still returns true when either head is unreadable, :91-97) and `Receipt.methodNote` (:53-58) does not say that exits inside a surviving app count. The control arm in bench does correct for it |
| 22 | low | C | argv/env parse shifts when argv[0] is empty | handle empty argv[0] | open (low): `dm_proc_argv`/`dm_proc_env` unchanged (cdarwinmem.c:214-215, 250-251): the padding skip eats an empty argv[0], so argv gains env[0] and `dm_proc_env` misses it. Same limitation as Apple's ps; only affects a process exec'd with argv[0] == "" |
| 23 | low | robust | Format.duration traps on NaN/inf | guard non-finite | fixed: Format.swift:35-36. Test nonFiniteDurations |
| 24 | low | sudo | Firefox/transcripts use /var/root under sudo | use RealUser.home everywhere | fixed: `RealUser.home` in FirefoxLevers.supportDir (:15), ClaudeTranscripts (:154), ClaudeDesktopSessions (:46), ClaudeMCPConfig (:7), receipts (:95). Cosmetic leftover: `AgentClassifier.label(forCwd:)` (:280) still uses the current user's home, so under sudo "~" is never shown |
| 25 | docs | docs | SECURITY.md: "three calls" (four); "restores on client disconnect" (it completes the hold); "relaunch on crash" (not SIGKILL); frontmost (CLI); idle-daemon kills undisclosed | correct the docs | fixed: four calls (:9), hold runs to its end (:25-26), relaunch after any unsuccessful exit incl. SIGKILL (:28-30), idle daemons (:20-22), frontmost is app-only (:46-47). New wording drift from the lever feature: R-10 |

*high only if `ram` is ever granted through a restricted sudoers rule; otherwise the user is already root.

Verified OK by the reviewer (abridged): every DirectSysctlBackend restore path incl. EINVAL-after-flag; helper relieve/restore/startup recovery; guard handler async-signal-safety; idle-exit cannot strand a hold; uninstall order; caller requirement string (team 8WA5T6YMPK) accepts ram, rejects /bin/ls; /var/run and PrivilegedHelperTools not user-plantable; resumePaused gated by the kernel's own PROC_ACTION_STATE; SafeKill identity + audit token; ReliefEngine exclusions; wall math vs xnu.md; Welch/Theil-Sen/Spearman; C struct layouts; UInt64 subtraction guards.

## Re-review 2026-10-20 (same reviewer, after commits 5ba24fb..0a27fd8)

Method: every file named above re-read at HEAD (0a27fd8); each finding checked against code and its test;
the new code since review 1 (multi-lever downloads, HoldMarkers, RealUser.asUser, DuplicateServers +
ClaudeMCPConfig, lever progress events, InputLimits) reviewed with the same rigor; every trigger write
traced to its restore. Sources/RAMApp was excluded (being edited concurrently); it never writes the trigger
(non-root, helper only). No source file was changed by the reviewer.

Tests: the full `swift test` cannot link right now because Sources/RAMApp does not compile (the concurrent
edit), so the fixture and both test targets were built on their own and run with `--skip-build`:
106 tests in 32 suites, 105 passed, 1 failed: `swapUsageMatchesSysctl` (SystemSampleTests.swift:23), two
swap readings 72 MB apart on a Mac that was actively swapping at 19 % available against a 64 MB tolerance.
That is an environmental flake of a tolerance test, not a safety issue (widen the tolerance or compare
within one sample). Every review-fix test (ReviewFixTests, 11 tests) and every lever test passed. The root
integration suites were skipped by their memory gate during the first run (a concurrent download from the
installed helper had the kernel at level 4 at 13:22); the re-run of those suites is reported at the end.

### Restore paths, re-verified at HEAD

The trigger is written in exactly one non-restoring place, `DirectSysctlBackend.relieve`
(ReliefBackends.swift:27). Every other `Trigger.write` is a NORMAL (0x60001) reset: ReliefBackends.swift:33,
41, 57; RAMHelper/main.swift:77 (XPC restore), 171 (startup); HelperInstaller.swift:91 (uninstall). No script
or test writes it.

- Normal completion, task cancellation (`waitError`) and any error after the handler was reached: the NORMAL
  write at :33/:41 runs before the throw; only EPERM/ENOENT skip it, and those never reach the handler (the
  sysctl root check and the name lookup both fail before `sysctl_memorypressure_manual_trigger` sets
  `memorystatus_manual_testing_on`). Validation (:20) runs before the marker, the arm and the write, so no
  trap can happen mid-hold.
- SIGPIPE: ignored in the CLI at startup (main.swift:8) and `arm` leaves an ignored disposition alone
  (cdarwinmem.c:376): `sudo ram download | head` now gets EPIPE on the write and the hold finishes. In the
  helper (which never writes to a pipe) and anywhere else SIGPIPE is not ignored, the guard handler catches it.
- Crash signals: SIGILL, SIGTRAP (Swift runtime traps on arm64), SIGABRT, SIGEMT, SIGFPE, SIGBUS, SIGSEGV,
  SIGSYS are armed (cdarwinmem.c:333-336). The handler is the raw `sysctl` syscall on a pre-resolved MIB,
  `unlink`, `signal`, `raise` (all async-signal-safe); other guard signals are blocked while it runs
  (sa_mask, :369). A stack-overflow SIGSEGV cannot run a handler (no sigaltstack): the marker then covers it.
- EBUSY second hold: refused before any kernel write (cdarwinmem.c:358, ReliefBackends.swift:23-26). See R-1.
- ENOENT: nothing was set, no NORMAL write, marker removed (ReliefBackends.swift:32-35).
- Marker: written before the arm (:21), copied into a static buffer by `arm` (:364), unlinked by the handler
  only after the NORMAL write succeeded (:350), removed by the holder only after a successful NORMAL write
  (:35, :43); on `restoreFailed` the marker stays so `ram status` warns and the helper restores at its next start.
- SIGKILL / power loss: marker survives; the helper restores at startup only for markers whose owner is
  gone or whose pid now belongs to another process (RAMHelper/main.swift:169-174, HoldMarkers.swift:47-55);
  `ram status`/`ram download` warn via the same `orphaned()` (main.swift:32-36), readable without root
  (/var/run is 0775 root:daemon, markers 0644). `KeepAlive {SuccessfulExit: false}` + `RunAtLoad` means
  launchd relaunches the helper after any non-zero exit or signal death and at boot, and leaves an idle
  `exit(0)` alone until the next XPC demand, which is the intended semantics.
- Live hold is never "recovered": a running holder's marker has a matching start time (root readers) or
  answers `kill(pid, 0)` with 0/EPERM (non-root readers), so neither the helper nor `ram restore` touches it.
- Client disconnect: the helper's hold runs in a detached task and replies afterwards; `policy.isRunning`
  keeps the idle timer from exiting during a hold (RAMHelper/main.swift:56-63, 136).

Two paths defer the restore rather than skip it; both are low and listed below: a job-control stop (R-2) and
an `exit()` without a signal (R-3, R-4).

### New findings

| # | Sev | Area | Finding (file:line) | Failure scenario | Fix |
|---|---|---|---|---|---|
| R-1 | low | restore | A refused second `relieve` in the same process deletes the live hold's marker (ReliefBackends.swift:21-26): `HoldMarkers.write` overwrites `<prefix>.<pid>` (same path as hold 1) before `arm` returns EBUSY, then `HoldMarkers.remove(marker)` unlinks it | A process that calls `relieve` twice concurrently (no shipping caller does: the helper's policy returns `.busy` first, the CLI/bench/autopilot run one at a time) loses SIGKILL recovery for the running hold: no warning, no helper restore | Check `dm_restore_guard_is_armed()` (or arm first) before writing the marker; never remove a marker you did not just create |
| R-2 | low | restore | Job-control stop signals are not in the guard (cdarwinmem.c:333-336): SIGTSTP/SIGTTIN/SIGTTOU stop the holder with simulated pressure on, and `isLive` reports a stopped holder as live, so `ram status` does not warn | Ctrl-Z during `sudo ram download`: the kernel stays at simulated critical (and real pressure tracking stays frozen, xnu.md §2) until `fg` or a kill; the shell shows the stopped job, `fg` ends the hold normally | Add SIGTSTP, SIGTTIN, SIGTTOU to `g_guard_signals`: the handler restores, unlinks and re-raises the default (stop); on SIGCONT the hold's final NORMAL write is a harmless repeat |
| R-3 | low | restore | `ReliefEngine.run` never awaits the relief task on its own error paths (ReliefEngine.swift:98-120); the CLI's `fail()` then calls `exit()` (RAMCLI/main.swift:210-214), which runs no signal handler | Only if `sampling.systemSample()` or `sampling.sleep` throws while a direct (sudo) hold is live, which host_statistics64 never does in practice; the marker is left for the helper/`ram status` | Await `relief.value` in a `defer`/catch before rethrowing, or register an `atexit` restore in the CLI |
| R-4 | low | restore | Helper idle exit races a new hold (RAMHelper/main.swift:132-141): `!policy.isRunning` is checked under the lock but `exit(0)` runs after it is released, so a `relieve` admitted in that gap can be cut off by `exit(0)`, which leaves exit status 0 (no relaunch until the next XPC demand) | Microsecond window; the marker (written before the trigger write) makes the next helper start restore | Take the lock across the check and `exit`, or set a `draining` flag under the lock that `relieve` refuses |
| R-5 | low | kill | `--levers leftovers,archived` (or `all`) quits classifier-chosen processes without showing them first, and `--dry-run` disables levers (main.swift:176), so there is no preview; `ram agents --quit-archived` requires `--yes` but the lever does not (Levers.swift:25 `needsConsent` is not consulted by the CLI) | A user who types `--levers all` to "get everything" also quits a `nohup`'d dev server from a closed Terminal that has been idle 10 min (leftover rules: same uid, ppid 1, responsible != self, dev-tool name). Every kill still passes SafeKill (uid, protected names, system paths, start time, audit token) and the receipt lists the targets | Print the targets and require `--yes` for consent levers, or make `--dry-run --levers` report what would be quit |
| R-6 | low | resume | The `resume` lever ignores `PausedApps.safeToResume` (Levers.swift:168-173) although the offer logic applies it (:98-99) | `--levers resume|all` right after hitting the wall resumes every paused process while the wall is still near; same behaviour as the explicit `ram resume` | Skip with "wall still near" unless the user passes `resume` explicitly |
| R-7 | info | measure | The GPU lever counts the whole Firefox group's delta over its 6 s window, busy or not (Levers.swift:130-141); late responses to the signal or growth of the new GPU process land in the lever's number. The windows themselves are disjoint (the signal is measured over before -> afterSignal, :123-125; each lever takes its own before after that), so nothing is double-counted and the headline stays Σ levers | Attribution label, not the total | Report the GPU process delta and the rest-of-group drift separately, or apply the busy rule |
| R-8 | info | sudo | Under `sudo` the levers compare against `getuid()` == 0 (SafeKill.swift:39, AgentClassifier.swift:244), so the sudo user's processes never qualify: `--levers` is silently inert ("belongs to another user", "nothing to quit") | Safe but surprising on the direct path | Use SUDO_UID for ownership on the direct path, or say so in the output |
| R-9 | info | privacy | `serverKey` (DuplicateServers.swift:42-52) builds the duplicate's label from up to two non-flag argv tokens, so `ram agents`/`ram doctor`/`--json` can echo a positional argv value of the user's own process (visible to the same user via ps anyway); `~/.claude.json` reading is clean: only `mcpServers.*.command/args` basenames, never `env` (ClaudeMCPConfig.swift:10-23; test fixture carries `env: {TOKEN}` and asserts `["rea","mcp"]`) and only the server *name* is printed (Diagnosis.swift:85-86) | Same-user data shown to the same user; receipts and share data do not contain it | Keep only the launcher's script/subcommand token |
| R-10 | docs | docs | SECURITY.md:47 "the CLI acts only on a pid you type" is no longer true (`--levers leftovers,archived`, `ram agents --quit-archived --yes`); SECURITY.md:40-41 "written with your own uid on that thread": seteuid is process-wide (Receipt.swift:155-157 says so) | Reader is misled about what the CLI can quit | Reword: the CLI quits a pid you type or the levers you name on the command line; "for the duration of the write" |
| R-11 | info | ops | The helper installed on this Mac is v1.0.0: `/Library/PrivilegedHelperTools/ca.bryanyao.DownloadMoreRAM.helper` (10:15, strings "1.0.0", single `.holding` marker path) and the plist (12:38) has `KeepAlive {Crashed: true}`; the signed `build/Products.noindex/bin/ram-helper` (13:13) differs. A live v1.0 hold was observed at 13:22 (legacy marker + level 4), and the v1.1 CLI handled the legacy marker correctly (live, no warning; gone after the hold) | Findings 2, 3, 4, 6, 7, 8, 10, 11, 14 are fixed in the repo but not in effect on this Mac | `sudo ram helper install` from the signed build (the reviewer never runs sudo) |

Verified OK in the new code (abridged): `LeverKind.parse` rejects "signal" and `all` excludes it; the engine
filters `.kernelSignal`; `--dry-run` runs no lever; every lever kill goes through `SafeKill.terminate`
(uid, protected names, system paths, start-time identity, audit token); archived needs the desktop
`isArchived` flag + CPU <= 1 % + 30 min quiet; leftovers need same uid, ppid 1, responsible != self,
dev-tool name, idle >= 10 min; GPU restart needs >= 1 GB and > 30 s uptime; leftovers/archived count only
the targeted keys (exited -> full footprint, survivor -> its change, Levers.swift:161-165); headline ==
Σ lever bytes by construction (ReliefEngine.swift:152) and `Receipt.leverSum` recomputes it; the real
13:10 receipt sums (-5.9 MB signal + 971.8 MB GPU = 965.9 MB); progress events and the demo recorder carry
lever titles only (no targets, titles or paths); HoldMarkers liveness uses (pid, start time) when readable
and `kill(pid, 0)` otherwise, treats a reused pid as orphaned, parses the v1.0 single marker (pid from its
content, else 0 -> orphaned) and lives in root-owned /var/run; `RealUser.asUser` orders setegid before
seteuid, seteuid(0) before setegid(0), restores in a defer on throw, rolls back egid if seteuid fails, and is
a plain call without sudo or with SUDO_UID 0, and every caller runs after the hold has ended; InputLimits
bounds hold 1–30 s, trials 1–50, cooldown 20–600 s, hogs 1–8, MB 16–2048/64–4096 then headroom/4 (min 16),
doctor days 1–90; the helper's XPC `restore` is itself a NORMAL write and removes only orphaned markers.

Root integration suites (installed helper, re-run under `--filter "ReliefEndToEndTests|FixtureTests"`):
"Relief end to end (helper)" passed 2/2 (`pressureAwareCacheIsReturnedAndDumbHogIsNot` 11.9 s,
`killingTheClientMidHoldStillRestoresNormal` 33.7 s): the v1.1 signed CLI downloaded through the installed
v1.0.0 helper, the cachehog returned its cache, the dumbhog kept its memory, the helper finished the hold
after its client was SIGKILLed, the kernel read normal (level 1) afterwards and `interruptedHoldDetected`
was false with the helper's legacy marker present during the hold and gone after it. "Fixtures (real
processes)" stayed skipped by its 20 % gate (19 % available). A fresh legacy marker from another, concurrent
hold was visible for a moment after the run and had gone a minute later with pressure at the real level:
nothing was left stuck.

## Author's changes after review 2 (claims for the next review to verify, not verdicts)

- R-1: `DirectSysctlBackend.relieve` checks `dm_restore_guard_is_armed()` before writing any marker.
- R-2: SIGTSTP/SIGTTIN/SIGTTOU are guarded; `dm_restore_guard_disarm` restores handlers even after a
  handler already restored (`g_guard_installed`). Test `jobControlStopsAreGuarded`.
- R-3: `ReliefEngine.run` cancels and awaits the relief task before rethrowing any error.
- R-4: the helper's idle exit runs while holding the policy lock.
- R-5: `--levers leftovers/archived` lists the targets first and asks (TTY) or needs `--yes`;
  `--dry-run` shows the list. Test `previewListsWhatQuittingLeversWouldQuit`.
- R-6: the resume lever skips while the wall is near unless `resume` is named explicitly.
- R-8: ownership checks use `RealUser.uid` (SUDO_UID under sudo).
- R-10: SECURITY.md reworded.
- 13: build.sh deletes a half-signed app bundle and exits 1.
- 21: `Receipt.methodNote` says a helper exiting inside a surviving app counts as given back.
- Also: the helper end-to-end suite is opt-in (`RAM_LIVE_TESTS=1`, set by scripts/acceptance.sh), and
  benchmark arms touched by another process's signal (helper log) are redone and listed in `redone`.
