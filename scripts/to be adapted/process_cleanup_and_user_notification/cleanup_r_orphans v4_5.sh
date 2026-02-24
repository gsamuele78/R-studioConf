#!/bin/bash
# ============================================================================
# cleanup_r_orphans.sh v4.5
#
# CHANGES v4.5:
# 1. DEEP ANCESTRY CHECK: Loops up to 5 levels to find parent 'rsession'.
#    Fixes "False Positives" for nested workers (future/callr/clustermq).
# 2. POWER USER SUPPORT: Adds tmux, screen, sshd to valid parents list.
#    Ensures terminal-based long-running jobs are NOT killed.
# 3. ZOMBIE FILTER: Skips true <defunct> processes.
# 4. SAFETY: Checks if parent is PID 1 (Init) to confirm orphan status.
# 5. TIMEOUT: Grace period 15s for data flush before SIGKILL.
#
# Per BIOME-CALC - 137.204.21.170
# ============================================================================

CONF_FILE="/usr/local/custom/rstudio/conf/r_orphan_cleanup.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | Config not found: $CONF_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONF_FILE"

# --- Safety & Tuning ---
# Timeout waiting for SIGTERM to work (seconds)
# Heavy data writes need more time (15s+)
KILL_TIMEOUT=15

# How many levels up to check for a valid 'rsession' parent
MAX_PARENT_DEPTH=5

mkdir -p "$LOG_DIR" "$NOTIFY_DIR"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

etime_to_seconds() {
    local ET="$1"
    local DAYS=0 HOURS=0 MINS=0 SECS=0
    if [[ "$ET" == *-* ]]; then
        DAYS="${ET%%-*}"; ET="${ET##*-}"
    fi
    IFS=':' read -ra PARTS <<< "$ET"
    local N=${#PARTS[@]}
    if [ "$N" -eq 3 ]; then
        HOURS=$((10#${PARTS[0]})); MINS=$((10#${PARTS[1]})); SECS=$((10#${PARTS[2]}))
    elif [ "$N" -eq 2 ]; then
        MINS=$((10#${PARTS[0]})); SECS=$((10#${PARTS[1]}))
    elif [ "$N" -eq 1 ]; then
        SECS=$((10#${PARTS[0]}))
    fi
    echo $(( DAYS*86400 + HOURS*3600 + MINS*60 + SECS ))
}

# Rotate Log if needed
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d_%H%M%S').old"
    log_msg "INFO | Log rotated"
fi

build_grep_pattern() {
    local PATTERN=""
    for ENTRY in "${ORPHAN_PATTERNS[@]}"; do
        local GREP_PART="${ENTRY%%|*}"
        if [ -z "$PATTERN" ]; then PATTERN="$GREP_PART"; else PATTERN="${PATTERN}|${GREP_PART}"; fi
    done
    echo "$PATTERN"
}

classify_worker() {
    local CMD="$1"
    for ENTRY in "${ORPHAN_PATTERNS[@]}"; do
        local GREP_PART="${ENTRY%%|*}"
        local LABEL="${ENTRY##*|}"
        if echo "$CMD" | grep -qE "$GREP_PART"; then echo "$LABEL"; return; fi
    done
    echo "unknown"
}

is_excluded() {
    local CMD="$1"
    for EXCL in "${EXCLUDE_PATTERNS[@]}"; do
        if echo "$CMD" | grep -qi "$EXCL"; then return 0; fi
    done
    return 1
}

# ----------------------------------------------------------------------------
# CORE LOGIC: Deep Ancestry Check
# Returns 0 (TRUE) if process is an ORPHAN (no valid parent found).
# Returns 1 (FALSE) if process is SAFE (valid parent found).
# ----------------------------------------------------------------------------
check_is_orphan() {
    local CURRENT_PID="$1"
    local DEPTH=0
    
    # 1. Immediate Parent Check: Is it Init?
    # If a process is reparented to PID 1, it is almost certainly an orphan
    # unless it is a system service (excluded by patterns).
    local IMMEDIATE_PPID
    IMMEDIATE_PPID=$(ps -o ppid= -p "$CURRENT_PID" 2>/dev/null | tr -d ' ')
    
    if [ "$IMMEDIATE_PPID" -eq 1 ]; then
        # Confirmed Orphan (Adopted by Init)
        return 0 
    fi

    # 2. Recursive Check: Climb the tree looking for a valid owner
    while [ "$DEPTH" -lt "$MAX_PARENT_DEPTH" ]; do
        
        # Stop if we hit root or invalid PID
        if [ -z "$CURRENT_PID" ] || [ "$CURRENT_PID" -eq 1 ] || [ "$CURRENT_PID" -eq 0 ]; then
            # We climbed to the top and found NO rsession. It's an orphan.
            return 0
        fi

        # Get Command of current ancestor
        local CURR_CMD
        CURR_CMD=$(ps -o args= -p "$CURRENT_PID" 2>/dev/null)
        
        if [ -z "$CURR_CMD" ]; then
             # Process vanished while checking
            return 0
        fi

        # VALIDATION: Is this an RStudio Session or Main R Process?
        # Matches: rsession, R (interactive), RStudio Server, rserver
        # ADDED v4.5: tmux, screen, sshd (for terminal-based long jobs)
        if echo "$CURR_CMD" | grep -qE 'rsession|/R\s|R --interactive|rstudio-server|rserver|tmux|screen|sshd'; then
            # FOUND OWNER! This process is SAFE.
            return 1 
        fi
        
        # Climb up one level
        local NEXT_PID
        NEXT_PID=$(ps -o ppid= -p "$CURRENT_PID" 2>/dev/null | tr -d ' ')
        
        CURRENT_PID="$NEXT_PID"
        DEPTH=$((DEPTH + 1))
    done

    # If we exceeded max depth without finding an owner, assume Orphan.
    return 0
}

get_suggestion() {
    local WORKER_TYPE="$1"
    case "$WORKER_TYPE" in
        *future*|*parallelly*)
            echo '    plan(multisession, workers = 4)'
            echo '    on.exit(plan(sequential), add = TRUE)' ;;
        *parallel*|*PSOCK*|*snow*|*BiocParallel*|*foreach*)
            echo '    cl <- makeCluster(4, type = "PSOCK")'
            echo '    on.exit(stopCluster(cl), add = TRUE)' ;;
        *tensorflow*|*keras*)
            echo '    on.exit(keras::k_clear_session(), add = TRUE)' ;;
        *rgee*|*earthengine*)
            echo '    on.exit(try(rgee::ee_clean_credentials(), silent=TRUE), add = TRUE)' ;;
        *)
            echo '    # Usa on.exit(...) per garantire il cleanup.' ;;
    esac
}

# ── Scan and Kill ───────────────────────────────────────────────
GREP_PATTERN=$(build_grep_pattern)

if [ -z "$GREP_PATTERN" ]; then
    log_msg "ERROR | No patterns configured"
    exit 1
fi

ORPHANS_FOUND=0

# Fetch process list with STATE (s) to filter Zombies (Z)
# pid, ppid, user, stat, lstart, etime, args
ps -eo pid,ppid,user,stat,lstart,etime,args --no-headers 2>/dev/null | \
    grep -E "$GREP_PATTERN" | \
    grep -v grep | \
    grep -v "cleanup_r_orphans" | \
while IFS= read -r LINE; do

    PROC_PID=$(echo "$LINE"    | awk '{print $1}')
    PARENT_PID=$(echo "$LINE"  | awk '{print $2}')
    PROC_USER=$(echo "$LINE"   | awk '{print $3}')
    PROC_STAT=$(echo "$LINE"   | awk '{print $4}')
    # Dates/Times (fields 5-9 roughly)
    PROC_START=$(echo "$LINE"  | awk '{print $5, $6, $7, $8, $9}')
    PROC_ETIME=$(echo "$LINE"  | awk '{print $10}')
    # Command (rest of line)
    PROC_CMD=$(echo "$LINE"    | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')

    # 1. SKIP TECHNICAL ZOMBIES (Defunct)
    # You cannot kill a zombie; you must kill its parent.
    if [[ "$PROC_STAT" == *"Z"* ]] || [[ "$PROC_CMD" == *"<defunct>"* ]]; then
        continue
    fi

    is_excluded "$PROC_CMD" && continue

    WORKER_TYPE=$(classify_worker "$PROC_CMD")

    # 2. DEEP ORPHAN CHECK
    check_is_orphan "$PROC_PID"
    IS_ORPHAN=$?
    
    # If IS_ORPHAN returns 1, it means it found a parent -> SAFE -> Skip
    if [ "$IS_ORPHAN" -eq 1 ]; then
        continue
    fi

    # 3. AGE CHECK
    AGE_SEC=$(etime_to_seconds "$PROC_ETIME")
    [ "$AGE_SEC" -lt "$MIN_AGE_SECONDS" ] && continue

    ORPHANS_FOUND=$((ORPHANS_FOUND + 1))

    log_msg "KILLED | type=${WORKER_TYPE} | user=${PROC_USER} | pid=${PROC_PID} | ppid=${PARENT_PID} | started=${PROC_START} | elapsed=${PROC_ETIME}"

    # Notification File
    USER_NOTIFY="${NOTIFY_DIR}/${PROC_USER}.log"
    {
        echo "────────────────────────────────────────────────────"
        echo "  PROCESSO ORFANO TERMINATO"
        echo "  Data:      $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Tipo:      ${WORKER_TYPE}"
        echo "  PID:       ${PROC_PID} (parent: ${PARENT_PID})"
        echo "  Comando:   ${PROC_CMD}"
        echo "  Suggerimento:"
        get_suggestion "$WORKER_TYPE"
        echo "────────────────────────────────────────────────────"
    } >> "$USER_NOTIFY"

    # System Logger
    logger -t r-orphan-cleanup "Killed orphan ${WORKER_TYPE}: user=${PROC_USER} pid=${PROC_PID}"

    # 4. ESCALATED KILL SEQUENCE
    # Step A: SIGTERM (Polite kill)
    kill -TERM "$PROC_PID" 2>/dev/null
    
    # Step B: Wait for Data Flush (Critical for Big Data)
    sleep "$KILL_TIMEOUT"
    
    # Step C: SIGKILL (Force kill) if process persists
    if kill -0 "$PROC_PID" 2>/dev/null; then
        kill -KILL "$PROC_PID" 2>/dev/null
        log_msg "FORCE  | pid=${PROC_PID} required SIGKILL after ${KILL_TIMEOUT}s"
    fi

done

if [ "$ORPHANS_FOUND" -gt 0 ]; then
    log_msg "SUMMARY | Orphans killed this run: ${ORPHANS_FOUND}"
fi
