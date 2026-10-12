#!/usr/bin/env bats
# tests/unit/test_agent_guard.bats
#
# Pre-registered measurement for the agent guard (.claude/hooks/guard.sh):
#   deny corpus  → 100 % "deny"   (27 commands, 14 of them obfuscated)
#   ask corpus   → 100 % "ask"    (26 commands)
#   allow corpus → 100 % "allow"  (false-positive guard, 30 everyday commands)
#   mutation     → removing ANY single rule makes at least one corpus line fail
# Corpus: tests/fixtures/agent_guard/{deny,ask,allow}.txt

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    ROOT="$DIR/../.."
    GUARD="$ROOT/.claude/hooks/guard.sh"
    CORPUS="$ROOT/tests/fixtures/agent_guard"
}

# Prints every corpus line of $2 that the guard at $1 does not classify as $3.
misses() {
    local guard="$1" file="$2" want="$3" line got
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        got="$(bash "$guard" --classify "$line")"
        [[ "$got" == "$want" ]] || printf '%s -> %s: %s\n' "$want" "$got" "$line"
    done <"$file"
}

@test "guard: is executable and passes bash -n" {
    [ -x "$GUARD" ]
    bash -n "$GUARD"
}

@test "guard: every deny-corpus command is denied" {
    run misses "$GUARD" "$CORPUS/deny.txt" deny
    [ -z "$output" ] || { echo "$output"; false; }
}

@test "guard: every ask-corpus command needs confirmation" {
    run misses "$GUARD" "$CORPUS/ask.txt" ask
    [ -z "$output" ] || { echo "$output"; false; }
}

@test "guard: no false positives on everyday maintenance commands" {
    run misses "$GUARD" "$CORPUS/allow.txt" allow
    [ -z "$output" ] || { echo "$output"; false; }
}

@test "guard: hook protocol emits a deny decision as JSON" {
    run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | bash '$GUARD'"
    [ "$status" -eq 0 ]
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = "deny" ]
}

@test "guard: allowed command produces no output" {
    run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}' | bash '$GUARD'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard: non-Bash tools are left to the permission rules" {
    run bash -c "printf '%s' '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"x\"}}' | bash '$GUARD'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard: unparseable input fails closed to ask, not to allow" {
    run bash -c "printf 'not json' | bash '$GUARD'"
    [ "$status" -eq 0 ]
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = "ask" ]
}

@test "guard: mutation — removing any single rule breaks the corpus" {
    local n=0 survivors="" line name mutant
    mutant="$BATS_TEST_TMPDIR/guard_mutant.sh"
    while IFS= read -r line; do
        n=$((n + 1))
        name="${line#*\"}"; name="${name%%|*}"
        grep -vxF -- "$line" "$GUARD" >"$mutant"
        if [ -z "$(misses "$mutant" "$CORPUS/deny.txt" deny)$(misses "$mutant" "$CORPUS/ask.txt" ask)" ]; then
            survivors+="${name}; "
        fi
    done < <(grep -E '^    "[^"|]+\|' "$GUARD")
    [ "$n" -ge 20 ]   # the rule list was actually found
    [ -z "$survivors" ] || { echo "rules with no corpus coverage: $survivors"; false; }
}

@test "settings: hook is wired and secrets are denied to the Read tool" {
    local s="$ROOT/.claude/settings.json"
    jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | test("guard.sh"))' "$s" >/dev/null
    jq -e '.permissions.deny | index("Read(./config/site/**)")' "$s" >/dev/null
    jq -e '.permissions.deny | index("Read(**/.env)")' "$s" >/dev/null
    # git reset was allowed without confirmation before this change.
    ! jq -e '.permissions.allow // [] | map(select(test("git reset"))) | length > 0' "$s" >/dev/null
}
