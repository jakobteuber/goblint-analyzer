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
#            (default: "td_simplified_ref td_worklist_lifo td_worklist_fifo td_parallel_base")
#            td_parallel_base uses the thread pool mock chosen at build time, see GOBLINT_THREADPOOL_MOCK in src/util/parallel/dune.
#   JOBS     number of parallel Goblint runs (default: nproc)
#   TIMEOUT  seconds per run, i.e. per test and solver (default: 120)
#   OUT      output directory (default: tests/suite_result/solver_work)
#   gobopt   extra Goblint options, appended after the test's PARAM
#   GOBLINT  Goblint binary (default: ./goblint), e.g. a copy built with another thread pool mock
#   SVCOMP_CONF      configuration for SV-COMP tasks (default: conf/svcomp23.json)
#   SVCOMP_PROPERTY  property file for SV-COMP tasks, relative to the task directory (default: ../properties/no-data-race.prp)
#
# Output:
#   $OUT/work.csv     one row per test and solver: status (ok, timeout, error), eval and iterate calls, right-hand side evaluations
#   $OUT/report.txt   totals per solver and the comparison with the baseline, also printed at the end
#   $OUT/logs/        Goblint's output per test and solver

set -u

SOLVERS=(${SOLVERS:-td_simplified_ref td_worklist_lifo td_worklist_fifo td_parallel_base})
JOBS=${JOBS:-$(nproc)}
TIMEOUT=${TIMEOUT:-120}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "${OUT:-$ROOT/tests/suite_result/solver_work}")
GOBLINT=$(realpath "${GOBLINT:-$ROOT/goblint}")
SVCOMP_CONF=$(realpath "${SVCOMP_CONF:-$ROOT/conf/svcomp23.json}")
SVCOMP_PROPERTY=${SVCOMP_PROPERTY:-../properties/no-data-race.prp}

if [ ! -x "$GOBLINT" ]; then
  echo "Goblint not found at $GOBLINT, build it with ./make.sh nat first." >&2
  exit 1
fi

if [ $# -gt 0 ]; then
  GROUPS_=("$@")
else
  GROUPS_=($(ls "$ROOT/tests/regression"))
fi

rm -rf "$OUT"
mkdir -p "$OUT/logs" "$OUT/rows" "$OUT/goblint-dirs"

# Tests are discovered like update_suite.rb does: files NN-*.c, without SKIP (or kernel, if the headers are missing) in the first line.
TESTS=()
for group in "${GROUPS_[@]}"; do
  if [ -d "$group" ] && compgen -G "$group/*.yml" > /dev/null; then
    for f in "$group"/*.yml; do
      TESTS+=("$(realpath "$f")")
    done
    continue
  fi
  for f in "$ROOT"/tests/regression/"$group"/[0-9][0-9]-*.c; do
    [ -e "$f" ] || continue
    first=$(head -n 1 "$f")
    [[ $first == *SKIP* ]] && continue
    [[ $first == *kernel* && ! -e "$ROOT/linux-headers" ]] && continue
    TESTS+=("$f")
  done
done

echo "Running ${#SOLVERS[@]} solver(s) on ${#TESTS[@]} tests with $JOBS jobs, results in $OUT"

# Runs one test with one solver and writes one CSV row.
# Arguments: test file, solver
run_one() {
  local file=$1 solver=$2
  local group test id log params status work
  local input arch
  group=$(basename "$(dirname "$file")")
  if [[ $file == *.yml ]]; then
    # SV-COMP task: analyze its input file with the SV-COMP configuration, for the task's data model.
    test=$(basename "$file" .yml)
    input=$(grep -oP "^input_files: *'?\K[^' ]+" "$file" | head -n 1)
    arch=32bit
    grep -q "data_model: *LP64" "$file" && arch=64bit
    params="--conf $SVCOMP_CONF --set ana.specification $SVCOMP_PROPERTY --set exp.architecture $arch"
  else
    test=$(basename "$file" .c)
    input=$(basename "$file")
    params=$(head -n 1 "$file" | grep -oP "PARAM: \K.*")
  fi
  id="$group/$test"
  log="$OUT/logs/$group-$test.$solver.log"

  # PARAMs may refer to files relative to the test, so run in the test's directory (as update_suite.rb does).
  (cd "$(dirname "$file")" &&
    eval timeout "$TIMEOUT" "$GOBLINT" "$input" "$params" \
      --set solver "$solver" \
      --set goblint-dir "$OUT/goblint-dirs/$group-$test.$solver" "${gobopt:-}") > "$log" 2>&1
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
  cat "$OUT"/rows/*.csv | sort
} > "$OUT/work.csv"
rm -rf "$OUT/rows"

# The report only uses tests on which all solvers succeeded, so that the totals are comparable.
awk -F, -v solvers="${SOLVERS[*]}" '
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
  printf "%-22s %12s %10s %12s %12s %12s %10s\n", "solver", "rhs", "vs. base", "eval", "iterate", "eval+iter", "vs. base"
  for (i = 1; i <= n; i++) {
    s = S[i]
    total = sum_ev[s] + sum_it[s]; btotal = sum_ev[base] + sum_it[base]
    printf "%-22s %12d %9.1f%% %12d %12d %12d %9.1f%%\n", s, sum_rhs[s], (sum_rhs[base] > 0 ? 100 * sum_rhs[s] / sum_rhs[base] : 0), sum_ev[s], sum_it[s], total, (btotal > 0 ? 100 * total / btotal : 0)
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
}' "$OUT/work.csv" | tee "$OUT/report.txt"
