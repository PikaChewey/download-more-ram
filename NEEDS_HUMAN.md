# Needs Bryan

Things the agent must not do itself (passwords, your own settings, publishing).

| # | What | Command / action | Status |
|---|---|---|---|
| H1 | Install the root helper | done 2026-10-20 12:38 | done |
| H1b | Reinstall the hardened helper (v1.1.0) | done 2026-10-21 14:03 (your password in the macOS prompt) | done |
| H11 | **Restart Firefox once**: its low-memory tab unloader is written but Firefox has been running since Oct 16, and it reads the setting only at launch. Until then the signal does nothing for your biggest app | quit and reopen Firefox (tabs come back if "Open previous windows and tabs" is on) | waiting |
| H2 | Real-machine downloads and benchmarks | approved 2026-10-20 | done |
| H3 | Firefox low-memory tab unloader (`browser.lowMemoryResponseMask = 3` in user.js) | written 12:42; applies the next time you restart Firefox; undo `ram firefox unloader off` | done |
| H4 | Restart Firefox's GPU process | done 12:42 (6.02 GB back), 13:10 (926.8 MB) and 14:08 (654.2 MB, the final recorded download) | done |
| H5 | Raycast's paused WebKit helper | resumed by `ram resume` 12:42 | done |
| H7 | Optional, biggest single win: `rea` (the reverse-engineering MCP server) is configured for EVERY Claude Code session in `~/.claude.json` (user scope), so 16 copies run at once (3.15 GB). Scope it to the projects that use it. | in Claude Code: `/mcp` (or `claude mcp remove rea -s user`, then add it with `-s project` in the RE projects) | your call |
| H9 | Optional: allow notifications for Download More RAM when macOS asks (it asks the first time the wall is minutes away; the warning names who is growing) | click Allow | when asked |
| H6 | Publish: create `PikaChewey/download-more-ram` (public), push, tag v1.1.0, then the Homebrew tap (packaging/) | say yes in chat | not asked yet |
| H10 | Optional, for a one-click download: a notarized DMG needs a **Developer ID Application** certificate (Apple Developer Program; this Mac only has an Apple Development one) and `xcrun notarytool store-credentials`. Until then the Homebrew formula and `scripts/install.sh` build from source, which needs no notarization | `DEVELOPER_ID="Developer ID Application: … (8WA5T6YMPK)" NOTARY_PROFILE=<profile> scripts/make-dmg.sh` | when you publish |
| H8 | Optional: re-record the launch clip on a heavy day (Firefox open for days, many sessions) so the number is bigger. The current clip and card come from the real 13:10 run (921.2 MB) | `ram download --levers firefox-gpu --record r.json`, then `DownloadMoreRAM --render-clip r.json clip.mp4` and `--render-share r.json card.png` | when you launch |

Undo the helper any time: `sudo ram helper uninstall` (also restores normal pressure).
