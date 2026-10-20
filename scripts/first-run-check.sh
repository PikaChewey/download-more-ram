#!/bin/zsh
# S7: time to value. Installs into a scratch prefix, checks the helper answers (installing it is the
# one password step, done once by the user), makes one real download, and times `ram doctor --fast`.
# Writes bench/first-run.json.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
scripts/install.sh --apps "$TMP/Applications" --bin "$TMP/bin" >/dev/null       # command 1
RAM="$TMP/bin/ram"
"$RAM" helper status | grep -q "installed, version" || { echo "helper missing: sudo ram helper install" >&2; exit 1; }   # command 2 (done once)
RECEIPTS="$HOME/Library/Application Support/DownloadMoreRAM/receipts"
before=$(ls "$RECEIPTS" 2>/dev/null | wc -l | tr -d ' ')
"$RAM" download --hold 3 >/dev/null                                             # command 3
after=$(ls "$RECEIPTS" 2>/dev/null | wc -l | tr -d ' ')
t0=$(python3 -c 'import time; print(time.time())')
"$RAM" doctor --fast >/dev/null
t1=$(python3 -c 'import time; print(time.time())')
mkdir -p bench
python3 - "$before" "$after" "$t0" "$t1" <<'PY' | tee bench/first-run.json
import json,sys
b,a,t0,t1=int(sys.argv[1]),int(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])
print(json.dumps({"commands":3,"receipt_created":a>b,"doctor_fast_s":round(t1-t0,3)}, indent=2))
PY
