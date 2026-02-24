#!/bin/bash
# ============================================================================
# r_orphan_report.sh v4.3
# Report sysadmin: orfani attivi, storico per utente e tipo
#
# CHANGES v4.3:
# 1. FIXED TRUNCATION: Uses 'id -nu' to resolve full usernames (matches cleanup v4.8).
# 2. ALIGNED SAFETY LOGIC: PPID=1 processes are reported as "OK (Detached/Safe)"
#    if the user has an active session. They are only "ORPHAN" if no session exists.
#
# Per BIOME-CALC - 137.204.21.170
# ============================================================================

CONF_FILE="/usr/local/custom/rstudio/conf/r_orphan_cleanup.conf"
HELPERS="/usr/local/custom/rstudio/script/orphan_cleanup_helpers.sh"

if [ ! -f "$CONF_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | Config not found: $CONF_FILE" >&2
    exit 1
fi
if [ ! -f "$HELPERS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | Helpers not found: $HELPERS" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"
# shellcheck source=/dev/null
source "$HELPERS"

SEND_MAIL=0
[ "${1:-}" = "--mail" ] && SEND_MAIL=1

# ── Costruisci grep pattern ───────────────────────────────────
GREP_PATTERN=""
for ENTRY in "${ORPHAN_PATTERNS[@]}"; do
    GP="${ENTRY%%|*}"
    if [ -z "$GREP_PATTERN" ]; then
        GREP_PATTERN="$GP"
    else
        GREP_PATTERN="${GREP_PATTERN}|${GP}"
    fi
done

# ── Function: Check Safety (Same as cleanup v4.8) ─────────────
check_is_safe() {
    local PPID="$1"
    local UID="$2"
    
    # Case 1: Active Parent (Not Init)
    if [ "$PPID" -ne 1 ] && ps -p "$PPID" > /dev/null 2>&1; then
        return 0 # Safe (Normal child)
    fi

    # Case 2: Parent is Init (1) OR Dead
    # CHECK SAFETY NET: Does user have active rsession?
    if pgrep -u "$UID" -f "rsession" > /dev/null 2>&1; then
        return 0 # Safe (Active Session)
    fi

    return 1 # Not Safe (True Orphan)
}

generate_report() {

echo "================================================================"
echo "  BIOME-CALC - Report Processi Orfani v4.3"
echo "  Generato: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Server:   $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
echo "  Pattern monitorati: ${#ORPHAN_PATTERNS[@]}"
echo "================================================================"
echo ""

# ── Orfani attivi ora (REAL Orphans) ──────────────────────────
echo "-- ORFANI ATTIVI ORA (DA TERMINARE) -----------------------------"
echo ""

ORPHAN_COUNT=0
# ps output: pid, ppid, uid, user, etime, args
ps -eo pid,ppid,uid,user,etime,args --no-headers 2>/dev/null | \
    grep -E "$GREP_PATTERN" | grep -v grep | grep -v cleanup_r_orphans | \
while IFS= read -r LINE; do
    PROC_PID=$(echo "$LINE"    | awk '{print $1}')
    PARENT_PID=$(echo "$LINE"  | awk '{print $2}')
    PROC_UID=$(echo "$LINE"    | awk '{print $3}')
    PROC_USER_RAW=$(echo "$LINE" | awk '{print $4}')
    PROC_ETIME=$(echo "$LINE"  | awk '{print $5}')
    PROC_CMD=$(echo "$LINE"    | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}')

    # Resolve Full Username
    FULL_USER=$(id -nu "$PROC_UID" 2>/dev/null)
    [ -z "$FULL_USER" ] && FULL_USER="$PROC_USER_RAW"

    # Check Safety
    check_is_safe "$PARENT_PID" "$PROC_UID"
    IS_SAFE=$?

    if [ "$IS_SAFE" -eq 1 ]; then
        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        
        TYPE="sconosciuto"
        for ENTRY in "${ORPHAN_PATTERNS[@]}"; do
            GP="${ENTRY%%|*}"
            LB="${ENTRY##*|}"
            if echo "$PROC_CMD" | grep -qE "$GP"; then
                TYPE="$LB"
                break
            fi
        done
        printf "  !! %-25s PID %-8s %-20s attivo da %s\n" "$TYPE" "$PROC_PID" "$FULL_USER" "$PROC_ETIME"
    fi
done

if [ "$ORPHAN_COUNT" -eq 0 ]; then
    echo "  Nessuno (OK)"
fi
echo ""

# ── Tutti i processi monitorati attivi ────────────────────────
echo "-- TUTTI I PROCESSI MONITORATI ATTIVI ---------------------------"
echo ""
# Use temp file to handle loop output properly
TMP_LIST=$(mktemp)

ps -eo pid,ppid,uid,user,etime,args --no-headers 2>/dev/null | \
    grep -E "$GREP_PATTERN" | grep -v grep | grep -v cleanup_r_orphans > "$TMP_LIST"

if [ ! -s "$TMP_LIST" ]; then
    echo "  Nessun processo monitorato attivo (OK)"
else
    printf "  %-20s %-8s %-8s %-12s %s\n" "UTENTE" "PID" "PPID" "ATTIVO DA" "STATO"
    echo "  ------------------------------------------------------------------------"
    while IFS= read -r LINE; do
        PROC_PID=$(echo "$LINE"    | awk '{print $1}')
        PARENT_PID=$(echo "$LINE"  | awk '{print $2}')
        PROC_UID=$(echo "$LINE"    | awk '{print $3}')
        PROC_USER_RAW=$(echo "$LINE" | awk '{print $4}')
        PROC_ETIME=$(echo "$LINE"  | awk '{print $5}')
        
        # Resolve Full Username
        FULL_USER=$(id -nu "$PROC_UID" 2>/dev/null)
        [ -z "$FULL_USER" ] && FULL_USER="$PROC_USER_RAW"

        # Logic for Status Label
        if [ "$PARENT_PID" -eq 1 ]; then
            # PPID 1: Check if Safe via Session
            if pgrep -u "$PROC_UID" -f "rsession" > /dev/null 2>&1; then
                STATUS="OK (Detached/Safe)"
            else
                STATUS="!! ORFANO (ppid=1, No Session)"
            fi
        elif ! ps -p "$PARENT_PID" > /dev/null 2>&1; then
             # Parent Dead: Check if Safe via Session
            if pgrep -u "$PROC_UID" -f "rsession" > /dev/null 2>&1; then
                STATUS="OK (Parent Dead/Safe)"
            else
                STATUS="!! ORFANO (parent morto)"
            fi
        else
            STATUS="OK (parent=$PARENT_PID)"
        fi
        
        printf "  %-20s %-8s %-8s %-12s %s\n" "${FULL_USER:0:20}" "$PROC_PID" "$PARENT_PID" "$PROC_ETIME" "$STATUS"
    done < "$TMP_LIST"
fi
rm -f "$TMP_LIST"
echo ""

# ── Storico dal log ───────────────────────────────────────────
if [ -f "$LOG_FILE" ]; then

    echo "-- TOP UTENTI (storico) ---------------------------------------"
    echo ""
    printf "  %-8s %-25s %s\n" "ORFANI" "UTENTE" "TIPO PIU FREQUENTE"
    echo "  -----------------------------------------------------------"
    grep "KILLED" "$LOG_FILE" | grep -oP 'user=\K[^ |]+' | sort | uniq -c | sort -rn | head -15 | \
    while read -r COUNT UNAME; do
        FREQ_TYPE=$(grep "user=${UNAME}" "$LOG_FILE" | grep -oP 'type=\K[^|]+' | \
            sed 's/ *$//' | sort | uniq -c | sort -rn | head -1 | \
            awk '{for(i=2;i<=NF;i++) printf "%s ", $i}')
        printf "  %-8s %-25s %s\n" "$COUNT" "$UNAME" "$FREQ_TYPE"
    done
    echo ""

    echo "-- ORFANI PER TIPO (storico) ----------------------------------"
    echo ""
    printf "  %-8s %s\n" "COUNT" "TIPO"
    echo "  -----------------------------------------------------------"
    grep "KILLED" "$LOG_FILE" | grep -oP 'type=\K[^|]+' | sed 's/ *$//' | \
        sort | uniq -c | sort -rn | while read -r COUNT TYPE; do
        printf "  %-8s %s\n" "$COUNT" "$TYPE"
    done
    echo ""

    echo "-- ULTIMI 20 KILL ---------------------------------------------"
    echo ""
    printf "  %-20s %-25s %-20s %-8s %s\n" "DATA" "TIPO" "UTENTE" "PID" "ATTIVO DA"
    echo "  -----------------------------------------------------------"
    grep "KILLED" "$LOG_FILE" | tail -20 | while IFS='|' read -r TS _ REST; do
        TYPE=$(echo "$REST" | grep -oP 'type=\K[^|]+' | sed 's/ *$//')
        UNAME=$(echo "$REST" | grep -oP 'user=\K[^|]+' | sed 's/ *$//')
        PROC_PID=$(echo "$REST" | grep -oP 'pid=\K[^|]+' | sed 's/ *$//')
        ELAPSED=$(echo "$REST" | grep -oP 'elapsed=\K[^|]+' | sed 's/ *$//')
        printf "  %-20s %-25s %-20s %-8s %s\n" "$(echo "$TS" | xargs)" "$TYPE" "$UNAME" "$PROC_PID" "$ELAPSED"
    done
    echo ""

    echo "-- NOTIFICHE PENDENTI -----------------------------------------"
    echo ""
    PENDING=$(ls -1 "${NOTIFY_DIR}"/*.log 2>/dev/null | grep -v '\.sent' || true)
    if [ -z "$PENDING" ]; then
        echo "  Nessuna (OK)"
    else
        for F in ${PENDING}; do
            UNAME=$(basename "$F" .log)
            # Filter bad filenames
            if [[ "$UNAME" == *"+" ]]; then continue; fi
            UCOUNT=$(grep -c "PROCESSO ORFANO TERMINATO" "$F" 2>/dev/null || echo 0)
            printf "  %-25s %s orfani pendenti\n" "$UNAME" "$UCOUNT"
        done
    fi
fi

echo ""
echo "-- DESTINATARI ADMIN CONFIGURATI --------------------------------"
echo ""
ADMIN_RESOLVED=$(resolve_admin_recipients "$ADMIN_EMAIL")
if [ -z "$ADMIN_RESOLVED" ]; then
    echo "  !! NESSUN DESTINATARIO CONFIGURATO"
    echo "  Controlla ADMIN_EMAIL in: $CONF_FILE"
else
    echo "$ADMIN_RESOLVED" | tr ',' '\n' | while read -r ADDR; do
        echo "  - $ADDR"
    done
fi

echo ""
echo "-- PATTERN CONFIGURATI ------------------------------------------"
echo ""
for ENTRY in "${ORPHAN_PATTERNS[@]}"; do
    GP="${ENTRY%%|*}"
    LB="${ENTRY##*|}"
    printf "  %-35s -> %s\n" "$LB" "$GP"
done

echo ""
echo "================================================================"
echo "Log:       ${LOG_FILE}"
echo "Notifiche: ${NOTIFY_DIR}/"
echo "Conf:      ${CONF_FILE}"
echo "================================================================"

}

# ── Output ────────────────────────────────────────────────────
if [ "$SEND_MAIL" -eq 1 ]; then
    ADMIN_RESOLVED=$(resolve_admin_recipients "$ADMIN_EMAIL")
    if [ -z "$ADMIN_RESOLVED" ]; then
        echo "ERRORE: nessun destinatario admin configurato." >&2
        exit 1
    fi

    REPORT_FILE=$(mktemp /tmp/r_orphan_report_XXXXXX.txt)
    generate_report > "$REPORT_FILE"

    if [ -x "$SEND_EMAIL_SCRIPT" ]; then
        "$SEND_EMAIL_SCRIPT" \
            -s "$SMTP_HOST" -p "$SMTP_PORT" -f "$SENDER_EMAIL" \
            -T "$ADMIN_RESOLVED" \
            -u "[BIOME-CALC] Report processi orfani $(date '+%Y-%m-%d')" \
            -m "$REPORT_FILE" -d "$DNS_SERVERS" -L "r-orphan-report" \
        && echo "Report inviato a: ${ADMIN_RESOLVED}" \
        || echo "ERRORE invio report" >&2
    else
        echo "ERRORE: send_email.sh non trovato: $SEND_EMAIL_SCRIPT" >&2
        cat "$REPORT_FILE"
    fi
    rm -f "$REPORT_FILE"
else
    generate_report
fi
