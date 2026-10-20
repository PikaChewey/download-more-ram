# Security

## The privileged helper

Downloads need root, because only root can write `kern.memorypressure_manual_trigger`. Instead
of running the whole app as root, a tiny launchd daemon (`ram-helper`, source:
`Sources/RAMHelper/main.swift`) does exactly one privileged thing.

- **Four XPC calls:** `relieve(level, holdMs)`, `restore()`, `status()`, `resumePaused(pid)`. No
  file paths, no shell, no arbitrary sysctl.
- **Validation and rate limits** (`HelperPolicy`, unit-tested, on a monotonic clock): level must be
  warn or critical; hold 1–30 s; one download at a time; at least 20 s between downloads; at most
  30 per hour. `restore` at most once per 5 s. `resumePaused` at most 20 per 10 s, only for
  processes carrying the kernel's own wall-pause flag, and only the caller's own processes unless
  the caller is root.
- **Caller check:** when the helper is signed with a team identifier, it only accepts callers
  signed by the same team. Ad hoc builds accept any local caller, still bounded by the policy. If
  the helper cannot read its own signature it refuses every caller (fails closed).
- **What a download does to the system, so you know the cost:** for the hold (10 s by default) the
  kernel reports simulated critical pressure, so apps drop caches; Chromium-based browsers discard
  one background tab per critical notification (it reloads when you click it); clean, idle
  background daemons may exit (launchd restarts them when needed); volatile purgeable memory is
  purged. The worst a hostile local caller can do on an ad hoc build is cause that up to 30 times an
  hour, or resume its own processes that macOS paused at the wall.
- **Always restores normal pressure:** a hold always runs to its end (even if the client goes
  away) and then resets; every catchable terminating signal (SIGTERM, SIGINT, SIGHUP, SIGQUIT,
  SIGPIPE, SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, …) runs a signal-safe guard that writes the reset
  before the process dies; after SIGKILL or power loss, the per-process marker in `/var/run` makes
  the helper restore at its next start (launchd relaunches it after any unsuccessful exit and at
  boot). Markers of a hold that is still running are never treated as interrupted.
- **Logging:** every call is logged with the caller's pid
  (`log show --predicate 'subsystem == "ca.bryanyao.DownloadMoreRAM.helper"'`).
- **Idle:** it exits after 60 s idle; launchd relaunches it on demand.

Install: `sudo ram helper install` (you type your password; the app uses the standard macOS
administrator prompt). It copies `ram-helper` from next to the `ram` you ran, so whoever can
write that folder decides what runs as root: never put `ram helper install` in a restricted
sudoers rule. Remove: `sudo ram helper uninstall`, which also restores normal pressure.

Under `sudo`, files written on your behalf (receipts, `--record`, bench results) are written with
your own uid for the duration of the write (process-wide seteuid, after the download is over), so a
symlink in your home cannot redirect a root write.

## Quitting processes

- Only your own processes. Never other users', never anything under `/System`, `/usr/libexec`,
  `/usr/sbin`, never a protected list (WindowServer, loginwindow, Finder, Dock, launchd, …), and in
  the app never the frontmost app. The CLI quits only a pid you type, or the processes a lever you
  named picks (`--levers leftovers,archived`), which it lists first and asks about (or `--yes`).
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
