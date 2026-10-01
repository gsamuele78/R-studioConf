#!/usr/bin/env bash
# docker-deploy/scripts/validate_deployment.sh
# ──────────────────────────────────────────────────────────────
# Pre-flight validation for docker-deploy/deploy.sh.
# STATUS: PLACEHOLDER STUB (added 2026-05-09 to satisfy deploy.sh
#         reference; previously the deploy.sh silently skipped a
#         missing validator — HC-10 risk).
#
# This stub returns 0 but documents the validations that MUST be
# implemented before T2 (docker tier) is promoted past
# MIGRATION_IN_PROGRESS in .ai/project.yml → deployment_tiers.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "[VALIDATE] $*"; }
warn() { echo -e "${YELLOW}[VALIDATE WARN]${NC} $*"; }
fail() { echo -e "${RED}[VALIDATE FAIL]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${DEPLOY_DIR}/.env"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"

# ── Minimum validations enabled NOW (cheap, safe) ─────────────
[ -f "$COMPOSE_FILE" ] || fail "docker-compose.yml not found at $COMPOSE_FILE"
[ -f "$ENV_FILE" ]     || fail ".env not found at $ENV_FILE — copy .env.sandbox.example or create one (HC-08: never commit it)"

# HC-08: .env should not be tracked by git
if git -C "$DEPLOY_DIR/.." check-ignore -q "docker-deploy/.env" 2>/dev/null; then
    log "HC-08 OK — .env is gitignored"
else
    warn "HC-08 WARNING — could not confirm docker-deploy/.env is gitignored (git unavailable or repo state odd)"
fi

# HC-07 quick scan: external (non-botanical) images must have explicit version tag
if grep -E '^\s+image:' "$COMPOSE_FILE" | grep -vE '(botanical|rstudio-botanical|IMAGE_TAG)' | grep -E ':latest\s*$' >/dev/null; then
    fail "HC-07 violation: an external image is pinned to :latest in docker-compose.yml"
fi

# HC-09 quick scan: docker.sock mount only allowed in docker-socket-proxy block
if awk '/^  [a-zA-Z]/{svc=$1} /\/var\/run\/docker\.sock/{print svc}' "$COMPOSE_FILE" | grep -v 'docker-socket-proxy' | grep -q .; then
    fail "HC-09 violation: a non-socket-proxy service mounts /var/run/docker.sock"
fi

# Site files bind-mounted by docker-compose.yml. A missing source file would be
# created by Docker as an empty DIRECTORY, so fail before `up` instead.
read_env() { grep "^$1=" "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true; }
SITE_DIR="${DEPLOY_DIR}/config/site"
admin_file="$(read_env ADMIN_RECIPIENTS_FILE)"
admin_file="${admin_file:-./config/site/admin_recipients.txt}"
case "$admin_file" in /*) ;; *) admin_file="${DEPLOY_DIR}/${admin_file#./}" ;; esac
[ -f "$admin_file" ] || fail "admin recipients file missing: $admin_file
  mkdir -p '$SITE_DIR' && cp '${DEPLOY_DIR}/config/admin_recipients.txt.example' '$admin_file'
  then put the real addresses in it (config/SITE_OVERRIDE.md). It is gitignored."

# oauth2-proxy (profile "oidc") reads a live config holding client/cookie secrets.
oauth_cfg="$(read_env OAUTH2_PROXY_CONFIG)"
oauth_cfg="${oauth_cfg:-./config/oauth2-proxy.cfg}"
case "$oauth_cfg" in /*) ;; *) oauth_cfg="${DEPLOY_DIR}/${oauth_cfg#./}" ;; esac
if [ ! -f "$oauth_cfg" ]; then
    warn "oauth2-proxy config not found at $oauth_cfg — required only for the 'oidc' profile."
    warn "  cp '${DEPLOY_DIR}/config/oauth2-proxy.cfg.example' '$oauth_cfg' and fill in the secrets (gitignored)."
fi

log "Basic checks passed."

# ── TODO: full validation surface (track in .ai/project.yml) ──
cat <<'TODO'
[VALIDATE TODO] To promote T2 past MIGRATION_IN_PROGRESS, implement:
  - HC-01: every service has deploy.resources.limits (memory + cpus)
  - HC-02: zero named Docker volumes (no top-level `volumes:` map)
  - HC-04: no passwords passed as command:/args:/environment
  - HC-05: no `ports:` on postgres-like services
  - HC-06: no `apt-get install` / `apk add` in entrypoints
  - HC-10: chown failures in entrypoints exit non-zero
  - HC-11: no CDN URLs in nginx ConfigMap or portal HTML
  - .env required keys present (KEYCLOAK_*, AD_*, STEP_*, OIDC_*)
TODO

exit 0
