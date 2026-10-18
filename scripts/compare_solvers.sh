#!/usr/bin/env bash
# Compare the precision of solvers pairwise (via Goblint's `comparesolver` option) on all regression tests.
#
# Usage: ./scripts/compare_solvers.sh [group | task-directory ...]
#   group:          regression test group directories to restrict to, e.g. 04-mutex (default: all of tests/regression)
#   task-directory: a directory with SV-COMP task definitions (*.yml), e.g. sv-benchmarks/c/pthread,
#                   see scripts/solver_work.sh for downloading them.
#                   Each task is run with $SVCOMP_CONF, the task's data model and the property $SVCOMP_PROPERTY.
#
# Environment variables:
#   SOLVERS  solvers to compare, every pair is compared once (default: "td_simplified_ref td_worklist_lifo td_worklist_fifo td_parallel_base")
#   JOBS     number of parallel Goblint runs (default: nproc)
#   TIMEOUT  seconds per run, i.e. per test and pair of solvers (default: 120)
#   OUT      output directory (default: tests/suite_result/compare_solvers)
#   gobopt   extra Goblint options, appended after the test's PARAM
#   GOBLINT  Goblint binary (default: ./goblint), e.g. a copy built with another thread pool mock
#   SVCOMP_CONF      configuration for SV-COMP tasks (default: conf/svcomp23.json)
#   SVCOMP_PROPERTY  property file for SV-COMP tasks, relative to the task directory (default: ../properties/no-data-race.prp)
#
# Output:
#   $OUT/compare.csv   one row per test and pair; "left" is the first solver of the pair, "right" the second.
#                      For each of globals, locals (contexts joined per node) and locals_ctx (per node and context):
#                      the number of unknowns that are equal, more precise using left, more precise using right, incomparable.
#                      Globals of the race and deadlock analyses (race:*, deadlock:*) are not counted but listed in globals_warn_ignored:
#                      the comparison solver runs without warnings, so these analyses never side-effect to them
#                      and they always appear more precise on the right.
#   $OUT/logs/         Goblint's output per test and pair, including the differing values
#   The summary per pair is printed at the end and written to $OUT/summary.txt.

set -u

SOLVERS=(${SOLVERS:-td_simplified_ref td_worklist_lifo td_worklist_fifo td_parallel_base})
JOBS=${JOBS:-$(nproc)}
TIMEOUT=${TIMEOUT:-120}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "${OUT:-$ROOT/tests/suite_result/compare_solvers}")
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

PAIRS=()
for ((i = 0; i < ${#SOLVERS[@]}; i++)); do
  for ((j = i + 1; j < ${#SOLVERS[@]}; j++)); do
    PAIRS+=("${SOLVERS[i]} ${SOLVERS[j]}")
  done
done

echo "Comparing ${#PAIRS[@]} pair(s) of solvers on ${#TESTS[@]} tests with $JOBS jobs, results in $OUT"

# Runs one test with one pair of solvers and writes one CSV row.
# Arguments: test file, left solver, right solver
run_one() {
  local file=$1 left=$2 right=$3
  local group test id log params status numbers warn_only
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
  log="$OUT/logs/$group-$test.$left.$right.log"

  # PARAMs may refer to files relative to the test, so run in the test's directory (as update_suite.rb does).
  (cd "$(dirname "$file")" &&
    eval timeout "$TIMEOUT" "$GOBLINT" "$input" "$params" \
      --set solver "$left" --set comparesolver "$right" \
      --set goblint-dir "$OUT/goblint-dirs/$group-$test.$left.$right" \
      --enable dbg.compare_runs.diff "${gobopt:-}") > "$log" 2>&1
  local exit_code=$?
  rm -rf "$OUT/goblint-dirs/$group-$test.$left.$right"

  # globals: 4 numbers, locals: 4 numbers, locals_ctx: 6 numbers (the last two are unknowns missing in one of the solutions)
  numbers=$(grep -E "^\[Info\] (globals|locals|locals_ctx):" "$log" | grep -oE "= [0-9]+" | grep -oE "[0-9]+" | paste -sd,)
  if [ "$(echo "$numbers" | tr ',' '\n' | grep -c .)" -eq 14 ]; then
    status=ok
  elif [ $exit_code -eq 124 ]; then
    status=timeout
  else
    status=error
  fi
  if [ $status = ok ]; then
    # Move race:* and deadlock:* globals from the left/right/incomparable counts (fields 2-4) into a separate count.
    warn_only=$(grep -E "^\[Info\] Global (race|deadlock):" "$log" | grep -vE "is incomparable \(reverse diff\):" |
      awk '/more precise using left:/ {l++} /more precise using right:/ {r++} /is incomparable/ {i++} END {printf "%d,%d,%d", l, r, i}')
    numbers=$(awk -F, -v warn_only="$warn_only" 'BEGIN {split(warn_only, x, ",")} {
      $2 -= x[1]; $3 -= x[2]; $4 -= x[3]; OFS = ","; $1 = $1; print $0 "," (x[1] + x[2] + x[3])
    }' <<< "$numbers")
  else
    numbers=",,,,,,,,,,,,,,"
  fi
  echo "$id,$left,$right,$status,$numbers" > "$OUT/rows/$group-$test.$left.$right.csv"
}
export -f run_one
export OUT TIMEOUT GOBLINT SVCOMP_CONF SVCOMP_PROPERTY
export gobopt="${gobopt:-}"

for f in "${TESTS[@]}"; do
  for pair in "${PAIRS[@]}"; do
    echo "$f $pair"
  done
done | xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _

rmdir "$OUT/goblint-dirs" 2>/dev/null

{
  echo "test,left,right,status,globals_equal,globals_left,globals_right,globals_incomparable,locals_equal,locals_left,locals_right,locals_incomparable,ctx_equal,ctx_left,ctx_right,ctx_incomparable,ctx_missing_in_right,ctx_missing_in_left,globals_warn_ignored"
  cat "$OUT"/rows/*.csv | sort
} > "$OUT/compare.csv"
rm -rf "$OUT/rows"

# Summary per pair: a test counts as "left more precise" if left is more precise for at least one unknown, etc.
awk -F, 'NR > 1 {
  pair = $2 " vs " $3
  pairs[pair] = 1
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
  for (pair in pairs) {
    print pair ":"
    printf "  tests:                     %d\n", total[pair]
    printf "  failed (error/timeout):    %d\n", failed[pair]
    printf "  identical results:         %d\n", same[pair]
    printf "  left more precise somewhere:  %d\n", left[pair]
    printf "  right more precise somewhere: %d\n", right[pair]
    printf "  incomparable somewhere:    %d\n", incomparable[pair]
    printf "  contexts missing on a side: %d\n", missing[pair]
    if (diff_list[pair] != "") print "  differing tests (left/right/incomparable per category; missing in right/left):" diff_list[pair]
    if (failed_list[pair] != "") print "  failed tests:" failed_list[pair]
    print ""
  }
}' "$OUT/compare.csv" | tee "$OUT/summary.txt"
