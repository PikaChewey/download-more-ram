# Commit IDs before publishing

Before the first push (2026-10-21) the history was rewritten once: commits moved to the author's GitHub
noreply address and the private launch notes left every commit. Commit IDs quoted in earlier documents
(docs/reviews/, PROGRESS.md) are the old ones; this table maps them.

| old | new | subject |
|---|---|---|
| fe84ee1 | 61572a4 | feat: package skeleton and system memory sampler |
| 528df6d | 8802185 | feat: per-process footprint sampler |
| 4fd53cc | 9989617 | feat: app grouping, formatting and robust stats |
| ca9f294 | 35da0b9 | feat: relief engine with honest app-level measurement and receipts |
| 3a50777 | edfa60a | feat: agent session attribution, leftovers and safe quitting |
| 4a14284 | 6736b6c | feat: leak detector and wall-event history from loginwindow logs |
| 231b3e8 | e73a45a | feat: kernel trigger encoding, helper policy and relief backends with guaranteed restore |
| 2594c41 | 4f44e18 | feat: wall model from xnu limits, pause predictions, frozen-process detection, ram CLI |
| 5f1535c | b031b41 | feat: autopilot policy, Firefox levers, app and integration targets |
| afdf959 | d6e95db | test: real-process fixture tests and helper end-to-end relief test |
| 4d9200e | f00227e | feat: benchmark harness (relief vs control, Welch t-test, workload perf, report generator) |
| 73d18f9 | c91f06c | docs: how it works, security model, research notes |
| 166c9be | 9f3e3fa | feat: ram watch (foreground autopilot); sudo receipts land in the user's home |
| 58332a7 | 84f376c | fix: line-buffer CLI output when piped |
| eb51870 | 82b10de | feat: ram doctor diagnosis with ranked fixes; ram firefox unloader/gpu-restart |
| 657b5f4 | 7bd9040 | feat: resume apps macOS paused at the memory wall (helper call + ram resume), per-product builds |
| 1f95b81 | 005caef | test: fix resume refusal assertion |
| 906c471 | ccacf6d | test: correct the registered-not-paused flag value |
| c5eefe5 | 32f698a | docs: README draft; bench report injects numbers between README markers |
| 4c495b5 | f30468b | docs: no example numbers until a real run fills them |
| cd8d3ea | 3e4b5b2 | test: acceptance script for the nine criteria |
| 98c54ce | b33639c | test: client-disconnect restore test, app budget measurement |
| 4d1b02a | 97e284a | feat: dry-run downloads, recorded demo SVG renderer, report helpers spinning behind paused apps |
| 5926074 | 69d9418 | docs: paused apps keep their helpers spinning (measured) |
| 35b9522 | 6773ccd | docs: launch kit (X thread, demo shot list, Show HN, Reddit) |
| c4203c4 | 17083e1 | test: one-shot real-machine validation script |
| 0988ee1 | 82c9a23 | docs: progress |
| 181af0a | d25fe59 | feat: menu bar app with wall meter, download sheet, receipts and share card |
| b0529d8 | 3df0dea | feat: Claude desktop session titles, last activity and archived-but-running sessions |
| 50ccd03 | ef0ad96 | docs: launch rule: no sample-data renders in posts |
| b89fbe6 | 5983a8b | perf: cache the swapfile directory listing between samples |
| 512bb72 | 2df571e | docs: session titles and archived-but-running sessions |
| 8075739 | 44768d6 | perf: 5 s sampling and no SwiftUI publishes while the panel is closed |
| eed9d32 | a1e098e | bench: Firefox GPU restart returned 6.02 GB; real bench first under its own gate |
| 384d700 | 52185bb | docs: record review 1 (code and safety) findings |
| 5ba24fb | a40caa2 | fix: all 25 review findings; feat: multi-lever downloads with per-lever receipts, doctor --fast, install and scorecard scripts |
| b6b5a24 | c4c05a8 | design: DESIGN.md from 15 confirmed X posts + house style; contrast checker (20/20 pairs pass) |
| 9b7bfd2 | 9d37364 | feat: duplicate MCP/dev servers across agent sessions (found 16 x rea mcp = 3.15 GB); v1.1.0 |
| 4936dfa | 690c59a | feat: doctor names the user-scope MCP server behind duplicates; clearer helper-refused message |
| 0a27fd8 | 959cecb | feat: lever progress beats; recordings carry the command; demo SVG from the real 13:10 multi-lever download (921.2 MB) |
| 50fb9c1 | 96ef88c | docs: needs-you list, decisions log, Homebrew formula (unpublished) |
| 6c9cb99 | 75f9446 | docs: launch kit rewritten around today's measured findings |
| 4827c3e | 1672196 | docs: README leads with the day's measured findings and the lever model |
| ca732d2 | 2c5bbf1 | docs: claims match their evidence files (6 paused apps, under 4 days, full sudo path); save doctor and agents evidence |
| 9f0be55 | 77c46da | review: re-review of safety fixes |
| 335021b | 93e4893 | feat: doctor reads macOS's own crisis reports (JetsamEvent): who held memory, how many processes the kernel killed |
| 5967dc1 | 3bce508 | bench: report lists redone arms; BENCHMARKS.md and README numbers generated from real + synthetic results |
| 8a2d221 | 6dcf709 | docs: lead with what macOS's own crisis reports show (6,645 processes killed in 11 minutes); evidence file |
| 01b9f7f | 0e59f20 | docs: thread numbering |
| ccfda8e | a300652 | feat: ram watch names who is pushing toward the wall right now (app + the processes growing inside it); calmer output |
| a6282b7 | 3d54a7b | app: rebuild the menu bar UI on the DESIGN.md tokens; RAM-chip download sheet, printed receipt, lever rows, clip and share renderers; idle cost 0.62% -> 0.04% CPU |
| 37ded91 | 8d9a5aa | fix: no time-to-wall from under a minute of history; README growth example from a recorded watch run |
| 0364a24 | 01abfc9 | bench: perf n=5 (honest null: 0.12 s vs 0.12 s, p = 0.50) and synthetic results; report regenerated |
| 2724000 | 10407a2 | docs: say plainly that the signal is not a speed-up (perf null) |
| 46e1a66 | 2686091 | clip: 4:5 with the panel filling the width, cold open with the download moving before 1 s, replay starts at the signal |
| 6b9c768 | f9b0273 | copy: leftovers lever title reads 'Quit servers agents left behind' |
| 900c57b | f7d69da | fix: a refused or failed signal ends the download at once (no fake progress); ram download waits out the helper's spacing once |
| b0d9e28 | 1fedcbd | demo: 4:5 clip and share card re-rendered from the 13:10 recording; final multi-lever download (570.9 MB) and first-run check saved |
| 3832784 | 3488a49 | bench: keep the logs of every real run |
| a2d8b45 | f25c577 | docs: demo block from the real 13:10 log; demo SVG shows the actual command; disk-space and swapfile claims stated only as far as the evidence goes |
| ee2a682 | 3c4d9ba | feat: one warning before the wall (autopilot or not) naming who is growing; clicking it opens the panel |
| d8f16d6 | 53fd8d9 | docs: needs-you list updated (final recording, optional heavy-day clip, notification prompt) |
| bd0983f | 12987d3 | release: DMG script (Developer ID + notarization when available); final app idle 0.025% CPU, 15.7 MB, 0.11 wakeups/s |
| 371706c | dca6002 | docs: independent claims review of the launch surfaces (3 high, 6 medium open) |
| 529bc46 | 693fdf5 | docs: every claims-review finding addressed (H1-H3, M1-M6, lows); verbatim captures saved as evidence; bench report flags exited children and lists run history |
| d6593b6 | 8b054f1 | docs: progress for v2 |
| b372640 | 74ab8e2 | docs: claims review re-verified after 529bc46; all findings addressed |
| 2621e62 | 3f05fce | test: acceptance 9/9 and scorecard 10/10 on the final build |
| 63cb227 | 6ae03ec | feat: Update helper when the installed one is older; say when Firefox needs a restart for its tab unloader; the app waits out the helper's spacing once |
| 949f66e | f5f39bc | verify: the installed app's own download, end to end (helper log shows the app's pid; receipt 2.80 GB; compressed data -3.04 GB); explain why Memory Used barely moves; neutral sample data |
