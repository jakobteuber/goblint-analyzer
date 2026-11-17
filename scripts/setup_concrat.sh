#!/usr/bin/env bash
# Download the Concrat benchmarks (https://github.com/kaist-plrg/concrat, Hong & Ryu, ICSE 2023) and prepare them
# for compare_solvers.sh, solver_work.sh and solver_timing.sh.
#
# Concrat's bench/ has one directory per real-world program (GitHub projects using the pthread lock API), each with a
# CIL-merged single file main.c. Kocal et al. ("Same Engine, Multiple Gears") used the non-trivial ones of them.
# This script creates the gitignored directory concrat/ with one file <program>.c per program, whose first line is a
# PARAM comment as in the regression tests:
#   --conf ../conf/concrat.json: the configuration of the artifact of Kocal et al. (their gob_server_with_sv.json,
#     zenodo.org/records/18186778, without "result": "json-messages", which only selects the output format),
#   and for the five programs without a main function (libraries), --enable allfuns --enable exp.earlyglobs,
#   as in Concrat's own Makefiles.
# Then the scripts take the directory like a regression test group, or single files:
#   ./scripts/solver_work.sh concrat
#   ./scripts/compare_solvers.sh concrat/pigz.c concrat/wrk.c
#   ./scripts/solver_timing.sh concrat/pigz.c
#
# Changes to the programs:
#   - The *-fixed variants (dnspod-sr, Mirai-Source-Code, pigz, streem, sysbench) are left out: they are the same
#     programs with fixes for Concrat's translation to Rust (at most a few lines, pigz-fixed has the same main.c).
#   - Decimal integer constants >= 2^63 without suffix get the suffix ULL. The CIL version that merged the programs
#     printed unsigned 64-bit constants without suffix, and Goblint's CIL rejects them ("Cannot represent the integer"),
#     e.g. 18446744073709551615 in 13 of the programs. Kocal et al. fixed wrk the same way.
#   - Two errors of CIL's merger that Goblint's CIL rejects: zmap (a renamed parameter of an inline glibc function) and
#     sysbench (an inline function defined five times, with differently named but equal union types), see below.
#
# Also writes concrat/stats.csv, static statistics of the programs (see scripts/benchmark_stats.py).
#
# Usage: ./scripts/setup_concrat.sh
# Environment variables:
#   CONCRAT_COMMIT  commit of the Concrat repository (default: the one this was set up with)

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/concrat
REPO=$DIR/.repo
CONCRAT_COMMIT=${CONCRAT_COMMIT:-64c17d4b949c647500bfecfd69a36e3a1ae6a942}

if [ ! -d "$REPO/.git" ]; then
  # Only the C files: the repository also contains the Rust translations and Concrat itself.
  git clone --filter=blob:none --no-checkout https://github.com/kaist-plrg/concrat.git "$REPO"
  git -C "$REPO" sparse-checkout set --no-cone '/bench/*/main.c' '/bench/*/README.md' '/LICENSE'
fi
git -C "$REPO" fetch --quiet origin "$CONCRAT_COMMIT"
git -C "$REPO" -c advice.detachedHead=false checkout --quiet "$CONCRAT_COMMIT"

rm -f "$DIR"/*.c
n=0
for src in "$REPO"/bench/*/main.c; do
  name=$(basename "$(dirname "$src")")
  [[ $name == *-fixed ]] && continue
  param="--conf ../conf/concrat.json"
  grep -q "int main(" "$src" || param+=" --enable allfuns --enable exp.earlyglobs"
  {
    echo "// PARAM: $param"
    # Unsigned 64-bit constants: >= 2^63, without suffix (not the digits of a floating-point constant).
    perl -pe 's/(?<![\w.])(\d{19,20})(?![\w.])/length($1) == 20 || $1 ge "9223372036854775808" ? "$1ULL" : $1/ge' "$src" |
      case $name in
        # The parameter __addr of one copy of glibc's fortified recvfrom was renamed, but not its uses.
        zmap) perl -0pe 's/__cil_tmp14 ,(\n\s*socklen_t \* __restrict  __addr_len \)\n\{\n)(?!  __SOCKADDR_ARG __addr ;)/__addr ,$1/g' ;;
        # Five definitions of the inline function sb_rand_uniform_double (one per merged file), keep the first.
        sysbench) perl -0pe '$n = 0; s/(__inline double sb_rand_uniform_double\(void\)\n\{\n.*?\n\}\n\}\n)/$n++ ? "" : $1/gse' ;;
        *) cat ;;
      esac
  } > "$DIR/$name.c"
  n=$((n + 1))
done

python3 -I "$ROOT/scripts/benchmark_stats.py" "$DIR"/*.c > "$DIR/stats.csv"
echo "Prepared $n Concrat programs in $DIR, statistics in $DIR/stats.csv"
