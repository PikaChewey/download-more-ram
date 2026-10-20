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
| 7 Helper daemon + installer | done | v1.0.0 installed; hardened v1.1.0 built, waiting for H1b |
| 8 Fixtures + integration tests | done | root suites skip until helper installed |
| 9 Agents, leftovers, safe quit | done | 24 sessions / 13.95 GB found live |
| 10 Wall model, leaks, wall log | done | xnu limits; stuck-swap detection; 6 wall events in 7 days found |
| 11 CLI | done | status/apps/agents/download/doctor/resume/firefox/watch/bench/measure |
| 12 Bench harness | done | real/synthetic/perf + report; runs after H1 |
| 13 Menu bar app | done | DESIGN.md UI (a6282b7); idle 0.025% CPU, 15.7 MB, 0.11 wakeups/s (bench/app-budget.json) |
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

## v2 (spec ~/Documents/Goals/download-more-ram-v2.md), 2026-10-20 afternoon

Scorecard (scripts/scorecard.sh): S1-S9 pass; S10 waits on the claims reviewer's re-verification.
- Multi-lever downloads with per-lever receipts (headline == sum); final recorded run 14:08: 570.9 MB.
- `ram doctor` reads macOS's own crisis reports (JetsamEvent): Oct 16 04:02-04:12, 6,645 background processes
  killed while the Claude app's coalition held 45.5 GB (23 x python3.12 = 35.7 GB).
- `ram watch` and the app name who is growing toward the wall (GrowthTracker); the app warns once before the wall.
- Duplicate MCP servers per session (16 x rea mcp = 3.15 GB), archived-but-running sessions, paused-app resume.
- Safety: review 1 (25 findings) and review 2 (R-1..R-10) fixed; reviewer closed docs/reviews/code-safety.md.
- Benches: real (n=5, p=0.147, not significant), synthetic (cachehog 112/112 MB every relief arm, p<0.001),
  perf (n=5, 0.12 s vs 0.12 s, p=0.50: honest null). Bench redoes arms touched by another process's signal.
- Demo: 4:5 clip, share card and SVG from the real 13:10 recording (921.2 MB); claims-evidence review round 1
  found 3 high / 6 medium / 18 low, all fixed in 529bc46 with verbatim captures saved under bench/evidence/.
- Still needs Bryan: H1b helper v1.1.0, H6 publish, H7 rea scope, H10 Developer ID for a notarized DMG.
