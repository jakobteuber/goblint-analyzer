#!/usr/bin/env bash
# Report how much work solvers do on the regression tests, measured by the number of calls to eval and iterate
# and the number of right-hand side evaluations
# (logged as "solver work: eval = ..., iterate = ..., rhs = ..." by td_simplified_ref, td_worklist and td_parallel_base).
# Right-hand side evaluations are the most comparable between solvers: td_simplified_ref also calls iterate on stable unknowns,
# where it returns immediately, while the other solvers only iterate unstable ones.
#
# Usage: ./scripts/solver_work.sh [group | task-directory ...]
#   group:          regression test group directories to restrict to, e.g. 04-mutex (default: all of tests/regression)
#   task-directory: a directory with SV-COMP task definitions (*.yml), e.g. sv-benchmarks/c/pthread.
#                   Each task is run with $SVCOMP_CONF, the task's data model and the property $SVCOMP_PROPERTY.
#                   The SV-COMP 2023 concurrency tasks can be downloaded (into the gitignored sv-benchmarks/) with:
#                     git clone --depth 1 --branch svcomp23 --filter=blob:none --sparse \
#                       https://gitlab.com/sosy-lab/benchmarking/sv-benchmarks.git sv-benchmarks
#                     git -C sv-benchmarks sparse-checkout set c/properties c/pthread c/pthread-atomic c/pthread-ext \
#                       c/pthread-wmm c/pthread-lit c/ldv-races c/ldv-linux-3.14-races c/pthread-complex \
#                       c/pthread-driver-races c/pthread-C-DAC c/pthread-divine c/pthread-nondet c/goblint-regression \
#                       c/weaver c/pthread-deagle
#
# Environment variables:
#   SOLVERS  solvers to run (from those above), the first one is the baseline of the report
#            (default: DEFAULT_SOLVERS in scripts/solver_lib.sh)
#            A solver can be given several times with a label after #, to run it repeatedly; for td_worklist_random,
#            the label is the seed. Per test, these runs are aggregated into the best and the worst one by rhs
#            (e.g. td_worklist_random#best and td_worklist_random#worst), which are reported as if they were solvers:
#            they show how much can be gained or lost by the order alone, and become more pronounced with more runs.
#            The worst run of a test is a failed one (timeout, error) if any run failed, the best one only if all failed.
#   RANDOM_RUNS   number of random orders: td_worklist_random#1 ... are added to SOLVERS (default: 5)
#   RANDOM_SEEDS  the seeds of the random orders instead (default: 1 ... RANDOM_RUNS)
#   JOBS     number of parallel Goblint runs (default: nproc)
#   TIMEOUT  seconds per run, i.e. per test and solver (default: 120)
#   OUT      output directory (default: tests/suite_result/solver_work)
#   gobopt   extra Goblint options, appended after the test's PARAM
#   GOBLINT  Goblint binary (default: ./goblint)
#   SVCOMP_CONF      configuration for SV-COMP tasks (default: conf/svcomp23.json)
#   SVCOMP_PROPERTY  property file for SV-COMP tasks, relative to the task directory (default: ../properties/no-data-race.prp)
#
# Output:
#   $OUT/work.csv     one row per test and solver: status (ok, timeout, error), eval and iterate calls, right-hand side evaluations;
#                     with the labelled runs replaced by their best and worst run
#   $OUT/work_runs.csv  as work.csv, but with every labelled run, if there were any
#   $OUT/report.txt   totals per solver and the comparison with the baseline, also printed at the end
#   $OUT/dataset.txt  description of the inputs, for the plots
#   $OUT/logs/        Goblint's output per test and solver

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/scripts/solver_lib.sh"
init_solvers
init_common
# The solvers of work.csv and the report: labelled runs of a solver are replaced by its best and worst run.
REPORT_SOLVERS=()
declare -A LABELLED_RUNS
for solver in "${SOLVERS[@]}"; do
  if [[ $solver == *#* ]]; then
    solver=${solver%%#*}
    LABELLED_RUNS[$solver]=$((${LABELLED_RUNS[$solver]:-0} + 1))
    [[ " ${REPORT_SOLVERS[*]} " == *" $solver#best "* ]] || REPORT_SOLVERS+=("$solver#best" "$solver#worst")
  else
    REPORT_SOLVERS+=("$solver")
  fi
done
TIMEOUT=${TIMEOUT:-120}
OUT=$(realpath -m "${OUT:-$ROOT/tests/suite_result/solver_work}")

rm -rf "$OUT"
mkdir -p "$OUT/logs" "$OUT/rows" "$OUT/goblint-dirs"
discover_tests "$@"

echo "Running ${#SOLVERS[@]} solver(s) on ${#TESTS[@]} tests with $JOBS jobs, results in $OUT"

# Runs one test with one solver and writes one CSV row.
# Arguments: test file, solver
run_one() {
  local file=$1 solver=$2
  local log status work
  task_params "$file"
  log="$OUT/logs/$group-$test.$solver.log"

  # PARAMs may refer to files relative to the test, so run in the test's directory (as update_suite.rb does).
  (cd "$(dirname "$file")" &&
    eval timeout "$TIMEOUT" "$GOBLINT" "$input" "$params" \
      $(solver_args "$solver") \
      --set goblint-dir "'$OUT/goblint-dirs/$group-$test.$solver'" "${gobopt:-}") > "$log" 2>&1
  local exit_code=$?
  rm -rf "$OUT/goblint-dirs/$group-$test.$solver"

  work=$(grep -oP "^\[Info\] solver work: eval = \K[0-9]+, iterate = [0-9]+, rhs = [0-9]+" "$log" | head -n 1 | sed 's/, [a-z]* = /,/g')
  if [ $exit_code -eq 124 ]; then
    status=timeout
  elif [ $exit_code -ne 0 ] || [ -z "$work" ]; then
    status=error
  else
    status=ok
  fi
  [ $status = ok ] || work=",,"
  echo "$id,$solver,$status,$work" > "$OUT/rows/$group-$test.$solver.csv"
}
export -f run_one
export OUT TIMEOUT GOBLINT SVCOMP_CONF SVCOMP_PROPERTY
export gobopt="${gobopt:-}"

for f in "${TESTS[@]}"; do
  for solver in "${SOLVERS[@]}"; do
    echo "$f $solver"
  done
done | xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _

rmdir "$OUT/goblint-dirs" 2>/dev/null

{
  echo "test,solver,status,eval,iterate,rhs"
  find "$OUT/rows" -name "*.csv" -exec cat {} + | sort
} > "$OUT/work_runs.csv"
rm -rf "$OUT/rows"

# Replace the labelled runs of each solver and test by the best and the worst one.
# The whole row of the chosen run is kept, so that eval, iterate and rhs are from the same run.
awk -F, -v OFS=, '
NR == 1 { print; next }
$2 !~ /#/ { print; next }
{
  solver = $2; sub(/#.*/, "", solver); k = $1 SUBSEP solver; keys[k] = 1
  if ($3 == "ok") {
    if (!(k in best) || $6 + 0 < best_rhs[k]) { best[k] = $0; best_rhs[k] = $6 + 0 }
    if (!(k in failed) && (!(k in worst) || $6 + 0 > worst_rhs[k])) { worst[k] = $0; worst_rhs[k] = $6 + 0 }
  } else if (!(k in failed)) {
    failed[k] = $0; worst[k] = $0
  }
}
function emit(row, solver) { $0 = row; $2 = solver; print }
END {
  for (k in keys) {
    split(k, p, SUBSEP)
    emit(k in best ? best[k] : failed[k], p[2] "#best")
    emit(worst[k], p[2] "#worst")
  }
}' "$OUT/work_runs.csv" | { read -r header; echo "$header"; sort; } > "$OUT/work.csv"
# Without labelled runs, work_runs.csv is the same as work.csv.
cmp -s "$OUT/work.csv" "$OUT/work_runs.csv" && rm "$OUT/work_runs.csv"

# The report only uses tests on which all solvers succeeded, so that the totals are comparable.
{
  for solver in "${!LABELLED_RUNS[@]}"; do
    seeds=""
    [ "$solver" = td_worklist_random ] && seeds=" (seeds $RANDOM_SEEDS)"
    echo "$solver#best and $solver#worst: per test, the best and the worst of ${LABELLED_RUNS[$solver]} runs of $solver$seeds by rhs"
  done
awk -F, -v solvers="${REPORT_SOLVERS[*]}" '
BEGIN { n = split(solvers, S, " "); base = S[1]; M[1] = "rhs"; M[2] = "eval+iter" }
NR > 1 {
  tests[$1] = 1
  status[$1, $2] = $3
  ev[$1, $2] = $4; it[$1, $2] = $5; rhs[$1, $2] = $6
  if ($3 != "ok") failed[$2]++
}
# Value of metric m for test t and solver s.
function work(m, t, s) { return m == "rhs" ? rhs[t, s] : ev[t, s] + it[t, s] }
END {
  for (t in tests) {
    all_ok = 1
    for (i = 1; i <= n; i++) if (status[t, S[i]] != "ok") all_ok = 0
    if (!all_ok) continue
    common++
    for (i = 1; i <= n; i++) {
      s = S[i]
      sum_ev[s] += ev[t, s]; sum_it[s] += it[t, s]; sum_rhs[s] += rhs[t, s]
      if (i == 1) continue
      for (j = 1; j <= 2; j++) {
        m = M[j]; w = work(m, t, s); b = work(m, t, base)
        if (b > 0 && w > 0) { log_ratio[m, s] += log(w / b); ratios[m, s]++ }
        if (w < b) less[m, s]++; else if (w > b) more[m, s]++; else same[m, s]++
        d = w - b
        if (!((m, s) in max_d) || d > max_d[m, s]) { max_d[m, s] = d; max_t[m, s] = t }
        if (!((m, s) in min_d) || d < min_d[m, s]) { min_d[m, s] = d; min_t[m, s] = t }
      }
    }
  }
  printf "Tests on which all solvers succeeded: %d\n", common
  for (i = 1; i <= n; i++) if (failed[S[i]] > 0) printf "  %s failed (error/timeout) on %d test(s)\n", S[i], failed[S[i]]
  print ""
  printf "%-34s %12s %10s %12s %12s %12s %10s\n", "solver", "rhs", "vs. base", "eval", "iterate", "eval+iter", "vs. base"
  for (i = 1; i <= n; i++) {
    s = S[i]
    total = sum_ev[s] + sum_it[s]; btotal = sum_ev[base] + sum_it[base]
    printf "%-34s %12d %9.1f%% %12d %12d %12d %9.1f%%\n", s, sum_rhs[s], (sum_rhs[base] > 0 ? 100 * sum_rhs[s] / sum_rhs[base] : 0), sum_ev[s], sum_it[s], total, (btotal > 0 ? 100 * total / btotal : 0)
  }
  for (j = 1; j <= 2; j++) {
    m = M[j]
    print ""
    printf "Per test, %s compared with the baseline %s:\n", m, base
    for (i = 2; i <= n; i++) {
      s = S[i]
      printf "  %s: less on %d, same on %d, more on %d tests; geometric mean of ratio %.3f\n", s, less[m, s], same[m, s], more[m, s], (ratios[m, s] > 0 ? exp(log_ratio[m, s] / ratios[m, s]) : 1)
      printf "    largest increase: %+d (%s), largest decrease: %+d (%s)\n", max_d[m, s], max_t[m, s], min_d[m, s], min_t[m, s]
    }
  }
}' "$OUT/work.csv"
} | tee "$OUT/report.txt"
