set -euo pipefail

SCALE=${SCALE:-10}
TX=${TX:-20000}
RUNS=${RUNS:-5}
PORT=${PORT:-5499}
CPUS=${CPUS:-}
PGDATA=$HOME/perfdata
STAMP=$(date +%Y%m%d-%H%M%S)
RESULTS=$HOME/perf-results-$STAMP.csv

[ $# -ge 1 ] || set -- /usr/local/pgsql/bin

SERVER_OPTS=(
    -c shared_buffers=128kB
    -c track_io_timing=on
    -c autovacuum=off
    -c checkpoint_timeout=1d
    -c max_wal_size=100GB
    -c bgwriter_lru_maxpages=0
)

pin() {
    if [ -n "$CPUS" ]; then taskset -c "$CPUS" "$@"; else "$@"; fi
}

build_name() {
    local bin=${1%/}
    basename "$(dirname "$bin")"
}

run_one() {
    local bin=${1%/} run=$2
    local name out log
    name=$(build_name "$bin")
    out=$HOME/perf-$name-$STAMP-r$run.csv
    log=$HOME/postgres-$name-$STAMP-r$run.log

    if [ -f "$PGDATA/postmaster.pid" ]; then
        "$bin/pg_ctl" -D "$PGDATA" -w stop -m immediate >/dev/null 2>&1 || true
    fi
    rm -rf "$PGDATA"

    "$bin/initdb" -D "$PGDATA" >/dev/null
    "$bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -l "$HOME/init-$name.log" -w start >/dev/null
    "$bin/createdb" -p "$PORT" bench
    "$bin/pgbench" -p "$PORT" -i -s "$SCALE" -q bench >/dev/null 2>&1
    "$bin/psql" -p "$PORT" -q -c 'VACUUM ANALYZE' -c 'CHECKPOINT' bench
    "$bin/pg_ctl" -D "$PGDATA" -w stop -m fast >/dev/null

    pin perf stat -x, -e instructions:u,cycles:u -o "$out" \
        -- "$bin/postgres" -D "$PGDATA" -p "$PORT" "${SERVER_OPTS[@]}" \
        >"$log" 2>&1 &
    local perf_pid=$!

    local i=0
    until "$bin/pg_isready" -p "$PORT" -q; do
        sleep 0.5
        i=$((i + 1))
    done

    pin "$bin/pgbench" -p "$PORT" -c 1 -j 1 -t "$TX" bench \
        >"$HOME/pgbench-$name-$STAMP-r$run.txt"

    "$bin/pg_ctl" -D "$PGDATA" -w stop -m fast >/dev/null
    wait "$perf_pid" || true

    local instr cycles
    instr=$(awk -F, '$3 ~ /^instructions/ {print $1}' "$out")
    cycles=$(awk -F, '$3 ~ /^cycles/ {print $1}' "$out")
    echo "$name,$run,$instr,$cycles" >>"$RESULTS"
    awk -v r="$run" -v n="$name" -v i="$instr" -v c="$cycles" -v tx="$TX" \
        'BEGIN { printf "run %2d  %-20s instr/tx %10.1f  cycles/tx %10.1f\n", r, n, i/tx, c/tx }'
}

stats() {
    sort -g | awk '{a[NR]=$1}
        END { m = (NR % 2) ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1]) / 2
              printf "%.1f %.1f %.1f\n", m, a[1], a[NR] }'
}

echo "build,run,instructions,cycles" >"$RESULTS"
echo "SCALE=$SCALE TX=$TX RUNS=$RUNS CPUS=${CPUS:-unpinned}"

bins=("$@")
for run in $(seq 1 "$RUNS"); do
    if (( run % 2 == 1 )); then
        order=("${bins[@]}")
    else
        order=()
        for (( k=${#bins[@]}-1; k>=0; k-- )); do order+=("${bins[k]}"); done
    fi
    for bin in "${order[@]}"; do
        run_one "$bin" "$run"
    done
done

echo
echo "== per tx: median (min .. max) over $RUNS runs =="
declare -A MED_I MED_C
for bin in "${bins[@]}"; do
    name=$(build_name "$bin")
    read -r mi lo_i hi_i < <(awk -F, -v n="$name" -v tx="$TX" 'NR>1 && $1==n {print $3/tx}' "$RESULTS" | stats)
    read -r mc lo_c hi_c < <(awk -F, -v n="$name" -v tx="$TX" 'NR>1 && $1==n {print $4/tx}' "$RESULTS" | stats)
    MED_I[$name]=$mi
    MED_C[$name]=$mc
    printf "%-20s instr %10.1f (%.1f .. %.1f)   cycles %10.1f (%.1f .. %.1f)\n" \
        "$name" "$mi" "$lo_i" "$hi_i" "$mc" "$lo_c" "$hi_c"
done

if [ ${#bins[@]} -ge 2 ]; then
    base=$(build_name "${bins[0]}")
    for bin in "${bins[@]:1}"; do
        name=$(build_name "$bin")
        awk -v b="${MED_I[$base]}" -v p="${MED_I[$name]}" \
            -v bc="${MED_C[$base]}" -v pc="${MED_C[$name]}" -v n="$name" -v bn="$base" \
            'BEGIN { printf "%s vs %s: instr %+.1f/tx (%+.3f%%), cycles %+.1f/tx (%+.2f%%)\n",
                     n, bn, p-b, (p-b)/b*100, pc-bc, (pc-bc)/bc*100 }'
    done
fi

echo "raw results: $RESULTS"
