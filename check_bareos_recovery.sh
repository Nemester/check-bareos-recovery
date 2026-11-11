#!/usr/bin/env bash
# ==============================================================================
#:
#: check_bareos_recovery.sh
#: Checks available recovery points (successful backups) for a Bareos job.
#: Supports both human-readable and Icinga/Nagios monitoring plugin modes.
#:
#: Usage:
#:   ./check_bareos_recovery.sh -j <jobname> [OPTIONS]
#:
#: Options:
#:   -j <jobname>    Name of the Bareos job to check (required)
#:   -d <days>       Look back this many days (default: 30)
#:   -m <min_count>  Minimum required recovery points, sets WARNING threshold (default: 1)
#:   -c <crit_count> Critical threshold: below this count → CRITICAL (default: 0, disabled)
#:   -M              Monitoring mode: Icinga/Nagios-compatible output and exit codes
#:   -p              Include perfdata in output (only useful with -M)
#:   -l              List all found recovery points with details (human mode only)
#:   -h              Show this help message
#:
#: Exit codes (standard / monitoring mode):
#:   Human:      0=OK  1=below minimum  2=none found  3=error
#:   Monitoring: 0=OK  1=WARNING        2=CRITICAL     3=UNKNOWN
#:
#: Perfdata format (with -M -p):
#:   successful=N;warn;crit  failed=N  lookback_days=N
#: 
#: Author
#:   Manuel Sonder
#: 
#: Version 1.0
#: 
#: License
#:   MIT (see LICENSE file)
#:   SPDX-License-Identifier: MIT
#: 
# ==============================================================================

set -euo pipefail

# ---------- defaults ----------------------------------------------------------
DAYS=30
MIN_COUNT=1
CRIT_COUNT=0
LIST_JOBS=false
MONITORING=false
PERFDATA=false
JOB_NAME=""
BCONSOLE_CMD="bconsole"
BCONSOLE_CONF="/etc/bareos/bconsole.conf"

# ---------- colours (suppressed in monitoring mode) ---------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- helpers -----------------------------------------------------------
usage() {
    grep '^#:' "$0" | sed 's/^#: \{0,2\}//' | sed '1d'
    exit 0
}

# In monitoring mode: plain stdout, no colours, single-line, then exit.
# In human mode: coloured multi-line output, then exit.
mon_exit() {
    local state=$1   # 0=OK 1=WARNING 2=CRITICAL 3=UNKNOWN
    local msg="$2"
    local perfdata="${3:-}"
    local labels=("OK" "WARNING" "CRITICAL" "UNKNOWN")
    if $MONITORING; then
        local out="${labels[$state]} - ${msg}"
        [[ -n "$perfdata" ]] && out+=" | ${perfdata}"
        echo "$out"
        exit "$state"
    fi
}

die() {
    if $MONITORING; then
        echo "BAREOS UNKNOWN - $*"
        exit 3
    else
        echo -e "${RED}ERROR: $*${NC}" >&2
        exit 3
    fi
}

info() { $MONITORING || echo -e "${CYAN}INFO:${NC}  $*"; }
ok()   { $MONITORING || echo -e "${GREEN}OK:${NC}    $*"; }
warn() { $MONITORING || echo -e "${YELLOW}WARN:${NC}  $*"; }

# ---------- parse args --------------------------------------------------------
while getopts ":j:d:m:c:Mplh" opt; do
    case $opt in
        j) JOB_NAME="$OPTARG" ;;
        d) DAYS="$OPTARG" ;;
        m) MIN_COUNT="$OPTARG" ;;
        c) CRIT_COUNT="$OPTARG" ;;
        M) MONITORING=true ;;
        p) PERFDATA=true ;;
        l) LIST_JOBS=true ;;
        h) usage ;;
        :) die "Option -$OPTARG requires an argument." ;;
        \?) die "Unknown option: -$OPTARG" ;;
    esac
done

[[ -z "$JOB_NAME" ]] && die "Job name is required. Use -j <jobname> (or -h for help)."
[[ "$DAYS"      =~ ^[0-9]+$ ]] || die "-d must be a positive integer."
[[ "$MIN_COUNT" =~ ^[0-9]+$ ]] || die "-m must be a positive integer."
[[ "$CRIT_COUNT" =~ ^[0-9]+$ ]] || die "-c must be a positive integer."

# ---------- check bconsole ----------------------------------------------------
if ! command -v "$BCONSOLE_CMD" &>/dev/null; then
    die "bconsole not found in PATH."
fi

BCONSOLE_OPTS=()
[[ -f "$BCONSOLE_CONF" ]] && BCONSOLE_OPTS+=("-c" "$BCONSOLE_CONF")

if ! echo "quit" | "$BCONSOLE_CMD" "${BCONSOLE_OPTS[@]}" &>/dev/null; then
    die "Could not connect to Bareos Director via bconsole."
fi

# ---------- query Bareos ------------------------------------------------------
SINCE_DATE=$(date -d "-${DAYS} days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
          || date -v-"${DAYS}"d '+%Y-%m-%d %H:%M:%S')

info "Querying job '${JOB_NAME}' for successful backups in the last ${DAYS} day(s)..."

RAW_OUTPUT=$(printf 'list jobs job=%s\nquit\n' "$JOB_NAME" \
    | "$BCONSOLE_CMD" "${BCONSOLE_OPTS[@]}" 2>&1) || die "bconsole query failed."

# ---------- detect column positions from header row ---------------------------
HEADER_LINE=$(echo "$RAW_OUTPUT" | grep -i '| *jobid')

if [[ -z "$HEADER_LINE" ]]; then
    die "Could not find table header in bconsole output."
fi

get_col_index() {
    local header="$1" field="$2" idx=0
    while IFS='|' read -ra cols; do
        for col in "${cols[@]}"; do
            if echo "$col" | grep -qi "^[[:space:]]*${field}[[:space:]]*$"; then
                echo "$idx"; return
            fi
            (( idx++ ))
        done
    done <<< "$header"
    echo "-1"
}

COL_JOBID=$(get_col_index  "$HEADER_LINE" "JobId")
COL_START=$(get_col_index  "$HEADER_LINE" "StartTime")
COL_STATUS=$(get_col_index "$HEADER_LINE" "JobStatus")
COL_FILES=$(get_col_index  "$HEADER_LINE" "JobFiles")
COL_BYTES=$(get_col_index  "$HEADER_LINE" "JobBytes")

# Fallback to standard Bareos column order:
# | JobId | Name | Client | StartTime | Duration | Type | Level | JobFiles | JobBytes | JobStatus |
#     1      2       3         4           5         6      7        8          9           10
[[ "$COL_JOBID"  == "-1" ]] && COL_JOBID=1
[[ "$COL_START"  == "-1" ]] && COL_START=4
[[ "$COL_STATUS" == "-1" ]] && COL_STATUS=10
[[ "$COL_FILES"  == "-1" ]] && COL_FILES=8
[[ "$COL_BYTES"  == "-1" ]] && COL_BYTES=9

# ---------- compute since epoch -----------------------------------------------
since_epoch=$(date -d "$SINCE_DATE" '+%s' 2>/dev/null \
           || date -j -f '%Y-%m-%d %H:%M:%S' "$SINCE_DATE" '+%s' 2>/dev/null \
           || echo 0)

# ---------- parse data rows ---------------------------------------------------
SUCCESSFUL=()
FAILED=()
LAST_SUCCESS=""
LAST_SUCCESS_FILES=0
LAST_SUCCESS_BYTES=0

while IFS= read -r line; do
    [[ "$line" =~ ^\|[[:space:]]*[0-9]+ ]] || continue

    IFS='|' read -ra fields <<< "$line"

    job_id=$(echo "${fields[$COL_JOBID]:-}"  | xargs)
    start=$(echo  "${fields[$COL_START]:-}"  | xargs)
    status=$(echo "${fields[$COL_STATUS]:-}" | xargs)
    files=$(echo  "${fields[$COL_FILES]:-}"  | xargs | tr -d ',')
    bytes=$(echo  "${fields[$COL_BYTES]:-}"  | xargs | tr -d ',')

    [[ -z "$job_id" || -z "$status" || -z "$start" ]] && continue

    job_epoch=$(date -d "$start" '+%s' 2>/dev/null \
             || date -j -f '%Y-%m-%d %H:%M:%S' "$start" '+%s' 2>/dev/null \
             || echo 0)
    [[ "$job_epoch" -lt "$since_epoch" ]] && continue

    if [[ "$status" == "T" ]]; then
        SUCCESSFUL+=("$job_id|$start|$files|$bytes")
        # Track the most recent successful job (rows are chronological)
        LAST_SUCCESS="$start"
        LAST_SUCCESS_FILES="${files:-0}"
        LAST_SUCCESS_BYTES="${bytes:-0}"
    elif [[ "$status" =~ ^[EfW]$ ]]; then
        FAILED+=("$job_id|$start|$status")
    fi

done <<< "$RAW_OUTPUT"

COUNT=${#SUCCESSFUL[@]}
FAIL_COUNT=${#FAILED[@]}

# ---------- build perfdata string ---------------------------------------------
build_perfdata() {
    # successful=<val>;<warn>;<crit>;0;
    # failed=<val>;;;;
    # lookback_days=<val>;;;;
    # age_hours=<val>;;;; (hours since last successful backup, or U if none)
    local warn_thresh="$MIN_COUNT"
    local crit_thresh="${CRIT_COUNT:-0}"
    [[ "$crit_thresh" -eq 0 ]] && crit_thresh=""

    local age_hours="U"
    if [[ -n "$LAST_SUCCESS" ]]; then
        local last_epoch now_epoch
        last_epoch=$(date -d "$LAST_SUCCESS" '+%s' 2>/dev/null \
                  || date -j -f '%Y-%m-%d %H:%M:%S' "$LAST_SUCCESS" '+%s' 2>/dev/null \
                  || echo 0)
        now_epoch=$(date '+%s')
        age_hours=$(( (now_epoch - last_epoch) / 3600 ))
    fi

    printf "successful=%d;%d;%s;0; failed=%d;;;; lookback_days=%d;;;; age_hours=%s;;;; last_files=%d;;;; last_bytes=%d;;;;" \
        "$COUNT" "$warn_thresh" "$crit_thresh" \
        "$FAIL_COUNT" \
        "$DAYS" \
        "$age_hours" \
        "$LAST_SUCCESS_FILES" \
        "$LAST_SUCCESS_BYTES"
}

# ---------- evaluate state ----------------------------------------------------
# Determine state so we can use it in both monitoring and human output
STATE=0   # OK
STATE_MSG=""

if [[ $COUNT -eq 0 ]]; then
    if [[ "$CRIT_COUNT" -gt 0 ]]; then
        STATE=2
    else
        STATE=2   # no backups at all is always at least CRITICAL
    fi
    STATE_MSG="No successful recovery points found for '${JOB_NAME}' in the last ${DAYS} day(s). Failed jobs: ${FAIL_COUNT}."
elif [[ "$CRIT_COUNT" -gt 0 && $COUNT -lt $CRIT_COUNT ]]; then
    STATE=2
    STATE_MSG="${COUNT} successful recovery point(s) for '${JOB_NAME}' — below CRITICAL threshold of ${CRIT_COUNT}. Last: ${LAST_SUCCESS}. Failed: ${FAIL_COUNT}."
elif [[ $COUNT -lt $MIN_COUNT ]]; then
    STATE=1
    STATE_MSG="${COUNT} successful recovery point(s) for '${JOB_NAME}' — below WARNING threshold of ${MIN_COUNT}. Last: ${LAST_SUCCESS}. Failed: ${FAIL_COUNT}."
else
    STATE=0
    STATE_MSG="${COUNT} successful recovery point(s) for '${JOB_NAME}' in the last ${DAYS} day(s). Last: ${LAST_SUCCESS}. Failed: ${FAIL_COUNT}."
fi

# ---------- monitoring mode output --------------------------------------------
if $MONITORING; then
    PERF=""
    $PERFDATA && PERF="$(build_perfdata)"
    mon_exit "$STATE" "$STATE_MSG" "$PERF"
fi

# ---------- human mode output -------------------------------------------------
echo ""
echo "========================================"
echo "  Bareos Recovery Point Report"
echo "========================================"
printf "  Job Name      : %s\n" "$JOB_NAME"
printf "  Lookback      : %d days (since %s)\n" "$DAYS" "$SINCE_DATE"
printf "  Min. Required : %d\n" "$MIN_COUNT"
[[ "$CRIT_COUNT" -gt 0 ]] && printf "  Crit. Threshold: %d\n" "$CRIT_COUNT"
echo "----------------------------------------"
printf "  Successful backups : %d\n" "$COUNT"
printf "  Failed/errored     : %d\n" "$FAIL_COUNT"
[[ -n "$LAST_SUCCESS" ]] && printf "  Last successful    : %s\n" "$LAST_SUCCESS"
echo "========================================"
echo ""

if $LIST_JOBS && [[ $COUNT -gt 0 ]]; then
    echo "  Recovery Points (most recent first):"
    echo "  ----------------------------------------"
    for (( i=${#SUCCESSFUL[@]}-1; i>=0; i-- )); do
        IFS='|' read -r jid jtime jfiles jbytes <<< "${SUCCESSFUL[$i]}"
        printf "  [%3d]  JobID: %-8s  Started: %-22s  Files: %-8s  Bytes: %s\n" \
            "$((${#SUCCESSFUL[@]}-i))" "$jid" "$jtime" "$jfiles" "$jbytes"
    done
    echo ""
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
    warn "${FAIL_COUNT} failed/errored job(s) in the same window:"
    for entry in "${FAILED[@]}"; do
        IFS='|' read -r jid jtime jst <<< "$entry"
        printf "         JobID: %-8s  Started: %s  Status: %s\n" "$jid" "$jtime" "$jst"
    done
    echo ""
fi

if $PERFDATA; then
    echo "  Perfdata: $(build_perfdata)"
    echo ""
fi

case $STATE in
    0) ok  "$STATE_MSG" ;;
    1) warn "$STATE_MSG" ;;
    2) warn "$STATE_MSG" ;;
esac

exit $STATE
