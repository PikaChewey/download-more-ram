#!/bin/zsh
# Memory gate for heavy runs (integration tests, benches) so they never push this Mac into the
# out-of-memory wall.
#   scripts/memory-gate.sh          exit 0 when kern.memorystatus_level >= 20 and pressure != critical
#   scripts/memory-gate.sh --abort  exit 0 unless kern.memorystatus_level < 10 or pressure is critical
# Prints "level=<n> pressure=<n> swap_used=<MB>". Swap size alone is not a gate: macOS grows it on demand.
level=$(sysctl -n kern.memorystatus_level)
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)
swap_used=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')
echo "level=$level pressure=$pressure swap_used=${swap_used}MB"
if [[ ${1:-} == --abort ]]; then
  (( level >= 10 && pressure != 4 ))
  exit $?
fi
(( level >= 20 && pressure != 4 ))
