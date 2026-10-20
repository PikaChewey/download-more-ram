# PROGRESS

Spec: ~/Documents/Goals/download-more-ram.md · Plan: docs/superpowers/plans/2026-10-20-download-more-ram.md

| Task | Status | Notes |
|---|---|---|
| 1 Package, shims, system sampler | done | 4 tests |
| 2 Process sampler | next | |

## Machine log
- 2026-10-20 03:23 / 03:40 LowMemoryPanel episodes (Firefox, ChatGPT, Discord paused).
- 2026-10-20 04:12 another Claude Code session's `node engine/build.js` render hit 16 GB footprint in 47 s; swap grew 11 -> 16 GB (so swap is not hard-capped at 11 GB).

## Rules in force
- One heavy Swift job at a time: scripts/with-build-lock.sh. Heavy runs gated by scripts/memory-gate.sh.
- Never touch processes of other Claude sessions; never type Bryan's password; no remote/push without asking.
