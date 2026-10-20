#!/bin/zsh
# One command from a clone to a working install: build and sign everything, put the menu bar app in
# Applications and `ram` on your PATH. The root helper is the one step that needs your password:
# the script prints the command (it never runs sudo itself).
#
#   scripts/install.sh                     -> /Applications + ~/.local/bin/ram
#   scripts/install.sh --apps DIR --bin DIR (used by scripts/first-run-check.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
APPS=/Applications
BIN=$HOME/.local/bin
while (( $# )); do
  case $1 in
    --apps) APPS=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    *) echo "usage: scripts/install.sh [--apps DIR] [--bin DIR]" >&2; exit 2 ;;
  esac
done
scripts/build.sh >/dev/null
APP="build/Products.noindex/Download More RAM.app"
[[ -d $APP ]] || { echo "the app did not build" >&2; exit 1; }
mkdir -p "$APPS" "$BIN"
rm -rf "$APPS/Download More RAM.app"
cp -R "$APP" "$APPS/"
ln -sf "$APPS/Download More RAM.app/Contents/Helpers/ram" "$BIN/ram"
print "Installed $APPS/Download More RAM.app and $BIN/ram"
if ! "$BIN/ram" helper status 2>/dev/null | grep -q "installed, version"; then
  print "\nOne step needs your password (downloads use macOS's root-only memory-pressure switch):\n  sudo $BIN/ram helper install"
fi
print "\nThen:\n  ram doctor\n  ram download"
case ":$PATH:" in *":$BIN:"*) ;; *) print "\n(add $BIN to your PATH to type plain \`ram\`)" ;; esac
