#!/usr/bin/env bash
#
# Query-shape benchmark for a SINGLE valkey-search module build.
# Starts one throwaway valkey-server, loads a dataset, and for each of three
# query shapes (single term / two-word AND / two-word OR) benchmarks the
# text-only FT.SEARCH against the same query with a numeric + tag filter added.
# Results are shown side by side so you can see the cost of the extra filters.
#
# Fill in the CONFIG section below, then run:
#
#     ./query_shape_benchmark.sh
#
set -euo pipefail

# ============================================================================
# CONFIG -- edit the values below, then run the script (no arguments needed).
# ============================================================================

# The single module .so file to benchmark (REQUIRED -- fill this in).
MODULE=""

# Where to find valkey-server / valkey-cli / valkey-benchmark.
# Leave empty to auto-detect on $PATH; otherwise point at the directory that
# holds the three binaries (e.g. a valkey source tree's src/ directory).
VALKEY_BIN_DIR=""

# Port for the throwaway server.
PORT=7781

# Benchmark tuning.
HOST="127.0.0.1"
REQUESTS=5000                  # FT.SEARCH requests per run; longer window = less noise
WARMUP=1                       # seconds of un-recorded warmup before each run
REPEATS=7                      # odd; report the median (of paired deltas)
PRECISION=3                    # latency decimal places
DOC_COUNTS=(1000)              # dataset sizes to sweep
CONN_COUNTS=(500)              # connection counts to sweep

# Output directory for the timestamped log.
OUTDIR="$(pwd)/output"

# CPU pinning for measurement stability. Server pins to one physical core; the
# client runs on separate cores so it never steals cycles from the core under
# test. Set PIN=0 to disable, or adjust for your topology (`lscpu -p=CPU,CORE`
# shows which logical CPUs share a core).
PIN=1
SERVER_CPUS=2
CLIENT_CPUS="6,7"

# ============================================================================
# End of CONFIG. You should not need to edit below this line.
# ============================================================================

# --- locate binaries --------------------------------------------------------
resolve_bin() {
    local name="$1"
    if [[ -n "$VALKEY_BIN_DIR" ]]; then printf '%s\n' "${VALKEY_BIN_DIR%/}/$name"; return 0; fi
    command -v "$name" 2>/dev/null || true
}
SERVER="$(resolve_bin valkey-server)"
CLI="$(resolve_bin valkey-cli)"
BENCH="$(resolve_bin valkey-benchmark)"

# --- validate configuration -------------------------------------------------
if [[ -z "$MODULE" ]]; then
    echo "ERROR: MODULE is not set. Edit the CONFIG section and point it at the" >&2
    echo "       libsearch.so you want to benchmark." >&2
    exit 2
fi
if [[ -z "$SERVER" || -z "$CLI" || -z "$BENCH" ]]; then
    echo "ERROR: could not locate valkey binaries." >&2
    echo "       Set VALKEY_BIN_DIR at the top of this script, or put valkey-server," >&2
    echo "       valkey-cli and valkey-benchmark on your PATH." >&2
    exit 1
fi
for f in "$SERVER" "$CLI" "$BENCH"; do
    [[ -x "$f" ]] || { echo "ERROR: not an executable binary: $f" >&2; exit 1; }
done
[[ -e "$MODULE" ]] || { echo "ERROR: missing module: $MODULE" >&2; exit 1; }

DATADIR="$(mktemp -d)"

# --- CPU pinning setup ------------------------------------------------------
SERVER_PIN=(); CLIENT_PIN=()
if [[ "$PIN" == "1" ]] && command -v taskset >/dev/null 2>&1; then
    SERVER_PIN=(taskset -c "$SERVER_CPUS")
    CLIENT_PIN=(taskset -c "$CLIENT_CPUS")
    echo "==> CPU pinning: server -> CPU(s) ${SERVER_CPUS}, client -> CPU(s) ${CLIENT_CPUS}"
fi

# --- tee all output to a timestamped file in the output dir -----------------
mkdir -p "$OUTDIR"
OUTFILE="${OUTDIR}/query_shape_benchmark_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$OUTFILE") 2>&1
echo "==> Logging output to ${OUTFILE}"
echo "==> Binaries: server=${SERVER} cli=${CLI} benchmark=${BENCH}"
echo "==> Config: REQUESTS=${REQUESTS} WARMUP=${WARMUP}s REPEATS=${REPEATS} (median) DOC_COUNTS=[${DOC_COUNTS[*]}] CONN_COUNTS=[${CONN_COUNTS[*]}]"
echo "==> module = ${MODULE}  port ${PORT}"

# --- start the server -------------------------------------------------------
"${SERVER_PIN[@]}" "$SERVER" --port "$PORT" --dir "$DATADIR" --save '' \
    --loadmodule "$MODULE" --daemonize no >/dev/null 2>&1 &
SRV_PID=$!

cleanup() {
    echo "==> Shutting down server (pid ${SRV_PID})"
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -rf "$DATADIR"
}
trap cleanup EXIT

vcli() { "$CLI" -h "$HOST" -p "$PORT" "$@"; }

# --- wait until ready -------------------------------------------------------
echo "==> Waiting for server to become ready"
for _ in $(seq 1 30); do
    if vcli ping 2>/dev/null | grep -q PONG; then break; fi
    sleep 0.2
done
vcli ping | grep -q PONG || { echo "ERROR: server on $PORT not ready" >&2; exit 1; }
echo "    server up"

# --- document corpus --------------------------------------------------------
base_docs=(
"The orchard was full of apple trees heavy with fruit. Farmers picked apple after apple while a gentle breeze carried the sweet scent of ripe apple across the rolling green hills near the old stone farmhouse."
"A banana plantation stretched to the horizon under a tropical sun. Workers harvested banana bunches by hand, loading each banana onto carts that rumbled along the dusty road toward the bustling coastal market town."
"In the late summer the cherry trees turned a deep crimson red. Children climbed the branches to reach each cherry, filling wicker baskets with cherry after cherry to bake into pies for the village harvest festival."
"The grocer arranged apple and banana side by side in the wooden crates. Shoppers debated whether an apple or a banana made the better snack, while the grocer happily sold both apple and banana all morning long."
"A fruit salad recipe called for apple, banana, and cherry in equal measure. The chef diced each apple, sliced every banana, and pitted the cherry by hand before tossing the apple banana cherry mixture with honey and mint."
"The botanist studied how apple and cherry trees share the same rose family lineage. Her notebook compared apple blossoms to cherry blossoms, noting that neither apple nor cherry resembled the unrelated tropical banana plant at all."
"At the smoothie bar the most popular blend mixed banana with cherry yogurt. Customers loved how the creamy banana balanced the tart cherry, and many returned daily for another banana cherry smoothie topped with crunchy granola."
"The painter filled the still life canvas with a red apple, a yellow banana, and a small cluster of cherry. Light fell across the apple, glanced off the banana, and pooled around the cherry on the dark wooden table."
"A nutrition study tracked volunteers who ate one apple, one banana, and a handful of cherry each day. Researchers measured how the apple fiber, banana potassium, and cherry antioxidants together affected energy and sleep over the trial."
"The market stall owner shouted prices for apple, banana, and cherry to the passing crowd. Fresh apple gleamed beside golden banana, and ruby cherry spilled from baskets as the owner weighed apple banana cherry orders all day."
)
for i in "${!base_docs[@]}"; do export "BASE_DOC_${i}=${base_docs[$i]}"; done

# (re)build the index and load exactly N documents into the server.
# IMPORTANT: load the data FIRST, then create the index. Mass-inserting via
# `valkey-cli --pipe` while an index already exists overruns the module's write
# path and stalls the server. Creating the index afterward triggers a bulk
# backfill that scans existing keys, which is stable even at 100k docs.
populate() {
    local n="$1"
    vcli FT.DROPINDEX idx >/dev/null 2>&1 || true
    vcli flushall >/dev/null

    local nbase="${#base_docs[@]}"
    # Each doc carries a text body plus a numeric (price) and tag (color) field
    # so the index exercises all three field types. Values are derived from the
    # doc number to give a stable, predictable distribution across runs.
    awk -v n="$n" -v nbase="$nbase" 'BEGIN {
        ncolor = split("red green blue", colors, " ")
        for (i = 1; i <= n; i++) {
            d = ENVIRON["BASE_DOC_" ((i - 1) % nbase)] " document number " i
            price = (i % 500) + 1
            color = colors[(i % ncolor) + 1]
            printf "*8\r\n$4\r\nHSET\r\n$%d\r\nhash:%d\r\n$4\r\nbody\r\n$%d\r\n%s\r\n$5\r\nprice\r\n$%d\r\n%d\r\n$5\r\ncolor\r\n$%d\r\n%s\r\n", \
                   length("hash:" i), i, length(d), d, length(price ""), price, length(color), color
        }
    }' | "$CLI" -h "$HOST" -p "$PORT" --pipe >/dev/null

    vcli FT.CREATE idx ON HASH PREFIX 1 hash: SCHEMA body TEXT price NUMERIC color TAG >/dev/null

    # backfill is async; wait until it reports complete before benchmarking
    for _ in $(seq 1 600); do
        local pct
        pct=$(vcli FT.INFO idx | grep -A1 backfill_complete_percent | tail -n1)
        [[ "$pct" == "1" || "$pct" == "1.000000" ]] && return
        sleep 0.1
    done
}

# --- query scenarios --------------------------------------------------------
# For each shape we compare the text-only query (A) against the same query with
# a numeric + tag filter appended (B). The Δ% shows the cost of the filters.
declare -a NAMES=(
    "single term"
    "two word AND"
    "two word OR"
)
declare -a TEXT_QUERIES=(
    "apple"
    "apple banana"
    "apple | banana"
)
declare -a COMBINED_QUERIES=(
    "apple @price:[1 250] @color:{red}"
    "apple banana @price:[1 250] @color:{red}"
    "(apple | banana) @price:[1 250] @color:{red}"
)

# one benchmark run -> "<rps> <p50>", parsed from the summary line.
# Client is pinned off the server core and a warmup pass is not recorded.
run_bench_once() {
    local conn="$1" query="$2"
    "${CLIENT_PIN[@]}" "$BENCH" -h "$HOST" -p "$PORT" -n "$REQUESTS" -c "$conn" \
        --warmup "$WARMUP" --precision "$PRECISION" -q \
        FT.SEARCH idx "$query" 2>/dev/null \
        | grep "requests per second" | tail -n1 \
        | sed -E 's/.*: ([0-9.]+) requests per second.*p50=([0-9.]+).*/\1 \2/'
}

# median of a stream of numbers on stdin (one per line)
median() {
    sort -n | awk '{ v[NR]=$1 } END { if (NR) { m=int((NR+1)/2); print v[m] } }'
}

# Benchmark the text-only (A) and combined (B) queries for one shape,
# INTERLEAVED and PAIRED: each repeat runs A then B back-to-back and records
# that repeat's delta (B vs A) immediately, so short-term drift cancels. We
# report the median paired delta -- NOT the delta of two independent medians.
# Representative absolute rps/p50 (for display) are the medians of each side.
# Sets globals A_RPS/A_P50/B_RPS/B_P50 and RPS_DELTA/P50_DELTA.
run_pair() {
    local conn="$1" qa="$2" qb="$3"
    local a_rps=() a_p50=() b_rps=() b_p50=() rps_d=() p50_d=()
    for _ in $(seq 1 "$REPEATS"); do
        local ar ap br bp
        read -r ar ap < <(run_bench_once "$conn" "$qa")
        read -r br bp < <(run_bench_once "$conn" "$qb")
        ar="${ar:-0}"; ap="${ap:-0}"; br="${br:-0}"; bp="${bp:-0}"
        a_rps+=("$ar"); a_p50+=("$ap"); b_rps+=("$br"); b_p50+=("$bp")
        # per-pair signed % deltas (combined relative to text-only)
        rps_d+=("$(awk -v a="$ar" -v b="$br" 'BEGIN{ if(a+0==0){print "nan"}else{printf "%.4f",(b-a)/a*100} }')")
        p50_d+=("$(awk -v a="$ap" -v b="$bp" 'BEGIN{ if(a+0==0){print "nan"}else{printf "%.4f",(b-a)/a*100} }')")
    done
    A_RPS="$(printf '%s\n' "${a_rps[@]}" | median)"; A_RPS="${A_RPS:-0}"
    A_P50="$(printf '%s\n' "${a_p50[@]}" | median)"; A_P50="${A_P50:-0}"
    B_RPS="$(printf '%s\n' "${b_rps[@]}" | median)"; B_RPS="${B_RPS:-0}"
    B_P50="$(printf '%s\n' "${b_p50[@]}" | median)"; B_P50="${B_P50:-0}"
    RPS_DELTA="$(printf '%s\n' "${rps_d[@]}" | grep -v nan | median)"
    P50_DELTA="$(printf '%s\n' "${p50_d[@]}" | grep -v nan | median)"
}

# format a numeric percentage (already computed) as "+12.3%" / "-4.5%" / "NA"
fmt_delta() {
    awk -v d="$1" 'BEGIN { if (d == "" ) { print "NA"; exit } printf "%+.1f%%", d }'
}

# --- sweep ------------------------------------------------------------------
for docs in "${DOC_COUNTS[@]}"; do
    echo
    echo "############################################################"
    echo "## ${docs} documents"
    echo "############################################################"
    populate "$docs"
    echo "   DBSIZE=$(vcli dbsize), apple matches=$(vcli FT.SEARCH idx 'apple' | head -n1)"

    for conn in "${CONN_COUNTS[@]}"; do
        echo
        echo "  --- c=${conn} connections --- (rps higher=better, p50 ms lower=better)"
        printf "  %-14s %-20s %-20s %10s %10s\n" \
            "shape" "text-only rps(p50)" "text+num+tag rps(p50)" "rps Δ%" "p50 Δ%"

        for i in "${!NAMES[@]}"; do
            run_pair "$conn" "${TEXT_QUERIES[$i]}" "${COMBINED_QUERIES[$i]}"
            printf "  %-14s %-20s %-20s %10s %10s\n" \
                "${NAMES[$i]}" \
                "$(printf '%.0f (%.2f)' "$A_RPS" "$A_P50")" \
                "$(printf '%.0f (%.2f)' "$B_RPS" "$B_P50")" \
                "$(fmt_delta "$RPS_DELTA")" \
                "$(fmt_delta "$P50_DELTA")"
        done
    done
done

echo
echo "==> Δ% columns are text+num+tag relative to text-only (the filter cost):"
echo "      rps Δ%  : negative = combined query has lower throughput (expected)"
echo "      p50 Δ%  : positive = combined query has higher latency (expected)"
echo "==> Done. Full log saved to ${OUTFILE}"
