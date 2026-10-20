#!/bin/zsh
# Builds and signs Download More RAM.
#
#   scripts/build.sh            release build: build/Products.noindex/bin/{ram,ram-helper,ram-fixture}
#                               and, once the app target exists, build/Products.noindex/Download More RAM.app
#   scripts/build.sh --debug    debug build
#
# Signs with your Apple Development identity when one exists (the helper then only accepts callers
# signed by the same team), else ad hoc. codesign runs under a 120 s watchdog: if it hangs (a keychain
# dialog is waiting) that codesign is stopped and the binary is signed ad hoc instead.
# Holds the machine-wide build lock (one heavy Swift job at a time on a 16 GB Mac).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z ${BRYAN_BUILD_LOCK_HELD:-} ]]; then
  exec scripts/with-build-lock.sh "$0" "$@"
fi

CONFIG=release
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=debug ;;
    *) echo "usage: scripts/build.sh [--debug]" >&2; exit 2 ;;
  esac
done

IDENTITY=${RAM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
IDENTITY=${IDENTITY:--}

swift build -c $CONFIG --arch arm64 -j 2
BIN=.build/arm64-apple-macosx/$CONFIG
OUT=${RAM_BUILD_OUT:-build/Products.noindex}
mkdir -p $OUT/bin
cp $BIN/ram $BIN/ram-helper $BIN/ram-fixture $OUT/bin/

# One codesign under a 120 s watchdog: 0 ok, 1 failed, 124 stopped by the watchdog.
signed_with_watchdog() {
  "$@" &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    if (( waited >= 1200 )); then
      kill -TERM $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    (( waited += 1 ))
  done
  wait $pid
}

sign() {
  local identity=$1 id=$2 file=$3
  local cmd=(codesign --force --sign "$identity" --timestamp=none --identifier "$id")
  [[ $identity != "-" ]] && cmd+=(--options runtime)
  if ! signed_with_watchdog $cmd "$file"; then
    echo "codesign with '$identity' failed for $file; signing ad hoc" >&2
    codesign --force --sign - --identifier "$id" "$file"
  fi
}

sign "$IDENTITY" ca.bryanyao.DownloadMoreRAM.cli $OUT/bin/ram
sign "$IDENTITY" ca.bryanyao.DownloadMoreRAM.helper $OUT/bin/ram-helper
sign "$IDENTITY" ca.bryanyao.DownloadMoreRAM.fixture $OUT/bin/ram-fixture

if [[ -d Sources/RAMApp && -f $BIN/DownloadMoreRAM ]]; then
  APP="$OUT/Download More RAM.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
  cp $BIN/DownloadMoreRAM "$APP/Contents/MacOS/DownloadMoreRAM"
  cp $OUT/bin/ram $OUT/bin/ram-helper "$APP/Contents/Helpers/"
  VERSION=$(grep -m1 'let version' Sources/RAMCLI/main.swift | sed -E 's/.*"(.*)".*/\1/')
  BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
  [[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  sign "$IDENTITY" ca.bryanyao.DownloadMoreRAM.cli "$APP/Contents/Helpers/ram"
  sign "$IDENTITY" ca.bryanyao.DownloadMoreRAM.helper "$APP/Contents/Helpers/ram-helper"
  sign "$IDENTITY" ca.bryanyao.DownloadMoreRAM "$APP"
  echo "app: $APP"
fi

echo "signed with: $IDENTITY"
ls -la $OUT/bin
