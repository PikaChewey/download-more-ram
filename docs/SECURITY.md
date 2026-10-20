# Security

## The privileged helper

Downloads need root, because only root can write `kern.memorypressure_manual_trigger`. Instead
of running the whole app as root, a tiny launchd daemon (`ram-helper`, source:
`Sources/RAMHelper/main.swift`) does exactly one privileged thing.

- **Three XPC calls:** `relieve(level, holdMs)`, `restore()`, `status()`. No file paths, no
  shell, no arbitrary sysctl.
- **Validation and rate limits** (`HelperPolicy`, unit-tested): level must be warn or critical;
  hold 1–30 s; one download at a time; at least 20 s between downloads; at most 30 per hour.
- **Caller check:** when the helper is signed with a team identifier, it only accepts callers
  signed by the same team. Ad hoc builds accept any local caller, still bounded by the policy.
  The worst a hostile local process can do is make apps drop caches up to 30 times an hour.
- **Always restores normal pressure:** on completion, client disconnect, SIGTERM/SIGINT/SIGHUP
  (a signal-safe guard writes the reset before the process dies), and after SIGKILL or a crash
  (a marker file in `/var/run` makes the helper restore at its next start; launchd relaunches
  it on crash and at boot).
- **Logging:** every call is logged with the caller's pid
  (`log show --predicate 'subsystem == "ca.bryanyao.DownloadMoreRAM.helper"'`).
- **Idle:** it exits after 60 s idle; launchd relaunches it on demand.

Install: `sudo ram helper install` (you type your password; the app uses the standard macOS
administrator prompt). Remove: `sudo ram helper uninstall`, which also restores normal pressure.

## Quitting processes

- Only your own processes. Never other users', never system processes, never a protected list
  (WindowServer, loginwindow, Finder, Dock, launchd, …), never the frontmost app.
- Identity is checked by start time and signalled through an audit token, so a pid reused
  between listing and clicking is refused by the kernel.
- SIGTERM first; SIGKILL only on a second, explicit click.

## Firefox

The only file it ever edits is your Firefox profile's `user.js`, and only after you click. It
appends one marked line (`browser.lowMemoryResponseMask = 3`). Undo removes exactly that line.

## Privacy

No network, no telemetry. Receipts stay in `~/Library/Application Support/DownloadMoreRAM/`.
Share cards never include session names, folders or paths.

## Reporting

Open a GitHub issue, or email the maintainer for anything sensitive.
