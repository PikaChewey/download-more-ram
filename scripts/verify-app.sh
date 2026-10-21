#!/bin/zsh
# Proves the INSTALLED app frees memory, judged by the kernel's own counters:
#   1. a control window with no download (natural drift),
#   2. the app's own download (exactly what its button does, via --download-now <levers>),
#   3. the same counters 60 s after the receipt, the app's pid in the helper's log, the receipt.
# Writes bench/results/<timestamp>-app-verify.json. Levers default to firefox-gpu (pre-approved here).
#   scripts/verify-app.sh [levers]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="/Applications/Download More RAM.app"
RAM="$APP/Contents/Helpers/ram"
LEVERS=${1:-firefox-gpu}
WINDOW=60
RECEIPTS="$HOME/Library/Application Support/DownloadMoreRAM/receipts"
[[ -x $RAM ]] || { echo "install the app first: scripts/install.sh" >&2; exit 1; }
"$RAM" helper status | grep -q "installed, version" || { echo "the helper is not installed" >&2; exit 1; }
sample() { "$RAM" status --json | python3 -c '
import json,sys,time; d=json.load(sys.stdin); s=d["system"]
app=max(0,s["anonymousBytes"]-s["purgeableBytes"])
used=app+s["wiredBytes"]+s["compressorOccupiedBytes"]       # Activity Monitor "Memory Used" (physical)
demand=app+s["wiredBytes"]+s["compressedUncompressedBytes"]  # what apps hold, counting compressed data at full size
print(json.dumps({"t":time.time(),"memoryUsed":used,"demand":demand,"compressedData":s["compressedUncompressedBytes"],"swapUsed":s["swapUsed"],"compressed":s["compressorOccupiedBytes"],"wall":d["wall"]["percent"],"pressure":s["pressureLevel"]}))'; }

pkill -x DownloadMoreRAM 2>/dev/null || true
sleep 2
print "control: ${WINDOW}s with no download"
c0=$(sample); sleep $WINDOW; c1=$(sample)

before_receipts=$(ls "$RECEIPTS" 2>/dev/null | grep -c '\.json$' || true)
start_iso=$(date '+%Y-%m-%d %H:%M:%S')
print "app: downloading with levers: $LEVERS"
a0=$(sample)
open -a "$APP" --args --download-now "$LEVERS"
sleep 1
APP_PID=$(pgrep -x DownloadMoreRAM | tail -1)
receipt=""
for i in {1..120}; do
  newest=$(ls -t "$RECEIPTS"/*.json 2>/dev/null | head -1)
  count=$(ls "$RECEIPTS" 2>/dev/null | grep -c '\.json$' || true)
  if (( count > before_receipts )); then receipt=$newest; break; fi
  sleep 1
done
[[ -n $receipt ]] || { echo "the app did not finish a download within 120 s" >&2; exit 1; }
a1=$(sample); sleep $WINDOW; a2=$(sample)
helper_lines=$(/usr/bin/log show --start "$start_iso" --style compact \
  --predicate 'subsystem == "ca.bryanyao.DownloadMoreRAM.helper" AND eventMessage CONTAINS "relief from pid"' 2>/dev/null | grep "relief from pid" || true)

mkdir -p bench/results
out="bench/results/$(date +%Y-%m-%dT%H-%M-%S)-app-verify.json"
python3 - "$out" "$receipt" "$APP_PID" "$LEVERS" "$c0" "$c1" "$a0" "$a1" "$a2" "$helper_lines" <<'PY'
import json,sys
out,receipt_path,pid,levers=sys.argv[1:5]
c0,c1,a0,a1,a2=[json.loads(x) for x in sys.argv[5:10]]
helper=[l for l in sys.argv[10].splitlines() if l.strip()]
r=json.load(open(receipt_path))
G=2**30
span=a2["t"]-a0["t"]
def beyond(key):  # change over the download window minus the control window's drift over the same time
    drift=(c1[key]-c0[key])/(c1["t"]-c0["t"])
    return round((a2[key]-a0[key])-drift*span)
effect=beyond("memoryUsed")
b,a=r["systemBefore"],r["systemAfter"]
def demand(x): return max(0,x["anonymousBytes"]-x["purgeableBytes"])+x["wiredBytes"]+x["compressedUncompressedBytes"]
def used(x): return max(0,x["anonymousBytes"]-x["purgeableBytes"])+x["wiredBytes"]+x["compressorOccupiedBytes"]
res={
 "app_pid": int(pid), "levers": levers, "receipt": receipt_path.split("/")[-1],
 "receipt_backend": r["backend"], "receipt_headline_bytes": r["headlineBytes"],
 "receipt_levers": [{"kind":l["kind"],"bytes":l.get("bytes")} for l in r.get("levers") or []],
 "helper_log_mentions_app_pid": any(f"relief from pid {pid}:" in l for l in helper),
 "helper_log": helper,
 "control": {"seconds": round(c1["t"]-c0["t"],1), "memory_used_change": c1["memoryUsed"]-c0["memoryUsed"],
             "swap_change": c1["swapUsed"]-c0["swapUsed"], "wall": [c0["wall"],c1["wall"]]},
 "download": {"seconds": round(span,1), "memory_used_change": a2["memoryUsed"]-a0["memoryUsed"],
              "swap_change": a2["swapUsed"]-a0["swapUsed"], "compressed_change": a2["compressed"]-a0["compressed"],
              "wall": [a0["wall"],a1["wall"],a2["wall"]]},
 "memory_used_effect_beyond_drift": effect,
 "memory_demand_effect_beyond_drift": beyond("demand"),
 "compressed_data_effect_beyond_drift": beyond("compressedData"),
 "receipt_window": {"seconds": round(r["durationS"],1), "memory_demand_change": demand(a)-demand(b),
                    "compressed_data_change": a["compressedUncompressedBytes"]-b["compressedUncompressedBytes"],
                    "memory_used_change": used(a)-used(b), "wired_change": a["wiredBytes"]-b["wiredBytes"]},
 "samples": {"control":[c0,c1],"download":[a0,a1,a2]},
}
json.dump(res,open(out,"w"),indent=1)
w=res["receipt_window"]
print(f"receipt {r['headlineBytes']/G:+.2f} GB ({res['receipt_backend']}); during it: memory demand {w['memory_demand_change']/G:+.2f} GB, "
      f"compressed data {w['compressed_data_change']/G:+.2f} GB, Memory Used {w['memory_used_change']/G:+.2f} GB")
print(f"beyond control drift over {span:.0f}s: demand {res['memory_demand_effect_beyond_drift']/G:+.2f} GB, Memory Used {effect/G:+.2f} GB; "
      f"helper saw app pid: {res['helper_log_mentions_app_pid']}")
print("saved", out)
PY
