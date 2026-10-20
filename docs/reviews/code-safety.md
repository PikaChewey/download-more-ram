# Review 1: code and safety (independent Fable 5.1 reviewer, 2026-10-20)

Scope: Sources/CDarwinMem, Sources/RAMKit, Sources/RAMHelper, Sources/RAMCLI, Sources/RAMFixtures, scripts, tests.
Baseline: `swift test -j 2` 85 tests passing. Status column is updated as fixes land (fixed = code + test).

Status: OPEN (findings below are not yet addressed)

| # | Sev | Area | Finding (file) | Fix | Status |
|---|---|---|---|---|---|
| 1 | high | restore | `--hold` unvalidated on the sudo/direct path: negative/huge values trap after the CRITICAL write, kernel left at 4 (`RAMCLI/main.swift` download+bench, `ReliefBackends.swift` UInt64(holdMs)) | validate against HelperPolicy.holdRange in CLI and in DirectSysctlBackend before the write; UInt64(clamping:) | open |
| 2 | high | restore | guard covers only SIGINT/TERM/HUP; SIGQUIT, SIGPIPE (`sudo ram download \| head`), SIGTRAP/ABRT/SEGV/BUS/ILL, SIGALRM, SIGUSR1/2, SIGXCPU kill the holder with manual mode on (`cdarwinmem.c` dm_restore_guard_arm) | arm for every catchable terminating signal; ignore SIGPIPE in the CLI | open |
| 3 | medium | restore | `KeepAlive.Crashed` does not relaunch after SIGKILL; marker sits until next XPC launch/reboot (`HelperInstaller.swift`) | `KeepAlive {SuccessfulExit: false}` | open |
| 4 | medium | restore | single global marker clobbered by overlapping holders (helper + sudo CLI) (`ReliefBackends.swift`, helper) | per-pid markers, recovery globs them; delete only own | open |
| 5 | medium | restore | DirectSysctlBackend.relieve not serialized in-process; second arm/disarm leaves the first hold unguarded | serialize (global lock/actor) or refcount the guard | open |
| 6 | low | restore | ENOENT (missing oid) poisons the marker forever | treat ENOENT like EPERM | open |
| 7 | low | restore | spurious "interrupted download" warning during a live hold / after a guarded SIGINT | unlink marker in handler; check marker pid liveness before warning | open |
| 8 | low | abuse | helper `restore()` unlimited; each call re-notifies every process | rate-limit (<= 1/s) or no-op when nothing held | open |
| 9 | high* | privilege | root `chown()` follows symlinks in `RealUser.giveBack`; `--record`, `bench --out` also write as root (`Receipt.swift`) | drop privileges (seteuid/setegid to SUDO_UID/GID) around user-file writes or lchown + O_NOFOLLOW | open |
| 10 | medium | privilege | `applyCallerRequirement` fails open silently if Sec* calls fail (`RAMHelper/main.swift`) | fail closed + log, or bake the team id at build time | open |
| 11 | low | privilege | `resumePaused` no caller-uid check / rate limit | require same uid as the target unless root; rate-limit | open |
| 12 | low | privilege | installer copies ram-helper from argv[0]'s directory; createDirectory inherits umask | document; set 0755 root:wheel explicitly | open |
| 13 | low | build | build.sh per-binary ad hoc fallback can mix signatures | choose identity once; re-sign all or fail | open |
| 14 | low | policy | HelperPolicy uses wall-clock Date (clock step blocks downloads) | monotonic clock | open |
| 15 | medium | insight | `nextToPause` ignores throttle/kill registrants and PA_THROTTLE; 50% SIGKILL rule not reported (`WallModel.swift`) | candidate = max compressed over any pcontrol && !(flags & 0x1800); report action | open |
| 16 | low | kill | CLI never passes frontmostPid; same-uid /System processes killable by explicit pid (`SafeKill.swift`) | add isSystemPath to check; pass frontmost where possible | open |
| 17 | low | leftovers | "idle <age>" label wrong when recently active (lifetime rule) | skip lifetime rule when cpuFraction > activeFraction | open |
| 18 | low | kill | `--quit-archived` trusts exec-time env id | also require quiet CPU / idle | open |
| 19 | medium | wall | stuckSwap can flag imminent on a quiescent system (no swapouts) -> false red + autopilot | require swapouts to increase across the window | open |
| 20 | low | bench | bench hog sizing not from headroom; no swap-free rule; `--cooldown -1` / `--trials -1` trap | validate inputs; size from headroom | open |
| 21 | low | measure | member exits inside surviving apps always count; sameApp passes when head unreadable | document; control arm corrects; tighten sameApp | open |
| 22 | low | C | argv/env parse shifts when argv[0] is empty | handle empty argv[0] | open |
| 23 | low | robust | Format.duration traps on NaN/inf | guard non-finite | open |
| 24 | low | sudo | Firefox/transcripts use /var/root under sudo | use RealUser.home everywhere | open |
| 25 | docs | docs | SECURITY.md: "three calls" (four); "restores on client disconnect" (it completes the hold); "relaunch on crash" (not SIGKILL); frontmost (CLI); idle-daemon kills undisclosed | correct the docs | open |

*high only if `ram` is ever granted through a restricted sudoers rule; otherwise the user is already root.

Verified OK by the reviewer (abridged): every DirectSysctlBackend restore path incl. EINVAL-after-flag; helper relieve/restore/startup recovery; guard handler async-signal-safety; idle-exit cannot strand a hold; uninstall order; caller requirement string (team 8WA5T6YMPK) accepts ram, rejects /bin/ls; /var/run and PrivilegedHelperTools not user-plantable; resumePaused gated by the kernel's own PROC_ACTION_STATE; SafeKill identity + audit token; ReliefEngine exclusions; wall math vs xnu.md; Welch/Theil-Sen/Spearman; C struct layouts; UInt64 subtraction guards.
