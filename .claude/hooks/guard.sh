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
    # Newlines separate commands in bash: keep them as ";" so "echo ok<NL>rm -rf /"
    # is two commands, not one.
    printf '%s' "$out" | tr '\n' ';' | tr '\t' ' ' | canonicalise
}

# Make every command start where the rules look for it:
#   - "bash -c CMD", "sh -c CMD", "eval CMD" → "; CMD" (quotes are already gone);
#   - drop wrappers at command position: sudo/doas (with options), env (with
#     options and VAR=val), command, exec, nohup, nice, ionice, timeout, stdbuf,
#     time, and leading VAR=val assignments;
#   - "/usr/bin/rm" → "rm": strip the directory of the command word only (paths
#     in arguments are kept, the system-path rules need them);
#   - harmless dd/redirect targets (/dev/null, /dev/zero, ...) are renamed so the
#     block-device rule can match every other /dev path; committed templates
#     (.env.example, .env.sandbox.example) are renamed so .env.* rules skip them.
canonicalise() {
    local cur prev
    cur="$(sed -E 's/;/ ; /g; s/(&&|\|\|)/ \1 /g; s/ +/ /g')"
    for _ in 1 2 3 4 5 6; do
        prev="$cur"
        cur="$(sed -E \
            -e 's/(^|[;&|(`]) *((ba|z|da|k)?sh|eval)( +-[a-zA-Z]*c[a-zA-Z]*)? +-c +/\1 ; /g' \
            -e 's/(^|[;&|(`]) *eval +/\1 ; /g' \
            -e 's/(^|[;&|(`]) *(sudo|doas)( +(-[a-zA-Z]*[ugCghprT]|--(user|group|chdir|prompt|host|role|type|close-from)) +[^ ;&|-][^ ;&|]*| +-[a-zA-Z-]+(=[^ ;&|]*)?)* +/\1 /g' \
            -e 's/(^|[;&|(`]) *env( +-[a-zA-Z-]+( +[^ =;&|-][^ ;&|]*)?| +[A-Za-z_][A-Za-z0-9_]*=[^ ;&|]*)* +/\1 /g' \
            -e 's/(^|[;&|(`]) *(command|exec|nohup|time|stdbuf( +-[a-zA-Z0-9=]+)*|nice( +-n)? *(-?[0-9]+)?|ionice( +-[a-zA-Z] *[0-9]+)*|timeout( +-[a-zA-Z-]+( +[0-9a-zA-Z]+)?)* +[0-9.]+[smhd]?) +/\1 /g' \
            -e 's/(^|[;&|(`]) *([A-Za-z_][A-Za-z0-9_]*=[^ ;&|]* +)+/\1 /g' \
            -e 's#(^|[;&|(`]) *([^ ;&|]*/)([A-Za-z0-9_.+-]+)#\1 \3#g' \
            <<<"$cur")"
        [[ "$cur" == "$prev" ]] && break
    done
    sed -E -e 's#/dev/(null|zero|u?random|stdout|stderr|stdin|fd/[0-9]+|tty)( |$|;)#DEVSAFE\2#g' \
           -e 's/\.env((\.[A-Za-z0-9_-]+)*)\.example( |$|;)/ENV_EXAMPLE\1\3/g' \
           -e 's/ +/ /g; s/^ //; s/ $//' <<<"$cur"
}

# ---- rules: extended regex over the normalised command ----------------------
# rm with both recursive and force, in any spelling (-rf, -r -f, -r --force, ...).
R_FLAG='(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'
F_FLAG='(-[a-zA-Z]*f[a-zA-Z]*|--force)'
RF_BOTH='(-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*)'
# \b (GNU grep) ends the flag without consuming the blank the path rules need.
RM_RF="(^|[;&|(\` ])rm ([^;&|]* )?(${R_FLAG} ([^;&|]* )?${F_FLAG}|${F_FLAG} ([^;&|]* )?${R_FLAG}|${RF_BOTH})\b"
# A script being executed (not read): at command start, optionally via bash/sh
# with flags other than -n (syntax check only). Wrappers and directories of the
# command word were already removed by canonicalise.
EXEC='(^|[;&|(`] *)((ba)?sh +(-[a-mo-zA-Z]+ +)*)?([^ ;&|]*/)?'
# System paths. Deep roots: the root and anything below it. Shallow roots
# (home, data, mounts): the root and its first level (/home/alice), deeper paths
# fall to "ask". Home: ~, $HOME and its dot-directories (~/.ssh, ~/.config).
B='( |;|&|\||$)'
SYS_PATH="( |=)(/\*?|/(etc|usr|boot|bin|sbin|lib|lib32|lib64|root|var/lib|var/log)(/[^ ;&|]*)?|/(home|opt|srv|var|Rtmp|nfs|mnt|media|data)(/[^/ ;&|]*)?/?\*?|(~|\\\$HOME|\\\$\{HOME\})(/(\.[^/ ;&|]*)?)?/?\*?)${B}"
BLOCKDEV='/dev/(sd|vd|hd|xvd|nvme|mmcblk|loop|md|dm-|mapper/|disk/|zd|rbd|nbd)'
SECRET_FILES='(/etc/krb5\.keytab|\.keytab|/etc/shadow|/etc/gshadow|/var/lib/samba/private/)'
READERS='(cat|tac|nl|less|more|head|tail|strings|xxd|od|hexdump|base64|base32|cp|mv|scp|rsync|tar|zip|gzip|bzip2|xz|grep|egrep|fgrep|rg|awk|gawk|sed|cut|sort|uniq|diff|cmp|paste|tee|dd|vi|vim|nano|view|python[0-9.]*|perl|ruby|php|node|source|\.|klist +-k[a-z]*)'
UPLOAD='(-d|--data(-binary|-raw|-urlencode)?|-F|--form|--upload-file|-T)'
SECRET_NAMES='(\.env|\.keytab|oauth2-proxy\.cfg|config/site/|id_rsa|id_ecdsa|id_ed25519|\.pem|\.key|/etc/shadow)'

DENY_RULES=(
    "rm -rf on a system or home path|${RM_RF}[^;&|]*${SYS_PATH}"
    "filesystem creation|(^|[;&|(\` ])(mkfs(\.[a-z0-9]+)?|wipefs|mkswap) "
    "raw write to a block device|(^|[;&|(\` ])dd +[^;&|]*of=${BLOCKDEV}|> *${BLOCKDEV}"
    "partition table change|(^|[;&|(\` ])(sgdisk|sfdisk|fdisk|parted|gdisk|cfdisk) +[^;&|]*(-[a-zA-Z]*[zoZ]|mklabel|mktable|mkpart|resizepart|rm( |$)|--delete|-d)"
    "download piped to an interpreter|(curl|wget|fetch)( [^|]*)?\| *(ba|z|da|k)?sh( |$|;)|(curl|wget)( [^|]*)?\| *(python[0-9.]*|perl|ruby|node)( |$|;)"
    "remote script via process substitution|(ba|z)?sh +<\( *(curl|wget)"
    "recursive world-writable permissions on a system path|chmod +(-[a-zA-Z]*R[a-zA-Z]* +|--recursive +)?[0-7]?777[^;&|]*${SYS_PATH}"
    "recursive ownership change of a system path|chown +(-[a-zA-Z]*R[a-zA-Z]*|--recursive) +[^;&|]*${SYS_PATH}"
    "fork bomb|:\(\) *\{ *: *\| *: *& *\} *; *:"
    "reading Kerberos keytabs or shadow files|(^|[;&|(\` ])${READERS} +[^;&|]*${SECRET_FILES}|< *[^ ;&|]*${SECRET_FILES}"
    "exfiltrating secrets over the network|${SECRET_NAMES}[^;&|]*\| *(curl|wget|nc|ncat|socat)|(curl|wget)[^;&|]*${UPLOAD} *@?[^;&| ]*${SECRET_NAMES}"
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
    "reading site secrets|(^|[;&|(\` ])${READERS} +[^;&|]*(config/site/|( |/)\.env(\.[A-Za-z0-9_-]+)*( |;|$)|oauth2-proxy\.cfg|/etc/sssd/sssd\.conf|join_domain_[a-z]+\.vars\.conf( |$)|lib_kerberos_setup\.vars\.conf( |$)|user_email_map\.txt( |$)|admin_recipients\.txt( |$))"
    "crontab or timer change|(crontab +-[a-z]*[er]|/etc/cron|systemctl +[^;&|]*(enable|daemon-reload))"
    "user or group change|(^|[;&|(\` ])(sudo +)?(useradd|userdel|usermod|groupadd|groupdel|passwd|chpasswd|setquota|edquota)( |$)"
)

classify() { # $1 = raw command → prints "deny|reason", "ask|reason" or "allow|"
    local norm rule name pattern
    # Rules are evaluated inside "if grep", where a broken grep reads as "no
    # match" without tripping the ERR trap: prove grep works first.
    if ! grep -Eq -- '^a(b|c)$' <<<"ac" || grep -Eq -- '^a(b|c)$' <<<"ad"; then
        printf 'ask|grep -E unavailable, cannot classify'
        return 0
    fi
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
