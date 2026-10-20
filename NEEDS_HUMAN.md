# Needs Bryan

Things the agent must not do itself (passwords, your own settings, publishing).

| # | What | Command / action | Status |
|---|---|---|---|
| H1 | Install the root helper | done 2026-10-20 12:38 | done |
| H1b | **Reinstall the hardened helper (v1.1.0)**: per-process hold markers, every-signal restore guard, relaunch on SIGKILL, fail-closed caller check, resume only your own processes | `sudo ~/Documents/XCode/DownloadMoreRAM/build/Products.noindex/bin/ram helper install` | waiting |
| H2 | Real-machine downloads and benchmarks | approved 2026-10-20 | done |
| H3 | Firefox low-memory tab unloader (`browser.lowMemoryResponseMask = 3` in user.js) | written 12:42; applies the next time you restart Firefox; undo `ram firefox unloader off` | done |
| H4 | Restart Firefox's GPU process | done 12:42 (6.02 GB back) and 13:10 (0.93 GB) | done |
| H5 | Raycast's paused WebKit helper | resumed by `ram resume` 12:42 | done |
| H7 | Optional, biggest single win: `rea` (the reverse-engineering MCP server) is configured for EVERY Claude Code session in `~/.claude.json` (user scope), so 16 copies run at once (3.15 GB). Scope it to the projects that use it. | in Claude Code: `/mcp` (or `claude mcp remove rea -s user`, then add it with `-s project` in the RE projects) | your call |
| H6 | Publish: create `PikaChewey/download-more-ram` (public), push, tag v1.1.0, then the Homebrew tap (packaging/) | say yes in chat | not asked yet |
| H8 | Record the launch video on a heavy day (Firefox open for days, many sessions) | `ram download --levers firefox-gpu --record r.json`, then `DownloadMoreRAM --render-clip r.json clip.mp4` | when you launch |

Undo the helper any time: `sudo ram helper uninstall` (also restores normal pressure).
