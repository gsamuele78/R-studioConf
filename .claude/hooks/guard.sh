#!/usr/bin/env bash
# .claude/hooks/guard.sh
set -euo pipefail
# ==============================================================================
# PreToolUse guard for AI agents working on R-studioConf (ADR-0002, R-05).
#
# Claude Code pipes the pending tool call as JSON on stdin. For Bash calls this
# hook classifies the command and answers with a permission decision:
#   deny  — catastrophic or credential-exfiltrating; never run from an agent.
#   ask   — destructive, production-changing or supply-chain-sensitive; a human
#           must confirm in the client.
#   (no output, exit 0) — let the normal permission rules decide.
#
# Layers (pattern adapted from OpenHands software-agent-sdk, MIT:
# security/defense_in_depth/{utils,pattern,policy_rails}.py, security/ensemble.py):
#   1. normalise: drop invisible/bidi characters, NFKC (fullwidth "ｒｍ" → "rm"),
#      remove quotes and backslashes (rm "-rf" → rm -rf), squeeze blanks;
#   2. match the normalised text against deny rules, then ask rules;
#   3. fail closed to ASK: if this hook cannot parse its input it asks a human
#      instead of letting the command through.
#
# This is a guard rail, not a sandbox: an agent can still write a script and
# run it. It raises the cost of a bad command; it does not make one impossible.
#
# Test: tests/unit/test_agent_guard.bats (corpus in tests/fixtures/agent_guard/).
# CLI:  guard.sh --classify '<command>'   → prints deny|ask|allow (for tests).
# ==============================================================================


emit() { # $1 = deny|ask, $2 = reason
    local reason="${2//\\/\\\\}"
    reason="${reason//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"agent guard: %s"}}\n' \
        "$1" "$reason"
    exit 0
}

normalise() {
    local raw="$1" out
    if command -v python3 >/dev/null 2>&1; then
        out="$(printf '%s' "$raw" | python3 -I -c '
import sys, unicodedata, re
s = sys.stdin.read()
s = s.replace("\x00", "")
# zero-width, bidi controls, BOM, soft hyphen, tag block, C0/C1 controls except \t \n
s = re.sub(r"[­​-‏‪-‮⁠-⁤⁦-⁯﻿\U000e0000-\U000e007f]", "", s)
s = "".join(ch for ch in s if ch in "\t\n" or unicodedata.category(ch) != "Cc")
s = unicodedata.normalize("NFKC", s)
sys.stdout.write(s)
')" || return 1
    else
        # No python3: any non-ASCII byte is suspicious enough to ask.
        if LC_ALL=C grep -q '[^[:print:][:space:]]' <<<"$raw"; then
            return 1
        fi
        out="$raw"
    fi
    out="${out//\"/}"
    out="${out//\'/}"
    out="${out//\\/}"
    printf '%s' "$out" | tr '\n\t' '  ' | tr -s ' '
}

# ---- rules: extended regex over the normalised command ----------------------
# rm with both recursive and force, in any spelling.
RM_RF='(^|[;&|(` ])(sudo +)?rm +([^;&|]* )?(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR]|(-[a-zA-Z]*[rR][a-zA-Z]* +([^;&|]* )?-[a-zA-Z]*f)|(-[a-zA-Z]*f[a-zA-Z]* +([^;&|]* )?-[a-zA-Z]*[rR])|--recursive +([^;&|]* )?--force|--force +([^;&|]* )?--recursive)'
# A script being executed (not read): at command start, optionally via sudo/bash/sh
# with flags other than -n (syntax check only), then any path prefix.
EXEC='(^|[;&|(`] *)(sudo +(-[a-zA-Z]+ +)*)?((ba)?sh +(-[a-mo-zA-Z]+ +)*)?([^ ;&|]*/)?'
SYS_PATH='( |=)(/|/\*|~|~/|\$HOME|\$\{HOME\}|/(etc|usr|var|home|opt|boot|srv|root|lib|lib64|bin|sbin|Rtmp|nfs|mnt)(/\*?)?)( |;|&|\||$)'

DENY_RULES=(
    "rm -rf on a system or home path|${RM_RF}[^;&|]*${SYS_PATH}"
    "filesystem creation|(^|[;&|(\` ])(sudo +)?(mkfs(\.[a-z0-9]+)?|wipefs|mkswap) "
    "raw write to a block device|(^|[;&|(\` ])(sudo +)?dd +[^;&|]*of=/dev/(sd|vd|nvme|xvd|dm-|mapper|md)"
    "partition table change|(^|[;&|(\` ])(sudo +)?(sgdisk|sfdisk|parted|fdisk) +[^;&|]*(-[a-zA-Z]*[zoZ]|mklabel|rm |--delete|-d)"
    "download piped to an interpreter|(curl|wget|fetch)( [^|]*)?\| *(sudo +)?(ba|z|da|k)?sh( |$|;)|(curl|wget)( [^|]*)?\| *(sudo +)?(python[0-9.]*|perl|ruby|node)( |$|;)"
    "remote script via process substitution|(ba|z)?sh +<\( *(curl|wget)"
    "recursive world-writable permissions on a system path|chmod +(-[a-zA-Z]*R[a-zA-Z]* +)?[0-7]?777[^;&|]*${SYS_PATH}"
    "recursive ownership change of a system path|chown +-[a-zA-Z]*R[a-zA-Z]* +[^;&|]*${SYS_PATH}"
    "fork bomb|:\(\) *\{ *:\|:& *\} *;:"
    "reading Kerberos keytabs or shadow files|(cat|less|more|head|tail|strings|xxd|base64|cp|scp|rsync|klist +-k[a-z]*) +[^;&|]*(/etc/krb5\.keytab|\.keytab|/etc/shadow|/etc/gshadow|/var/lib/samba/private/)"
    "exfiltrating secrets over the network|(\.env|\.keytab|oauth2-proxy\.cfg|config/site/|id_rsa|id_ed25519|\.pem|\.key)[^;&|]*\| *(curl|wget|nc|ncat|socat)|(curl|wget)[^;&|]*(-d|--data|-F|--upload-file|-T) *@?[^;&| ]*(\.env|\.keytab|oauth2-proxy\.cfg|config/site/|id_rsa|id_ed25519|\.pem|\.key)"
)

ASK_RULES=(
    "rm -rf|${RM_RF}"
    "git history rewrite or remote write|(^|[;&|(\` ])git +([^;&|]* )?(push|reset +--hard|clean +-[a-zA-Z]*f|branch +-D|checkout +-- +\.|restore +[^;&|]*\.|rebase|filter-branch|filter-repo|update-ref +-d|tag +-d|stash +(drop|clear))"
    "service stop/restart on a production host|(^|[;&|(\` ])(sudo +)?(systemctl +(stop|restart|disable|mask|kill|isolate|reboot|poweroff|halt)|service +[^ ]+ +(stop|restart)|reboot|shutdown|poweroff|halt|init +[06])( |$|;)"
    "AD domain membership change|(^|[;&|(\` ])(sudo +)?(realm +(leave|join|deny|permit)|net +ads +(leave|join)|adcli +(delete|join)|kdestroy|ktutil)"
    "package removal or upgrade|(^|[;&|(\` ])(sudo +)?(apt(-get)?|dpkg|snap|pip[0-9.]*|python[0-9.]* +-m +pip|R +-e|Rscript +-e)[^;&|]*(remove|purge|autoremove|dist-upgrade|full-upgrade|upgrade|install|-r +|-P|remove\.packages|install\.packages)"
    "PAM, SSSD, Kerberos, Samba, nginx or RStudio config write|(sed +-i|tee|>|cp|mv|install|ln +-[a-z]*f|truncate|rm)[^;&|]*/etc/(pam\.d|sssd|krb5|samba|nginx|rstudio|R/|security|sudoers|ssh/sshd|nsswitch|profile\.d|biome-calc|systemd)"
    "PAM regeneration|pam-auth-update|authselect"
    "Docker data removal|docker +(compose +[^;&|]*down +[^;&|]*-v|compose +[^;&|]*down +-[a-z]*v|volume +rm|system +prune|image +prune +-a|rm +-[a-z]*f)"
    "R-studioConf orchestrator or installer|${EXEC}(init|r_env_manager|[0-5][0-9]_[a-z0-9_]+)\.sh( |$|;|&|\|)"
    "in-place hotfix or rollback|${EXEC}(fix_[a-z0-9_]+_inplace|hotfix_[a-z0-9_]+|update_nginx_templates)\.sh|--commit|--rollback|--apply|--uninstall|99_check_pkg_drift\.sh +[^;&|]*--update"
    "supply-chain configuration|(--index-url|--extra-index-url|--trusted-host|npm +config +set +registry|\.npmrc|pip\.conf|\.pypirc|/etc/apt/sources\.list|add-apt-repository|apt-key|gpg +--recv)"
    "SSH keys or authorized_keys|(\.ssh/|authorized_keys|ssh-keygen|ssh-copy-id)"
    "reading site secrets|(cat|less|more|head|tail|grep|awk|sed|cp|scp|rsync|base64|xxd|strings|source|\.) +[^;&|]*(config/site/|( |/)\.env( |$)|oauth2-proxy\.cfg|/etc/sssd/sssd\.conf|join_domain_[a-z]+\.vars\.conf( |$)|lib_kerberos_setup\.vars\.conf( |$)|user_email_map\.txt( |$)|admin_recipients\.txt( |$))"
    "crontab or timer change|(crontab +-[a-z]*[er]|/etc/cron|systemctl +[^;&|]*(enable|daemon-reload))"
    "user or group change|(^|[;&|(\` ])(sudo +)?(useradd|userdel|usermod|groupadd|groupdel|passwd|chpasswd|setquota|edquota)( |$)"
)

classify() { # $1 = raw command → prints "deny|reason", "ask|reason" or "allow|"
    local norm rule name pattern
    if ! norm="$(normalise "$1")"; then
        printf 'ask|could not normalise the command (non-ASCII without python3)'
        return 0
    fi
    for rule in "${DENY_RULES[@]}"; do
        name="${rule%%|*}"; pattern="${rule#*|}"
        if grep -Eq -- "$pattern" <<<"$norm"; then printf 'deny|%s' "$name"; return 0; fi
    done
    # A single, read-only hotfix invocation (--dry-run/--check, nothing else
    # chained) is diagnosis, not change: let it through.
    if grep -Eq -- "^(sudo +)?((ba)?sh +)?([^ ]*/)?(fix_[a-z0-9_]+_inplace|hotfix_[a-z0-9_]+)\.sh( +--(dry-run|check))+ *$" <<<"$norm"; then
        printf 'allow|'; return 0
    fi
    for rule in "${ASK_RULES[@]}"; do
        name="${rule%%|*}"; pattern="${rule#*|}"
        if grep -Eq -- "$pattern" <<<"$norm"; then printf 'ask|%s' "$name"; return 0; fi
    done
    printf 'allow|'
}

main() {
    if [[ "${1:-}" == "--classify" ]]; then
        local r; r="$(classify "${2:-}")"
        printf '%s\n' "${r%%|*}"
        return 0
    fi

    local input tool cmd verdict
    input="$(cat)" || emit ask "could not read the tool call"
    command -v jq >/dev/null 2>&1 || emit ask "jq missing, cannot inspect the command"
    tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" || emit ask "unparseable tool call"
    [[ "$tool" == "Bash" ]] || exit 0
    cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)" || emit ask "unparseable Bash command"
    [[ -n "$cmd" ]] || exit 0

    verdict="$(classify "$cmd")" || emit ask "classifier error"
    case "${verdict%%|*}" in
        deny) emit deny "${verdict#*|}" ;;
        ask)  emit ask  "${verdict#*|}" ;;
        *)    exit 0 ;;
    esac
}

# Any unexpected failure ends as "ask", never as a silent pass.
trap 'emit ask "guard internal error"' ERR
main "$@"
