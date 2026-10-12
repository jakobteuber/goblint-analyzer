#!/usr/bin/env bash
# Measure how long solvers take to solve, using the "solve" timing section of td_simplified_ref, td_worklist and td_parallel_base
# (the solver loop without the postsolver, printed with dbg.timing.enabled).
# Each input is analyzed RUNS times with each solver. The runs are sequential and interleaved (all solvers in run 1, then in run 2, ...),
# so that other load on the machine affects all solvers alike. Timing itself adds some overhead to all solvers.
#
# Usage: ./scripts/solver_timing.sh input ...
#   input: a C file, or an SV-COMP task definition (*.yml, see scripts/solver_work.sh for downloading them),
#          which is run with $SVCOMP_CONF, the task's data model and the property $SVCOMP_PROPERTY.
#   E.g.: ./scripts/solver_timing.sh sv-benchmarks/c/pthread-driver-races/char_pc8736x_gpio_pc8736x_gpio_configure_pc8736x_gpio_current.yml
#
# Environment variables:
#   SOLVERS  solvers to run, the first one is the baseline of the report
#            (default: "td_simplified_ref td_worklist_lifo td_worklist_fifo td_parallel_base")
#            td_parallel_base uses the thread pool mock chosen at build time, see GOBLINT_THREADPOOL_MOCK in src/util/parallel/dune.
#   RUNS     number of runs per input and solver (default: 5)
#   TIMEOUT  seconds per run (default: 300)
#   OUT      output directory (default: tests/suite_result/solver_timing)
#   gobopt   extra Goblint options
#   SVCOMP_CONF      configuration for SV-COMP tasks (default: conf/svcomp23.json)
#   SVCOMP_PROPERTY  property file for SV-COMP tasks, relative to the task directory (default: ../properties/no-data-race.prp)
#
# Output:
#   $OUT/timing.csv   one row per input, solver and run: status (ok, timeout, error), CPU and wall time of solve in seconds
#   $OUT/report.txt   per input and solver: median, min and max wall time, spread and median relative to the baseline, also printed
#   $OUT/logs/        Goblint's output per input, solver and run

set -u

SOLVERS=(${SOLVERS:-td_simplified_ref td_worklist_lifo td_worklist_fifo td_parallel_base})
RUNS=${RUNS:-5}
TIMEOUT=${TIMEOUT:-300}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "${OUT:-$ROOT/tests/suite_result/solver_timing}")
GOBLINT="$ROOT/goblint"
SVCOMP_CONF=$(realpath "${SVCOMP_CONF:-$ROOT/conf/svcomp23.json}")
SVCOMP_PROPERTY=${SVCOMP_PROPERTY:-../properties/no-data-race.prp}

if [ ! -x "$GOBLINT" ]; then
  echo "Goblint not found at $GOBLINT, build it with ./make.sh nat first." >&2
  exit 1
fi
if [ $# -eq 0 ]; then
  echo "Usage: $0 input ..." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/logs"
CSV="$OUT/timing.csv"
echo "input,solver,run,status,cputime,walltime" > "$CSV"

echo "Running ${#SOLVERS[@]} solver(s) $RUNS time(s) on $# input(s), results in $OUT"

for run in $(seq 1 "$RUNS"); do
  for arg in "$@"; do
    file=$(realpath "$arg")
    if [[ $file == *.yml ]]; then
      # SV-COMP task: analyze its input file with the SV-COMP configuration, for the task's data model.
      input=$(grep -oP "^input_files: *'?\K[^' ]+" "$file" | head -n 1)
      arch=32bit
      grep -q "data_model: *LP64" "$file" && arch=64bit
      params="--conf $SVCOMP_CONF --set ana.specification $SVCOMP_PROPERTY --set exp.architecture $arch"
      name=$(basename "$file" .yml)
    else
      input=$(basename "$file")
      params=""
      name=$(basename "$file" .c)
    fi
    for solver in "${SOLVERS[@]}"; do
      log="$OUT/logs/$name.$solver.$run.log"
      # Run in the input's directory, as the property file of SV-COMP tasks is relative to it.
      (cd "$(dirname "$file")" &&
        eval timeout "$TIMEOUT" "$GOBLINT" "$input" "$params" \
          --set solver "$solver" --enable dbg.timing.enabled \
          --set goblint-dir "$OUT/goblint-dir" "${gobopt:-}") > "$log" 2>&1
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
      echo "$name,$solver,$run,$status,$times" >> "$CSV"
      echo "run $run/$RUNS  $name  $solver  $status ${times#*,}"
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
# Median of the wall times of input i and solver s.
function median(i, s,   c, a, j, x, y) {
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
    printf "  %-22s %4s %10s %10s %10s %8s %10s\n", "solver", "runs", "median", "min", "max", "spread", "vs. base"
    bm = cnt[i, base] ? median(i, base) : 0
    for (k = 1; k <= n; k++) {
      s = S[k]
      if (!cnt[i, s]) { printf "  %-22s %4d failed\n", s, 0; continue }
      md = median(i, s)
      printf "  %-22s %4d %9.3fs %9.3fs %9.3fs %7.1f%% %9.1f%%", s, cnt[i, s], md, lo, hi, (md > 0 ? 100 * (hi - lo) / md : 0), (bm > 0 ? 100 * md / bm : 0)
      if (failed[i, s]) printf "  (%d failed)", failed[i, s]
      print ""
    }
    print ""
  }
}' "$CSV" | tee "$OUT/report.txt"
