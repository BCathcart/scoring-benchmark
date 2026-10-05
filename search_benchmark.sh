#!/usr/bin/env bash
#
# Comparative performance benchmark for two valkey-search module builds.
# Starts two throwaway valkey-servers (one per module) on separate ports,
# loads the same dataset into both, and benchmarks several FT.SEARCH query
# shapes across a sweep of dataset sizes and connection counts. Results are
# shown side by side with throughput / latency deltas (candidate vs baseline).
#
# This script is self-contained and location-independent: it hardcodes no
# usernames or absolute paths. Fill in the CONFIG section below, then run:
#
#     ./search_benchmark_portable.sh
#
set -euo pipefail

# ============================================================================
# CONFIG -- edit the values below, then run the script (no arguments needed).
# Every value can also be overridden from the environment without editing, e.g.
#   BASE_MODULE=/a/libsearch.so CAND_MODULE=/b/libsearch.so ./search_benchmark.sh
# so one checked-in copy serves several checkouts and CI-style wrappers.
# ============================================================================

# The two module .so files to compare (REQUIRED -- fill these in).
# baseline = the original module; candidate = the new build to compare against.
BASE_MODULE="${BASE_MODULE:-}"   # e.g. /path/to/baseline/valkey-search/.build-release/libsearch.so
CAND_MODULE="${CAND_MODULE:-}"   # e.g. /path/to/candidate/valkey-search/.build-release/libsearch.so

# Where to find valkey-server / valkey-cli / valkey-benchmark.
# Leave empty to auto-detect on $PATH; otherwise point at the directory that
# holds the three binaries (e.g. a valkey source tree's src/ directory).
VALKEY_BIN_DIR="${VALKEY_BIN_DIR:-}"

# Labels shown in the results table.
BASE_NAME="${BASE_NAME:-baseline}"
CAND_NAME="${CAND_NAME:-candidate}"

# Ports for the two throwaway servers.
BASE_PORT="${BASE_PORT:-7779}"
CAND_PORT="${CAND_PORT:-7780}"

# Benchmark tuning.
HOST="${HOST:-127.0.0.1}"
REQUESTS="${REQUESTS:-5000}"     # FT.SEARCH requests per run; longer window = less noise
WARMUP="${WARMUP:-1}"            # seconds of un-recorded warmup before each run
REPEATS="${REPEATS:-7}"          # odd; report the median (of paired deltas)
PRECISION="${PRECISION:-3}"      # latency decimal places
DOC_COUNTS=(${DOC_COUNTS:-1000}) # dataset sizes to sweep (space-separated in env)
CONN_COUNTS=(${CONN_COUNTS:-500}) # connection counts to sweep (space-separated in env)

# Which scenario set to run: "text" (the original non-positional queries),
# "positional" (phrase / INORDER / SLOP, which exercise the position merge the
# text set never touches), or "all".
SCENARIOS="${SCENARIOS:-all}"

# Output directory for the timestamped log.
OUTDIR="${OUTDIR:-$(pwd)/output}"

# CPU pinning for measurement stability. Both servers share ONE physical core
# (benchmarks run serially, so only one is ever hot; identical pinning gives
# both an identical CPU environment). The client runs on separate cores so it
# never steals cycles from the core under test. Set PIN=0 to disable, or adjust
# for your topology (`lscpu -p=CPU,CORE` shows which logical CPUs share a core).
PIN="${PIN:-1}"
SERVER_CPUS="${SERVER_CPUS:-2}"
CLIENT_CPUS="${CLIENT_CPUS:-6,7}"

# For an A/A noise check, point CAND_MODULE at the same .so as BASE_MODULE:
# the true delta is then 0%, so every reported delta is the harness noise floor.

# ============================================================================
# End of CONFIG. You should not need to edit below this line.
# ============================================================================

# --- locate binaries --------------------------------------------------------
# Resolution per binary: VALKEY_BIN_DIR if set, otherwise found on $PATH.
resolve_bin() {
    local name="$1"
    if [[ -n "$VALKEY_BIN_DIR" ]]; then printf '%s\n' "${VALKEY_BIN_DIR%/}/$name"; return 0; fi
    command -v "$name" 2>/dev/null || true
}
SERVER="$(resolve_bin valkey-server)"
CLI="$(resolve_bin valkey-cli)"
BENCH="$(resolve_bin valkey-benchmark)"

# --- validate configuration -------------------------------------------------
if [[ -z "$BASE_MODULE" || -z "$CAND_MODULE" ]]; then
    echo "ERROR: BASE_MODULE and CAND_MODULE are not set." >&2
    echo "       Edit the CONFIG section at the top of this script and set both" >&2
    echo "       to the libsearch.so files you want to compare." >&2
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
for f in "$BASE_MODULE" "$CAND_MODULE"; do
    [[ -e "$f" ]] || { echo "ERROR: missing module: $f" >&2; exit 1; }
done

BASE_DATADIR="$(mktemp -d)"
CAND_DATADIR="$(mktemp -d)"

# --- CPU pinning setup ------------------------------------------------------
SERVER_PIN=(); CLIENT_PIN=()
if [[ "$PIN" == "1" ]] && command -v taskset >/dev/null 2>&1; then
    SERVER_PIN=(taskset -c "$SERVER_CPUS")
    CLIENT_PIN=(taskset -c "$CLIENT_CPUS")
    echo "==> CPU pinning: servers -> CPU(s) ${SERVER_CPUS}, client -> CPU(s) ${CLIENT_CPUS}"
fi

# --- tee all output to a timestamped file in the output dir -----------------
mkdir -p "$OUTDIR"
OUTFILE="${OUTDIR}/search_benchmark_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$OUTFILE") 2>&1
echo "==> Logging output to ${OUTFILE}"
echo "==> Binaries: server=${SERVER} cli=${CLI} benchmark=${BENCH}"
echo "==> Config: REQUESTS=${REQUESTS} WARMUP=${WARMUP}s REPEATS=${REPEATS} (median) DOC_COUNTS=[${DOC_COUNTS[*]}] CONN_COUNTS=[${CONN_COUNTS[*]}]"
echo "==> baseline  = ${BASE_NAME}  (${BASE_MODULE})  port ${BASE_PORT}"
echo "==> candidate = ${CAND_NAME}  (${CAND_MODULE})  port ${CAND_PORT}"

# --- start both servers -----------------------------------------------------
"${SERVER_PIN[@]}" "$SERVER" --port "$BASE_PORT" --dir "$BASE_DATADIR" --save '' \
    --loadmodule "$BASE_MODULE" --daemonize no >/dev/null 2>&1 &
BASE_PID=$!
"${SERVER_PIN[@]}" "$SERVER" --port "$CAND_PORT" --dir "$CAND_DATADIR" --save '' \
    --loadmodule "$CAND_MODULE" --daemonize no >/dev/null 2>&1 &
CAND_PID=$!

cleanup() {
    echo "==> Shutting down servers (pids ${BASE_PID}, ${CAND_PID})"
    kill "$BASE_PID" "$CAND_PID" 2>/dev/null || true
    wait "$BASE_PID" "$CAND_PID" 2>/dev/null || true
    rm -rf "$BASE_DATADIR" "$CAND_DATADIR"
}
trap cleanup EXIT

vcli() { local port="$1"; shift; "$CLI" -h "$HOST" -p "$port" "$@"; }

# --- wait until both are ready ----------------------------------------------
echo "==> Waiting for servers to become ready"
for port in "$BASE_PORT" "$CAND_PORT"; do
    for _ in $(seq 1 30); do
        if vcli "$port" ping 2>/dev/null | grep -q PONG; then break; fi
        sleep 0.2
    done
    vcli "$port" ping | grep -q PONG || { echo "ERROR: server on $port not ready" >&2; exit 1; }
done
echo "    both servers up"

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

# (re)build the index and load exactly N documents into the server on $port.
# IMPORTANT: load the data FIRST, then create the index. Mass-inserting via
# `valkey-cli --pipe` while an index already exists overruns the module's write
# path and stalls the server. Creating the index afterward triggers a bulk
# backfill that scans existing keys, which is stable even at 100k docs.
populate() {
    local port="$1" n="$2"
    vcli "$port" FT.DROPINDEX idx >/dev/null 2>&1 || true
    vcli "$port" flushall >/dev/null

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
    }' | "$CLI" -h "$HOST" -p "$port" --pipe >/dev/null

    vcli "$port" FT.CREATE idx ON HASH PREFIX 1 hash: SCHEMA body TEXT price NUMERIC color TAG >/dev/null

    # backfill is async; wait until it reports complete before benchmarking
    for _ in $(seq 1 600); do
        local pct
        pct=$(vcli "$port" FT.INFO idx | grep -A1 backfill_complete_percent | tail -n1)
        [[ "$pct" == "1" || "$pct" == "1.000000" ]] && return
        sleep 0.1
    done
}

# --- query scenarios --------------------------------------------------------
# Each scenario is (name, query, extra FT.SEARCH arguments). The extra arguments
# are command flags such as INORDER or SLOP, which are not query syntax and so
# cannot be folded into the query string.
declare -a NAMES=() QUERIES=() EXTRA_ARGS=()
add_scenario() { NAMES+=("$1"); QUERIES+=("$2"); EXTRA_ARGS+=("${3:-}"); }

if [[ "$SCENARIOS" == "text" || "$SCENARIOS" == "all" ]]; then
    add_scenario "single word"        "apple"
    add_scenario "two words (AND)"    "apple banana"
    add_scenario "three words (AND)"  "apple banana cherry"
    add_scenario "OR of two"          "apple | banana"
    add_scenario "OR of three"        "apple | banana | cherry"
    add_scenario "text+num+tag"       "apple @price:[1 250] @color:{red}"
    add_scenario "2w AND+num+tag"     "apple banana @price:[1 250] @color:{red}"
    add_scenario "2w OR+num+tag"      "(apple | banana) @price:[1 250] @color:{red}"
fi
if [[ "$SCENARIOS" == "positional" || "$SCENARIOS" == "all" ]]; then
    # Every row here makes the text leaves positional, so the per-key position
    # merge runs on every candidate. The text set above never reaches it.
    add_scenario "phrase"             '"apple banana"'
    add_scenario "2w INORDER"         "apple banana"                      "INORDER"
    add_scenario "2w SLOP 0"          "apple banana"                      "SLOP 0"
    add_scenario "2w SLOP 2"          "apple banana"                      "SLOP 2"
    add_scenario "OR of two INORDER"  "apple | banana"                    "INORDER"
    add_scenario "prefix+word INORDER" "appl* banana"                     "INORDER"
    add_scenario "phrase+num+tag"     '"apple banana" @price:[1 250] @color:{red}'
fi
if [[ ${#NAMES[@]} -eq 0 ]]; then
    echo "ERROR: SCENARIOS must be text, positional or all (got '$SCENARIOS')" >&2
    exit 2
fi

# one benchmark run on $port -> "<rps> <p50>", parsed from the summary line.
# Client is pinned off the server core and a warmup pass is not recorded.
run_bench_once() {
    local port="$1" conn="$2" query="$3" extra="$4"
    # $extra is intentionally unquoted: "SLOP 2" must become two arguments.
    # shellcheck disable=SC2086
    "${CLIENT_PIN[@]}" "$BENCH" -h "$HOST" -p "$port" -n "$REQUESTS" -c "$conn" \
        --warmup "$WARMUP" --precision "$PRECISION" -q \
        FT.SEARCH idx "$query" $extra 2>/dev/null \
        | grep "requests per second" | tail -n1 \
        | sed -E 's/.*: ([0-9.]+) requests per second.*p50=([0-9.]+).*/\1 \2/'
}

# median of a stream of numbers on stdin (one per line)
median() {
    sort -n | awk '{ v[NR]=$1 } END { if (NR) { m=int((NR+1)/2); print v[m] } }'
}

# Benchmark baseline and candidate on the same scenario, INTERLEAVED and PAIRED:
# each repeat runs A then B back-to-back, and we record that repeat's delta
# (B vs A) immediately. Because the two halves of a pair run ~1s apart they see
# almost the same clock/thermal/neighbour state, so the *paired* delta cancels
# drift that a per-side median would leave in. We then report the median paired
# delta -- NOT the delta of two independently-taken medians (that reintroduces
# the noise interleaving was meant to remove). Representative absolute rps/p50
# (for display only) are the medians of each side. Sets globals
# B_RPS/B_P50/C_RPS/C_P50 and RPS_DELTA/P50_DELTA.
run_pair() {
    local conn="$1" query="$2" extra="$3"
    local b_rps=() b_p50=() c_rps=() c_p50=() rps_d=() p50_d=()
    for _ in $(seq 1 "$REPEATS"); do
        local br bp cr cp
        read -r br bp < <(run_bench_once "$BASE_PORT" "$conn" "$query" "$extra")
        read -r cr cp < <(run_bench_once "$CAND_PORT" "$conn" "$query" "$extra")
        br="${br:-0}"; bp="${bp:-0}"; cr="${cr:-0}"; cp="${cp:-0}"
        b_rps+=("$br"); b_p50+=("$bp"); c_rps+=("$cr"); c_p50+=("$cp")
        # per-pair signed % deltas (candidate relative to baseline)
        rps_d+=("$(awk -v a="$br" -v b="$cr" 'BEGIN{ if(a+0==0){print "nan"}else{printf "%.4f",(b-a)/a*100} }')")
        p50_d+=("$(awk -v a="$bp" -v b="$cp" 'BEGIN{ if(a+0==0){print "nan"}else{printf "%.4f",(b-a)/a*100} }')")
    done
    B_RPS="$(printf '%s\n' "${b_rps[@]}" | median)"; B_RPS="${B_RPS:-0}"
    B_P50="$(printf '%s\n' "${b_p50[@]}" | median)"; B_P50="${B_P50:-0}"
    C_RPS="$(printf '%s\n' "${c_rps[@]}" | median)"; C_RPS="${C_RPS:-0}"
    C_P50="$(printf '%s\n' "${c_p50[@]}" | median)"; C_P50="${C_P50:-0}"
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
    populate "$BASE_PORT" "$docs"
    populate "$CAND_PORT" "$docs"
    for side in BASE CAND; do
        port_var="${side}_PORT"; name_var="${side}_NAME"
        echo "   ${!name_var}: DBSIZE=$(vcli "${!port_var}" dbsize)," \
             "apple matches=$(vcli "${!port_var}" FT.SEARCH idx 'apple' | head -n1)," \
             "phrase matches=$(vcli "${!port_var}" FT.SEARCH idx '"apple banana"' | head -n1)"
    done

    for conn in "${CONN_COUNTS[@]}"; do
        echo
        echo "  --- c=${conn} connections --- (rps higher=better, p50 ms lower=better)"
        printf "  %-20s %-20s %-20s %10s %10s\n" \
            "scenario" "${BASE_NAME} rps(p50)" "${CAND_NAME} rps(p50)" "rps Δ%" "p50 Δ%"

        for i in "${!QUERIES[@]}"; do
            run_pair "$conn" "${QUERIES[$i]}" "${EXTRA_ARGS[$i]}"
            # deltas are the MEDIAN of per-pair (interleaved) deltas, so drift
            # cancels: negative rps = candidate slower; positive p50 = worse
            printf "  %-20s %-20s %-20s %10s %10s\n" \
                "${NAMES[$i]}" \
                "$(printf '%.0f (%.2f)' "$B_RPS" "$B_P50")" \
                "$(printf '%.0f (%.2f)' "$C_RPS" "$C_P50")" \
                "$(fmt_delta "$RPS_DELTA")" \
                "$(fmt_delta "$P50_DELTA")"
        done
    done
done

echo
echo "==> Δ% columns are ${CAND_NAME} relative to ${BASE_NAME}:"
echo "      rps Δ%  : negative = ${CAND_NAME} has lower throughput (worse)"
echo "      p50 Δ%  : positive = ${CAND_NAME} has higher latency (worse)"
echo "==> Done. Full log saved to ${OUTFILE}"
