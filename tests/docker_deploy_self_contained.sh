#!/usr/bin/env bash
# tests/docker_deploy_self_contained.sh — contract gate for the T2/T3 trees.
#
# WHY: Infra-Iam-PKI vendors docker-deploy/ and kubernetes-deploy/ byte-for-byte
# (its infra-rstudio/UPSTREAM.lock + sync_rstudioconf.sh). The copy only works if
# both trees are self-contained: nothing may reach into the repo root
# (config/, templates/, lib/, assets/) or outside the tree. This test fails the
# PR here, before the consumer's sync PR turns red.
#
# Checks:
#   1. no Dockerfile/compose/deploy path escapes its tree (`../` at top level, `../..` anywhere)
#   2. every Dockerfile COPY source exists inside docker-deploy/
#   3. every template named by docker-deploy scripts exists in docker-deploy/templates/
#   4. every relative bind-mount source in docker-compose.yml exists, or is gitignored site data
#   5. `docker compose config` resolves with .env.sandbox.example for both auth backends (if docker is present)
#
# Exit: 0 pass | 1 at least one check failed | 2 invocation error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly DD="${REPO_ROOT}/docker-deploy"
readonly K8S="${REPO_ROOT}/kubernetes-deploy"

for cmd in grep sed awk git; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required binary '$cmd' missing" >&2; exit 2; }
done
if [ ! -d "$DD" ] || [ ! -d "$K8S" ]; then
    echo "ERROR: docker-deploy/ or kubernetes-deploy/ missing" >&2; exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

# 1. Escapes
while IFS= read -r hit; do bad "path escapes its tree: $hit"; done < <(
    grep -nHE '(^|[^.])\.\./' "$DD"/docker-compose.yml "$DD"/Dockerfile* "$DD"/deploy.sh "$DD"/.env.sandbox.example "$K8S"/*.yaml 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' | sed "s#${REPO_ROOT}/##" || true
    grep -rnHE '\.\./\.\.' "$DD" "$K8S" --exclude-dir=doc --exclude='*.md' 2>/dev/null | sed "s#${REPO_ROOT}/##" || true
)

# 2. COPY sources (single-source form `COPY <src> <dst>`; --from= stages skipped)
for df in "$DD"/Dockerfile*; do
    while read -r src; do
        [ -e "$DD/$src" ] || bad "$(basename "$df"): COPY source '$src' not in docker-deploy/"
    done < <(awk 'toupper($1)=="COPY" && $2 !~ /^--/ {print $2}' "$df")
done

# 3. Templates referenced by the docker tier
while read -r tpl; do
    [ -f "$DD/templates/$tpl" ] || bad "template '$tpl' referenced by docker-deploy but missing from docker-deploy/templates/"
done < <(grep -rhoE '\$\{?TEMPLATE_DIR\}?/[A-Za-z0-9_.-]+\.(template|tpl)' "$DD"/scripts "$DD"/lib 2>/dev/null \
            | sed -E 's#.*/##' | sort -u)

# 4. Relative bind-mount sources (with ${VAR:-default}, the default is checked)
while read -r src; do
    rel="${src#./}"
    if [ -e "$DD/$rel" ]; then continue; fi
    if git -C "$REPO_ROOT" check-ignore -q "docker-deploy/$rel"; then continue; fi
    bad "bind-mount source '$src' neither exists in docker-deploy/ nor is gitignored site data"
done < <(grep -E '^\s+- ' "$DD/docker-compose.yml" | sed -E 's/^\s+- //; s/"//g' \
            | sed -E 's/\$\{[A-Z_]+:-([^}]*)\}/\1/g' | grep -E '^\./' | cut -d: -f1 | sort -u)

# 5. Compose resolves (skipped, with a note, where the docker CLI is absent)
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    for backend in sssd samba; do
        if ! (cd "$DD" && docker compose --env-file .env.sandbox.example \
                --profile "$backend" --profile portal --profile oidc config -q) 2>"$TMP/err"; then
            bad "docker compose config ($backend): $(grep -v 'level=warning' "$TMP/err" | head -1)"
        fi
    done
else
    echo "NOTE: docker compose not available — check 5 skipped"
fi

if [ "$fails" -gt 0 ]; then
    echo "docker-deploy self-contained: $fails problem(s)"
    exit 1
fi
echo "docker-deploy self-contained: OK"
