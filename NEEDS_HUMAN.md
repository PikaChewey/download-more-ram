# Needs Bryan

Things the agent must not do itself (passwords, changes to your own apps, publishing).

| # | What | Command / action | Status |
|---|---|---|---|
| H1 | Install the root helper once (type your password) | `sudo ~/Documents/XCode/DownloadMoreRAM/build/Products.noindex/bin/ram helper install` | waiting |
| H2 | Allow real-machine download tests (10 s simulated critical pressure; apps drop caches, a Chromium browser may discard one background tab, idle daemons restart on demand) | say yes in chat | waiting |
| H3 | Optional: turn on Firefox's low-memory tab unloader (`user_pref("browser.lowMemoryResponseMask", 3);` in the default profile's user.js, applies on next Firefox start, undo = delete the line) | say yes in chat | waiting |
| H4 | Optional: restart Firefox's GPU process (5.36 GB at 04:10; Firefox relaunches it; WebGL/canvas reset) | say yes in chat | waiting |
| H5 | Restart Raycast: its `com.apple.WebKit.Networking` helper (pid 1149) is still paused by macOS since the 03:40 memory wall | quit + reopen Raycast | waiting |
| H5b | **Your apps are paused right now** (since 04:49-04:53): Claude, Firefox, ChatGPT, Opera GX, Discord main processes + Raycast's WebKit helpers were suspended by macOS's out-of-memory action. Click Resume in the Force Quit panel (or quit/reopen them). `ram doctor` shows the list. | Force Quit panel → Resume | waiting |
| H6 | Create the GitHub repo `PikaChewey/download-more-ram` and push (public) | say yes in chat | not asked yet |

Undo the helper any time: `sudo ram helper uninstall` (also restores normal pressure).
