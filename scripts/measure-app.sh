#!/bin/zsh
# Measures the menu bar app's idle cost (spec section 9) and writes bench/app-budget.json.
# Launches the built app in the background (no activation), waits for it to settle, measures for
# N seconds with the panel closed, then quits it.
#   scripts/measure-app.sh [seconds]   default 300
set -euo pipefail
cd "$(dirname "$0")/.."
SECONDS_TO_MEASURE=${1:-300}
APP="build/Products.noindex/Download More RAM.app"
[[ -d $APP ]] || { echo "build the app first: scripts/build.sh" >&2; exit 1; }
"$APP/Contents/MacOS/DownloadMoreRAM" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
sleep 20
mkdir -p bench
build/Products.noindex/bin/ram measure $PID --seconds $SECONDS_TO_MEASURE | tee bench/app-budget.json
