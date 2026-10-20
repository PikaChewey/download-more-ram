#!/bin/zsh
# Runs the real-machine validation once the helper is installed (NEEDS_HUMAN H1):
#   1. synthetic: pressure-aware vs pressure-ignoring fixtures (mechanism proof, 3 trials)
#   2. real: this Mac's running apps, relief vs control (5 trials)
#   3. perf: 1 GiB foreground workload after relief vs after control (5 trials)
#   4. a recorded real download -> docs/demo.svg + the README demo block
#   5. bench report -> docs/BENCHMARKS.md + README numbers
# Each step is memory-gated; the helper's rate limit (>= 20 s apart, <= 30/h) is respected by the
# 60 s cooldowns (13-14 signals in total).
set -euo pipefail
cd "$(dirname "$0")/.."
RAM=build/Products.noindex/bin/ram
[[ -x $RAM ]] || scripts/build.sh
$RAM helper status
mkdir -p bench/results bench/logs

gate() {
  until scripts/memory-gate.sh >/dev/null; do echo "waiting for memory to recover ($(scripts/memory-gate.sh))"; sleep 30; done
}

# The real-apps bench allocates nothing, so it runs under the bench's own gate (>= 15% available,
# not critical). The fixture and workload benches allocate ~1 GiB and wait for >= 20%.
$RAM bench real --trials 5 2>&1 | tee bench/logs/real.log
gate; $RAM bench synthetic --trials 3 --hogs 2 --mb 256 2>&1 | tee bench/logs/synthetic.log
gate; $RAM bench perf --trials 5 --mb 1024 2>&1 | tee bench/logs/perf.log

gate; sleep 60
$RAM download --record bench/results/demo-recording.json 2>&1 | tee bench/logs/demo.log
python3 scripts/make-demo-svg.py bench/results/demo-recording.json docs/demo.svg

# README demo block: the plain-text receipt of that same run.
python3 - <<'PY'
import json, re
rec = json.load(open("bench/results/demo-recording.json"))["receipt"]
def gib(b):
    v = abs(b); s = "-" if b < 0 else ""
    return f"{s}{v/1024**3:.2f} GB" if v >= 1024**3 * 0.9995 else f"{s}{v/1024**2:.1f} MB"
apps = [a for a in rec["apps"] if a["before"] - a["after"] > 0][:5]
lines = [f"✓ Downloaded {gib(rec['headlineBytes'])} of RAM in {round(rec['durationS'])}s ({rec['machine']['chip']}, {rec['machine']['memoryBytes']//1024**3} GB)", ""]
lines += [f"  {a['name'][:22]:<22} {'+' + gib(a['before'] - a['after']):>10}" for a in apps]
block = "<!-- DEMO:BEGIN -->\n```\n" + "\n".join(lines) + "\n```\n<!-- DEMO:END -->"
readme = open("README.md").read()
readme = re.sub(r"<!-- DEMO:BEGIN -->.*?<!-- DEMO:END -->", lambda m: block, readme, flags=re.S)
open("README.md", "w").write(readme)
print("README demo block updated")
PY

$RAM bench report
echo "Validation complete. Review docs/BENCHMARKS.md and README.md, then commit."
