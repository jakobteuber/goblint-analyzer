#!/usr/bin/env bash
# Measure how long solvers take to solve, using the "solve" timing section of td_simplified_ref and td_worklist
# (the solver loop without the postsolver, printed with dbg.timing.enabled).
# Each input is analyzed RUNS times with each solver. The runs are sequential and interleaved (all solvers in run 1, then in run 2, ...),
# so that other load on the machine affects all solvers alike. Timing itself adds some overhead to all solvers.
#
# Random orders: td_worklist_random runs with fixed seeds, one series per seed (td_worklist_random#<seed>).
# The RUNS repetitions of a seed are the same order, so their median is meaningful; different seeds are different orders
# and are not averaged. The report gives each seed's median, and the fastest and slowest seed.
#
# Usage: ./scripts/solver_timing.sh input ...
#   input: a C file (analyzed with its PARAM line, if it has one), or an SV-COMP task definition
#          (*.yml, see scripts/solver_work.sh for downloading them), which is run with $SVCOMP_CONF,
#          the task's data model and the property $SVCOMP_PROPERTY.
#   E.g.: ./scripts/solver_timing.sh sv-benchmarks/c/pthread-driver-races/char_pc8736x_gpio_pc8736x_gpio_configure_pc8736x_gpio_current.yml
#
# Environment variables:
#   SOLVERS  solvers to run, the first one is the baseline of the report (default: DEFAULT_SOLVERS in scripts/solver_lib.sh)
#            A solver can be given several times with a label after #; for td_worklist_random, the label is the seed.
#   RANDOM_RUNS   number of random orders: td_worklist_random#1 ... are added to SOLVERS (default: 5)
#   RANDOM_SEEDS  the seeds of the random orders instead (default: 1 ... RANDOM_RUNS)
#   RUNS     number of runs per input and solver (default: 5)
#   TIMEOUT  seconds per run (default: 300)
#   OUT      output directory (default: tests/suite_result/solver_timing)
#   gobopt   extra Goblint options
#   GOBLINT  Goblint binary (default: ./goblint)
#   SVCOMP_CONF      configuration for SV-COMP tasks (default: conf/svcomp23.json)
#   SVCOMP_PROPERTY  property file for SV-COMP tasks, relative to the task directory (default: ../properties/no-data-race.prp)
#
# Output:
#   $OUT/timing.csv   one row per input, solver and run: status (ok, timeout, error), CPU and wall time of solve in seconds
#   $OUT/report.txt   per input and solver: median, min and max wall time, spread and median relative to the baseline,
#                     and for the random orders the fastest and slowest seed; also printed
#   $OUT/dataset.txt  description of the inputs, for the plots
#   $OUT/logs/        Goblint's output per input, solver and run

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/scripts/solver_lib.sh"
init_solvers
init_common
RUNS=${RUNS:-5}
TIMEOUT=${TIMEOUT:-300}
OUT=$(realpath -m "${OUT:-$ROOT/tests/suite_result/solver_timing}")

if [ $# -eq 0 ]; then
  echo "Usage: $0 input ..." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/logs"
CSV="$OUT/timing.csv"
echo "input,solver,run,status,cputime,walltime" > "$CSV"
names=()
for arg in "$@"; do
  names+=("$(basename "${arg%.*}")")
done
echo "${names[*]} ($# inputs)" > "$OUT/dataset.txt"

echo "Running ${#SOLVERS[@]} solver(s) $RUNS time(s) on $# input(s), results in $OUT"

for run in $(seq 1 "$RUNS"); do
  for arg in "$@"; do
    file=$(realpath "$arg")
    task_params "$file"
    for solver in "${SOLVERS[@]}"; do
      log="$OUT/logs/$test.$solver.$run.log"
      # Run in the input's directory, as the property file of SV-COMP tasks and PARAMs of regression tests are relative to it.
      (cd "$(dirname "$file")" &&
        eval timeout "$TIMEOUT" "$GOBLINT" "$input" "$params" \
          $(solver_args "$solver") --enable dbg.timing.enabled \
          --set goblint-dir "'$OUT/goblint-dir'" "${gobopt:-}") > "$log" 2>&1
      exit_code=$?
      # The section is printed as: name, CPU time, wall time, allocated memory, count.
      times=$(grep -oP "^\s+solve\s+\K[0-9.]+s\s+[0-9.]+s" "$log" | head -n 1 | sed 's/s\s\+/,/; s/s$//')
      if [ $exit_code -eq 124 ]; then
        status=timeout
      elif [ $exit_code -ne 0 ] || [ -z "$times" ]; then
        status=error
      else
        status=ok
      fi
      [ $status = ok ] || times=","
      echo "$test,$solver,$run,$status,$times" >> "$CSV"
      echo "run $run/$RUNS  $test  $solver  $status ${times#*,}"
    done
  done
done
rm -rf "$OUT/goblint-dir"

# Medians are robust against single slow runs. The spread (max - min) / median shows how reproducible the times are.
echo
awk -F, -v solvers="${SOLVERS[*]}" '
BEGIN { n = split(solvers, S, " "); base = S[1] }
NR > 1 {
  if (!($1 in seen)) { seen[$1] = 1; inputs[++m] = $1 }
  if ($4 == "ok") { k = ++cnt[$1, $2]; t[$1, $2, k] = $6 } else failed[$1, $2]++
}
# Median of the wall times of input i and solver s; also sets lo and hi.
function median(i, s,   c, a, j, x, y, tmp) {
  c = cnt[i, s]
  for (j = 1; j <= c; j++) a[j] = t[i, s, j]
  for (x = 2; x <= c; x++) for (y = x; y > 1 && a[y - 1] > a[y]; y--) { tmp = a[y]; a[y] = a[y - 1]; a[y - 1] = tmp }
  lo = a[1]; hi = a[c]
  return c % 2 ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2
}
END {
  for (j = 1; j <= m; j++) {
    i = inputs[j]
    print i
    printf "  %-34s %4s %10s %10s %10s %8s %10s\n", "solver", "runs", "median", "min", "max", "spread", "vs. base"
    bm = cnt[i, base] ? median(i, base) : 0
    seeds = 0
    for (k = 1; k <= n; k++) {
      s = S[k]
      if (!cnt[i, s]) { printf "  %-34s %4d failed\n", s, 0; continue }
      md = median(i, s)
      printf "  %-34s %4d %9.3fs %9.3fs %9.3fs %7.1f%% %9.1f%%", s, cnt[i, s], md, lo, hi, (md > 0 ? 100 * (hi - lo) / md : 0), (bm > 0 ? 100 * md / bm : 0)
      if (failed[i, s]) printf "  (%d failed)", failed[i, s]
      print ""
      if (s ~ /^td_worklist_random#/) {
        seeds++
        if (seeds == 1 || md < fast) { fast = md; fast_s = s }
        if (seeds == 1 || md > slow) { slow = md; slow_s = s }
      }
    }
    if (seeds > 1)
      printf "  random orders: medians from %.3fs (%s) to %.3fs (%s), i.e. the slowest order takes %.1f%% of the fastest\n", fast, fast_s, slow, slow_s, (fast > 0 ? 100 * slow / fast : 0)
    print ""
  }
}' "$CSV" | tee "$OUT/report.txt"
