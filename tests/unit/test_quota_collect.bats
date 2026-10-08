#!/usr/bin/env bats
# tests/unit/test_quota_collect.bats — deterministic collector tests, no SSH/root

setup() {
  ROOT="$BATS_TEST_TMPDIR/q"
  CACHE="$ROOT/cache"
  mkdir -p "$CACHE"
  LOG="$ROOT/collector.log"
  SCRIPT="$ROOT/collect.sh"
  sed -e "s|%%BIOME_CONF%%|$ROOT|g" \
      -e "s|%%LOG_FILE%%|$LOG|g" \
      "$BATS_TEST_DIRNAME/../../templates/biome_quota_collect.sh.template" > "$SCRIPT"
  chmod +x "$SCRIPT"
  UID_="$(id -u)"
  export QUOTA_SSH_HOST=dummy QUOTA_CACHE_DIR="$CACHE" QUOTA_SKIP_CHOWN=1 LOG_FILE="$LOG"
  export SECRETS_DIR="$ROOT/secrets" QUOTA_MIN_LINES=1
}

@test "valid quota row replaces cache atomically with mode 0400" {
  printf '%s\t%s\t%s\t%s\t%s\n' "$UID_" 1073741824 2147483648 7 none > "$ROOT/in"
  export QUOTA_SSH_CMD="cat '$ROOT/in'"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE/$UID_" ]
  read -r used quota objused objquota stamp < "$CACHE/$UID_"
  [ "$used" = 1073741824 ]
  [ "$quota" = 2147483648 ]
  [ "$objused" = 7 ]
  [ "$objquota" = none ]
  [ "$(stat -c '%a' "$CACHE/$UID_")" = 400 ]
  [ -s "$CACHE/.collected_at" ]
}

@test "malformed or unknown uid rows do not destroy previous cache" {
  printf 'old\n' > "$CACHE/$UID_"
  chmod 0400 "$CACHE/$UID_"
  printf 'not-a-uid\t1\t2\t3\t4\n999999999\t1\t2\t3\t4\n' > "$ROOT/in"
  export QUOTA_SSH_CMD="cat '$ROOT/in'"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(cat "$CACHE/$UID_")" = old ]
  [ ! -e "$CACHE/.collected_at" ]
}

@test "answer below QUOTA_MIN_LINES keeps previous cache" {
  printf 'old\n' > "$CACHE/$UID_"
  printf '%s\t1\t2\t3\t4\n' "$UID_" > "$ROOT/in"
  export QUOTA_MIN_LINES=2 QUOTA_SSH_CMD="cat '$ROOT/in'"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(cat "$CACHE/$UID_")" = old ]
}

@test "fetch failure keeps previous cache and logs failure" {
  printf 'old\n' > "$CACHE/$UID_"
  export QUOTA_SSH_CMD=false
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(cat "$CACHE/$UID_")" = old ]
  grep -q "fetch failed (cache kept)" "$LOG"
}

@test "answer below half of previous cache count is rejected" {
  for n in 1 2 3 4; do printf 'old\n' > "$CACHE/$n"; done
  printf '%s\t1\t2\t3\t4\n' "$UID_" > "$ROOT/in"
  export QUOTA_SSH_CMD="cat '$ROOT/in'"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(cat "$CACHE/1")" = old ]
  [ ! -e "$CACHE/.collected_at" ]
}
