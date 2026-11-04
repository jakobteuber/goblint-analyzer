# Shared parts of compare_solvers.sh, solver_work.sh and solver_timing.sh, sourced by them.

# The work-list heuristics of td_worklist, and td_simplified_ref (no work list) as the baseline.
DEFAULT_SOLVERS="td_simplified_ref td_worklist_lifo td_worklist_fifo td_worklist_most_invalidated td_worklist_least_invalidated td_worklist_shallowest_created td_worklist_cheapest_first td_worklist_producers_first"

# Sets the array SOLVERS from $SOLVERS (default: $DEFAULT_SOLVERS) and adds the random runs:
# td_worklist_random#<seed> for each seed in $RANDOM_SEEDS (default: 1 ... $RANDOM_RUNS; RANDOM_RUNS default: 5).
# With a fixed seed, a random run is the same order in every script and every repetition.
init_solvers() {
  SOLVERS=(${SOLVERS:-$DEFAULT_SOLVERS})
  RANDOM_RUNS=${RANDOM_RUNS:-5}
  RANDOM_SEEDS=${RANDOM_SEEDS:-$(seq -s " " 1 "$RANDOM_RUNS")}
  RANDOM_RUNS=$(wc -w <<< "$RANDOM_SEEDS")
  local seed
  for seed in $RANDOM_SEEDS; do
    SOLVERS+=("td_worklist_random#$seed")
  done
}

# Prints the Goblint options for a solver as given in SOLVERS: the name before the # and,
# for td_worklist_random, the seed after it. For other solvers, the label after # only distinguishes repeated runs.
solver_args() {
  local solver=$1 name=${1%%#*} args
  args="--set solver $name"
  if [ "$name" = td_worklist_random ] && [[ $solver == *#* ]]; then
    args+=" --set solvers.td_worklist.random_seed ${solver#*#}"
  fi
  echo "$args"
}

# Sets the array TESTS from the arguments: regression test groups (default: all) or directories with SV-COMP tasks (*.yml).
# Regression tests are discovered like update_suite.rb does: files NN-*.c, without SKIP (or kernel, if the headers are missing) in the first line.
# Also writes a one-line description of the inputs to $OUT/dataset.txt, used as the dataset name in the plots.
discover_tests() {
  local groups=("$@") group f svcomp=() regression=()
  [ ${#groups[@]} -gt 0 ] || groups=($(ls "$ROOT/tests/regression"))
  TESTS=()
  for group in "${groups[@]}"; do
    if [ -d "$group" ] && compgen -G "$group/*.yml" > /dev/null; then
      for f in "$group"/*.yml; do
        TESTS+=("$(realpath "$f")")
      done
      svcomp+=("$(basename "$group")")
      continue
    fi
    regression+=("$group")
    for f in "$ROOT"/tests/regression/"$group"/[0-9][0-9]-*.c; do
      [ -e "$f" ] || continue
      first=$(head -n 1 "$f")
      [[ $first == *SKIP* ]] && continue
      [[ $first == *kernel* && ! -e "$ROOT/linux-headers" ]] && continue
      TESTS+=("$f")
    done
  done
  local desc=""
  if [ ${#regression[@]} -gt 0 ]; then
    if [ $# -eq 0 ]; then desc="regression tests"; else desc="regression tests ${regression[*]}"; fi
  fi
  [ ${#svcomp[@]} -gt 0 ] && desc="${desc:+$desc, }SV-COMP ${svcomp[*]}"
  echo "$desc (${#TESTS[@]} tests)" > "$OUT/dataset.txt"
}

# Sets group, test, id, input and params for a test file: a regression test with its PARAM line,
# or an SV-COMP task (*.yml), whose input file is analyzed with $SVCOMP_CONF, the task's data model and $SVCOMP_PROPERTY.
task_params() {
  local file=$1 arch
  group=$(basename "$(dirname "$file")")
  if [[ $file == *.yml ]]; then
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
}

# Common settings; ROOT must be set by the script.
init_common() {
  JOBS=${JOBS:-$(nproc)}
  GOBLINT=$(realpath "${GOBLINT:-$ROOT/goblint}")
  SVCOMP_CONF=$(realpath "${SVCOMP_CONF:-$ROOT/conf/svcomp23.json}")
  SVCOMP_PROPERTY=${SVCOMP_PROPERTY:-../properties/no-data-race.prp}
  if [ ! -x "$GOBLINT" ]; then
    echo "Goblint not found at $GOBLINT, build it with ./make.sh nat first." >&2
    exit 1
  fi
}

export -f solver_args task_params
