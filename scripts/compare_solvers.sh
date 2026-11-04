#!/usr/bin/env bash
# Compare the precision of solvers pairwise on the regression tests or SV-COMP tasks.
# One Goblint run per test solves with every solver once and compares all pairs of results (Goblint's comparesolvers).
# So the number of analyses grows linearly with the number of solvers; only the comparisons, which are cheap, grow quadratically.
# All solvers run with warnings, so the race and deadlock globals are compared like all others
# (with comparesolver, the second solver ran without warnings, so they had to be excluded).
# Saving the results of separate runs and comparing them (save_run, compare_runs) does not work for SV-COMP:
# its configuration enables the octagon domain, whose (Apron) values cannot be marshalled.
# If one solver fails on a test (error, timeout), no pair of that test is compared.
#
# Usage: ./scripts/compare_solvers.sh [group | task-directory ...]
#   group:          regression test group directories to restrict to, e.g. 04-mutex (default: all of tests/regression)
#   task-directory: a directory with SV-COMP task definitions (*.yml), e.g. sv-benchmarks/c/pthread,
#                   see scripts/solver_work.sh for downloading them.
#                   Each task is run with $SVCOMP_CONF, the task's data model and the property $SVCOMP_PROPERTY.
#
# Environment variables:
#   SOLVERS  solvers to compare, every pair is compared once (default: DEFAULT_SOLVERS in scripts/solver_lib.sh)
#            A solver can be given several times with a label after #; for td_worklist_random, the label is the seed.
#   RANDOM_RUNS   number of random orders: td_worklist_random#1 ... are added to SOLVERS (default: 5)
#   RANDOM_SEEDS  the seeds of the random orders instead (default: 1 ... RANDOM_RUNS)
#   JOBS     number of tests analyzed in parallel; the solvers of one test run one after another (default: nproc)
#   TIMEOUT  seconds per solver: the run of a test gets TIMEOUT times the number of solvers (default: 120)
#   OUT      output directory (default: tests/suite_result/compare_solvers)
#   gobopt   extra Goblint options, appended after the test's PARAM
#   GOBLINT  Goblint binary (default: ./goblint)
#   SVCOMP_CONF      configuration for SV-COMP tasks (default: conf/svcomp23.json)
#   SVCOMP_PROPERTY  property file for SV-COMP tasks, relative to the task directory (default: ../properties/no-data-race.prp)
#
# Output:
#   $OUT/compare.csv   one row per test and pair; "left" is the solver that comes first in SOLVERS, "right" the other one.
#                      status: ok, timeout or error (of the run of the test).
#                      For each of globals, locals (contexts joined per node) and locals_ctx (per node and context):
#                      the number of unknowns that are equal, more precise using left, more precise using right, incomparable;
#                      for locals_ctx also the unknowns missing in one of the results.
#   $OUT/summary.txt   per pair: counts of tests, and the differing tests; also printed at the end
#   $OUT/dataset.txt   description of the inputs, for the plots
#   $OUT/logs/         Goblint's output per test, including the differing values

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/scripts/solver_lib.sh"
init_solvers
init_common
TIMEOUT=${TIMEOUT:-120}
OUT=$(realpath -m "${OUT:-$ROOT/tests/suite_result/compare_solvers}")

rm -rf "$OUT"
mkdir -p "$OUT/logs" "$OUT/rows" "$OUT/goblint-dirs"
discover_tests "$@"

n=${#SOLVERS[@]}
echo "Comparing $n solvers ($((n * (n - 1) / 2)) pairs) on ${#TESTS[@]} tests with $JOBS jobs, results in $OUT"

# Analyzes one test with all solvers, compares the results and writes one CSV row per pair.
# Arguments: test file
run_test() {
  local file=$1
  local solvers others list log code status i j k=0 rows=()
  read -ra solvers <<< "$SOLVER_LIST"
  task_params "$file"
  log="$OUT/logs/$group-$test.log"
  others=("${solvers[@]:1}")
  list=$(printf "'%s'," "${others[@]}")
  list="[${list%,}]"

  # PARAMs may refer to files relative to the test, so run in the test's directory (as update_suite.rb does).
  (cd "$(dirname "$file")" &&
    eval timeout "$((TIMEOUT * ${#solvers[@]}))" "$GOBLINT" "$input" "$params" $(solver_args "${solvers[0]}") \
      --set comparesolvers "\"$list\"" --enable dbg.compare_runs.diff \
      --set goblint-dir "'$OUT/goblint-dirs/$group-$test'" "${gobopt:-}") > "$log" 2>&1
  code=$?
  rm -rf "$OUT/goblint-dirs/$group-$test"

  # 14 numbers per compared pair (globals, locals, locals_ctx), in the order of the pairs below.
  mapfile -t rows < <(perl -ne '
    @n = () if /Comparing GlobConstrSys precision of/;
    if (/^\[Info\] (globals|locals|locals_ctx):/) { push @n, /= (\d+)/g; print join(",", @n), "\n" if @n == 14 }
  ' "$log")
  local pairs=$((${#solvers[@]} * (${#solvers[@]} - 1) / 2))
  if [ $code -eq 124 ]; then
    status=timeout
  elif [ $code -ne 0 ] || [ ${#rows[@]} -ne $pairs ]; then
    status=error
  else
    status=ok
  fi
  for ((i = 0; i < ${#solvers[@]}; i++)); do
    for ((j = i + 1; j < ${#solvers[@]}; j++)); do
      if [ $status = ok ]; then
        echo "$id,${solvers[i]},${solvers[j]},ok,${rows[k]}"
      else
        echo "$id,${solvers[i]},${solvers[j]},$status,,,,,,,,,,,,,,"
      fi
      k=$((k + 1))
    done
  done > "$OUT/rows/$group-$test.csv"
}
export -f run_test
export OUT TIMEOUT GOBLINT SVCOMP_CONF SVCOMP_PROPERTY
export SOLVER_LIST="${SOLVERS[*]}"
export gobopt="${gobopt:-}"

printf "%s\n" "${TESTS[@]}" | xargs -P "$JOBS" -I {} bash -c 'run_test "$@"' _ {}

rmdir "$OUT/goblint-dirs" 2>/dev/null

{
  echo "test,left,right,status,globals_equal,globals_left,globals_right,globals_incomparable,locals_equal,locals_left,locals_right,locals_incomparable,ctx_equal,ctx_left,ctx_right,ctx_incomparable,ctx_missing_in_right,ctx_missing_in_left"
  cat "$OUT"/rows/*.csv | sort
} > "$OUT/compare.csv"
rm -rf "$OUT/rows"

# Summary per pair: a test counts as "left more precise" if left is more precise for at least one unknown, etc.
awk -F, -v solvers="$SOLVER_LIST" 'NR > 1 {
  pair = $2 " vs " $3
  total[pair]++
  if ($4 != "ok") { failed[pair]++; failed_list[pair] = failed_list[pair] "\n    " $1 " (" $4 ")"; next }
  l = $6 + $10 + $14
  r = $7 + $11 + $15
  inc = $8 + $12 + $16
  miss = $17 + $18
  if (l + r + inc + miss == 0) { same[pair]++; next }
  if (l > 0) left[pair]++
  if (r > 0) right[pair]++
  if (inc > 0) incomparable[pair]++
  if (miss > 0) missing[pair]++
  diff_list[pair] = diff_list[pair] sprintf("\n    %-60s globals %s/%s/%s locals %s/%s/%s ctx %s/%s/%s missing %s/%s", $1, $6, $7, $8, $10, $11, $12, $14, $15, $16, $17, $18)
}
END {
  n = split(solvers, S, " ")
  printf "%-70s %6s %6s %9s %6s %6s %6s %6s\n", "pair (left vs right)", "tests", "failed", "identical", "left", "right", "incomp", "missing"
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
    pair = S[i] " vs " S[j]; order[++m] = pair
    printf "%-70s %6d %6d %9d %6d %6d %6d %6d\n", pair, total[pair], failed[pair], same[pair], left[pair], right[pair], incomparable[pair], missing[pair]
  }
  print ""
  print "left/right: tests where that solver is more precise for at least one unknown; incomp: incomparable for at least one;"
  print "missing: contexts missing in one of the results."
  for (k = 1; k <= m; k++) {
    pair = order[k]
    if (diff_list[pair] == "" && failed_list[pair] == "") continue
    print ""
    print pair ":"
    if (diff_list[pair] != "") print "  differing tests (left/right/incomparable per category; missing in right/left):" diff_list[pair]
    if (failed_list[pair] != "") print "  failed tests:" failed_list[pair]
  }
}' "$OUT/compare.csv" | tee "$OUT/summary.txt"
