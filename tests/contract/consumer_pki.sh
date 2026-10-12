#!/usr/bin/env bash
# tests/contract/consumer_pki.sh
set -euo pipefail
# ==============================================================================
# Consumer contract with gsamuele78/Infra-Iam-PKI (ADR R-04).
#
# Infra-Iam-PKI vendors docker-deploy/, kubernetes-deploy/ and 14 T1 host tools
# from this repository (its infra-rstudio/UPSTREAM.lock). This script answers,
# BEFORE merge: "if the consumer re-vendored this commit, would its own rstudio
# gates still pass?" It runs the consumer's own tools, unchanged:
#   1. sync_rstudioconf.sh --update  (fails if a vendored file listed in the lock
#                                      was removed or renamed here)
#   2. sync_rstudioconf.sh --check   (vendored tree == this commit)
#   3. .ai/validate.sh --ci          (the consumer's hard rules)
#   4. docker compose config -q      (sssd and samba backends, sandbox env)
#
# The consumer checkout is a throw-away copy: nothing is committed or pushed
# there. Its repository is never modified (read-only reference).
#
# Usage: tests/contract/consumer_pki.sh <path-to-Infra-Iam-PKI-checkout> [git-ref]
#   git-ref defaults to HEAD of this repository.
# Exit: 0 contract holds | 1 contract broken | 2 usage / missing tool
# ==============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKI_SRC="${1:-}"
REF="${2:-HEAD}"

[ -n "$PKI_SRC" ] && [ -x "$PKI_SRC/scripts/infra-rstudio/sync_rstudioconf.sh" ] \
    || { echo -e "${RED}usage: $0 <Infra-Iam-PKI checkout> [git-ref]${NC}" >&2; exit 2; }
for cmd in git jq docker; do
    command -v "$cmd" >/dev/null 2>&1 || { echo -e "${RED}missing: $cmd${NC}" >&2; exit 2; }
done
docker compose version >/dev/null 2>&1 || { echo -e "${RED}missing: docker compose v2${NC}" >&2; exit 2; }

BRANCH="contract-under-test-$$"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; git -C "$ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true' EXIT

# The consumer's sync clones this repo as a bare repository, which copies
# branches and tags but not a detached HEAD: pin the ref under test to a branch.
git -C "$ROOT" branch -f "$BRANCH" "$(git -C "$ROOT" rev-parse --verify "${REF}^{commit}")"

# Work on a copy so a local consumer checkout is never left with staged changes.
git clone --quiet --no-hardlinks "$PKI_SRC" "$WORK/pki"
PKI="$WORK/pki"
SYNC="$PKI/scripts/infra-rstudio/sync_rstudioconf.sh"
echo -e "${YELLOW}Consumer: Infra-Iam-PKI@$(git -C "$PKI" rev-parse --short=12 HEAD)  pinned upstream: $(jq -r '.upstream.commit[0:12]' "$PKI/infra-rstudio/UPSTREAM.lock")${NC}"
echo -e "${YELLOW}Under test: R-studioConf@$(git -C "$ROOT" rev-parse --short=12 "$BRANCH")${NC}"

fail=0
step() {
    local name="$1"; shift
    echo "── $name"
    if "$@"; then
        echo -e "${GREEN}PASS${NC} $name"
    else
        echo -e "${RED}FAIL${NC} $name"
        fail=$((fail + 1))
    fi
}

step "re-vendor (sync --update)" "$SYNC" --update --source "$ROOT" --ref "$BRANCH"
echo "── vendored diff against the consumer's current pin"
git -C "$PKI" diff --cached --stat | tail -n 15
step "vendor check (sync --check)" "$SYNC" --check --source "$ROOT"
step "consumer hard rules (.ai/validate.sh --ci)" bash -c 'cd "$1" && .ai/validate.sh --ci' _ "$PKI"
for backend in sssd samba; do
    step "compose config ($backend)" bash -c \
        'cd "$1/infra-rstudio" && docker compose --env-file .env.sandbox --profile "$2" --profile portal --profile oidc config -q' \
        _ "$PKI" "$backend"
done

if [ "$fail" -gt 0 ]; then
    echo -e "${RED}[contract] Infra-Iam-PKI would break on this commit: $fail gate(s) failed.${NC}"
    echo "Fix it here, or record the change as MAJOR (consumer contract) in CHANGELOG and open an issue on Infra-Iam-PKI."
    exit 1
fi
echo -e "${GREEN}[contract] Infra-Iam-PKI gates pass on this commit.${NC}"
