#!/bin/bash
# ============================================================================
# orphan_cleanup_helpers.sh
# Funzioni condivise per il sistema di cleanup worker R orfani
# Posizione: /usr/local/custom/rstudio/script/orphan_cleanup_helpers.sh
#
# Per BIOME-CALC - 137.204.21.170
# ============================================================================

# ── Risolvi ADMIN_EMAIL in lista CSV di indirizzi ─────────────
# Supporta tre formati:
#   file:///path/to/file.txt  → legge indirizzi dal file
#   addr1,addr2,addr3         → ritorna cosi' com'e'
#   addr@domain.com           → singolo indirizzo
#
# Uso:
#   RESOLVED=$(resolve_admin_recipients "$ADMIN_EMAIL")
#
resolve_admin_recipients() {
    local INPUT="$1"

    # Modalita' file
    if [[ "$INPUT" == file://* ]]; then
        local FILEPATH="${INPUT#file://}"

        if [ ! -f "$FILEPATH" ]; then
            echo "" # file non trovato
            return 1
        fi

        local RECIPIENTS=()
        while IFS= read -r LINE || [[ -n "$LINE" ]]; do
            # Trim whitespace
            LINE=$(echo "$LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Ignora vuote e commenti
            [[ -z "$LINE" ]] && continue
            [[ "$LINE" =~ ^# ]] && continue
            RECIPIENTS+=("$LINE")
        done < "$FILEPATH"

        if [ "${#RECIPIENTS[@]}" -eq 0 ]; then
            echo ""
            return 1
        fi

        # Ritorna come CSV
        local IFS=','
        echo "${RECIPIENTS[*]}"
        return 0
    fi

    # Modalita' stringa diretta (singolo indirizzo o CSV)
    echo "$INPUT"
    return 0
}

# ── Risolvi email utente (con mapping opzionale) ──────────────
# Se esiste un file di mapping, usa quello. Altrimenti fallback
# a <username>@MAIL_DOMAIN
#
# Uso:
#   USER_EMAIL=$(resolve_user_email "$USERNAME" "$MAIL_DOMAIN")
#
resolve_user_email() {
    local USERNAME="$1"
    local DEFAULT_DOMAIN="$2"
    local MAP_FILE="/usr/local/custom/rstudio/conf/user_email_map.txt"

    if [ -f "$MAP_FILE" ]; then
        local MAPPED
        MAPPED=$(grep "^${USERNAME}[[:space:]]" "$MAP_FILE" | awk '{print $2}' | head -1)
        if [ -n "$MAPPED" ]; then
            echo "$MAPPED"
            return 0
        fi
    fi

    echo "${USERNAME}@${DEFAULT_DOMAIN}"
    return 0
}
