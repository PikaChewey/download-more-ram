# Decisions (conservative calls made without asking)

- 2026-10-20: S1 is reported as measured (relief +478.5 MB vs control -72.0 MB, Welch p = 0.147, n = 5) with no re-run to chase significance; the README leads with the levers that move big numbers.
- 2026-10-20: The validation script was stopped after the pre-registered real bench so the remaining benches and the demo recording use the build with levers and the review fixes.
- 2026-10-20: Only the levers Bryan approved run on his Mac (signal, Firefox GPU restart). Leftovers and archived-session levers were exercised on fixtures only.
- 2026-10-20: The `rea` user-scope MCP config is reported with the fix, not changed (it is Bryan's Claude configuration).
- 2026-10-20: `sudo` user-file writes use process-wide seteuid (pthread_setugid_np is deprecated); the CLI only writes after a download finished.
- 2026-10-20: Menu bar glyph stays a template image (house style) even though X posts use colour; state is shown by shape.
