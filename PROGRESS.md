# PROGRESS

Spec: ~/Documents/Goals/download-more-ram.md · Plan: docs/superpowers/plans/2026-10-20-download-more-ram.md ·
Research: docs/research/xnu.md, docs/research/apps.md

| Task | Status | Notes |
|---|---|---|
| 1 Package, shims, system sampler | done | |
| 2 Process sampler | done | ~10 ms per snapshot of ~530 pids |
| 3 Grouping, formatting, stats | done | binary units like Activity Monitor; Theil-Sen, Spearman, Welch |
| 4 Trigger encoding + helper policy | done | (6<<16)\|level, reset 0x60001, verified against Apple's memory_pressure.c |
| 5 Relief backends | done | restore on error/EINVAL/cancel/signals; marker for SIGKILL |
| 6 Relief engine + receipts | done | busy/new/gone exclusions; dry-run mode |
| 7 Helper daemon + installer | built, signed | waiting for H1 (sudo install) |
| 8 Fixtures + integration tests | done | root suites skip until helper installed |
| 9 Agents, leftovers, safe quit | done | 24 sessions / 13.95 GB found live |
| 10 Wall model, leaks, wall log | done | xnu limits; stuck-swap detection; 6 wall events in 7 days found |
| 11 CLI | done | status/apps/agents/download/doctor/resume/firefox/watch/bench/measure |
| 12 Bench harness | done | real/synthetic/perf + report; runs after H1 |
| 13 Menu bar app | in progress | Fable agent |
| 14 Acceptance, docs, reviews | in progress | review 1 (code/safety) running |

Extra (from live findings): resume apps paused at the wall (proc_clear_vmpressure), "helpers spinning
behind paused apps" detection, Firefox levers, recorded demo SVG.

## Measurements
- `ram status` (release): 20-70 ms (budget < 150 ms).
- Dry-run natural drift (no signal, 13 s window, 2026-10-20 ~07:00): -137 MB net across non-busy apps.

## Machine log
- 2026-10-20 03:23 / 03:40 / 04:49 LowMemoryPanel episodes; 04:49 left Claude, Firefox, ChatGPT, Opera GX,
  Discord and Raycast helpers suspended for 2+ h; paused apps' helpers spun at ~6 cores total on battery.
- 2026-10-20 04:12 another Claude Code session's render hit 16 GB; swap grew 11 -> 16 GB.

## Rules in force
- One heavy Swift job at a time (scripts/with-build-lock.sh); heavy runs gated by scripts/memory-gate.sh.
- Never touch other Claude sessions' processes or the user's apps without a yes; never type Bryan's password;
  no remote/push without asking; no Claude attribution in commits; no Workflows (Fable subagents only).
