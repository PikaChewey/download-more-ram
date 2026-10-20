# Run history that is not a result file (read by `ram bench report`)

- The first perf run (13:21, bench/logs/bench-synthetic-perf.log) stopped at trial 3 of 5 when another process sent the signal through the helper; it was rerun in full at 13:48 under the heavy-job lock, with arms touched by foreign signals redone (none were).
