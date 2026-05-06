#!/bin/bash
#
# compare_branches.sh
#
# Helper that builds two checkouts ('baseline' and 'patched') of the same
# postgres source tree, runs measure_wal.sh against each cluster, and prints
# the per-scenario WAL byte differences.
#
# Usage:
#   SRC=/home/user/postgres ./compare_branches.sh <baseline-ref> <patched-ref>
#
# The script creates separate build/install/data directories under
# /tmp/bench-multi-insert-{baseline,patched} so the two clusters do not
# clobber each other.  After it runs both, it prints a TSV diff.

set -euo pipefail

SRC=${SRC:-/home/user/postgres}
BASE_REF=${1:?baseline ref required}
PATCHED_REF=${2:?patched ref required}
ROWS=${ROWS:-200000}

BUILD_ROOT=/tmp/bench-multi-insert
mkdir -p "$BUILD_ROOT"

build_one() {
    local label=$1
    local ref=$2
    local prefix=$BUILD_ROOT/$label
    mkdir -p "$prefix"

    if [ -d "$prefix/install/bin" ]; then
        echo "# reuse existing build for $label"
        return
    fi

    git -C "$SRC" worktree add --force "$prefix/src" "$ref"
    pushd "$prefix/src" >/dev/null
    ./configure --prefix="$prefix/install" --enable-debug CFLAGS="-O2" >"$prefix/configure.log" 2>&1
    make -s -j"$(nproc)" >"$prefix/build.log" 2>&1
    make -s install >"$prefix/install.log" 2>&1
    popd >/dev/null

    "$prefix/install/bin/initdb" -D "$prefix/data" -U postgres -A trust >/dev/null
}

run_one() {
    local label=$1
    local prefix=$BUILD_ROOT/$label
    PGBIN="$prefix/install/bin" PGDATA="$prefix/data" PGPORT="$2" \
        "$(dirname "$0")/measure_wal.sh" "$ROWS" \
        | tee "$prefix/results.tsv"
    "$prefix/install/bin/pg_ctl" -D "$prefix/data" -m fast stop >/dev/null || true
}

build_one baseline "$BASE_REF"
build_one patched  "$PATCHED_REF"

run_one baseline 55432
run_one patched  55433

echo
echo "# === diff (patched - baseline) ==="
join -t $'\t' -j 1 \
    <(grep -v '^#' "$BUILD_ROOT/baseline/results.tsv" | awk '$2=="run=1"' | sort) \
    <(grep -v '^#' "$BUILD_ROOT/patched/results.tsv"  | awk '$2=="run=1"' | sort) \
  | awk -F'\t' '{
        scenario=$1
        # bytes are in field 3 of each side
        split($3,a,"="); base=a[2]
        split($7,b,"="); pat=b[2]
        if (base+0 > 0) {
            printf "%-32s baseline=%10d  patched=%10d  delta=%+d  pct=%+.2f%%\n",
                scenario, base, pat, pat-base, (pat-base)/base*100
        }
    }'
