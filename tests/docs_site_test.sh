#!/usr/bin/env bash
set -euo pipefail
# tests/docs_site_test.sh — docs-site build gate + regression for the link hook (ADR-0001).
#
# 1. The real docs/ tree must build cleanly in MkDocs strict mode.
# 2. Negative controls: a broken link between docs pages, a broken #anchor and a
#    link to a missing repo file outside docs/ must each FAIL the strict build
#    (proves the gate is not false-green).
# 3. A link to an existing repo file outside docs/ must become a GitHub URL.
# Requires: mkdocs + mkdocs-material from scripts/tools/docs_site/requirements.txt.

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MKDOCS="${MKDOCS:-mkdocs}"
# The MkDocs 2.0 notice is acknowledged in ADR-0001 (we pin mkdocs 1.x).
export NO_MKDOCS_2_WARNING="${NO_MKDOCS_2_WARNING:-true}"
# NB: never pass --quiet: it hides WARNINGs from the strict-mode counter (false green).
command -v "$MKDOCS" >/dev/null 2>&1 || { printf "${RED}[FAIL]${NC} %s not found\n" "$MKDOCS" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
pass() { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
bad()  { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; fail=1; }

# 1. Real tree.
if "$MKDOCS" build --strict --config-file "$REPO_ROOT/mkdocs.yml" --site-dir "$WORK/site-real"; then
  pass "docs/ builds in strict mode"
else
  bad "docs/ does not build in strict mode"
fi

# Fixture: a minimal docs tree (two pages) built with the real mkdocs.yml and
# hook, plus one injected link. Isolated from the real docs/ on purpose.
make_fixture() {
  local dir="$1" line="$2"
  mkdir -p "$dir/docs/operations" "$dir/scripts/tools"
  cp "$REPO_ROOT/mkdocs.yml" "$REPO_ROOT/CHANGELOG.md" "$dir/"
  cp -r "$REPO_ROOT/scripts/tools/docs_site" "$dir/scripts/tools/docs_site"
  printf '# Troubleshooting\n\n## Real heading\n\ntext\n' > "$dir/docs/operations/TROUBLESHOOTING.md"
  printf '# Index\n\n[ok](operations/TROUBLESHOOTING.md#real-heading)\n\n%s\n' "$line" > "$dir/docs/README.md"
}

expect_fail() {
  local name="$1" line="$2" dir="$WORK/$1"
  make_fixture "$dir" "$line"
  if "$MKDOCS" build --strict --config-file "$dir/mkdocs.yml" --site-dir "$dir/site" >/dev/null 2>&1; then
    bad "$name: strict build passed but must fail"
  else
    pass "$name: strict build fails as expected"
  fi
}

# 2. Negative controls.
expect_fail broken-page   '[x](operations/DOES_NOT_EXIST.md)'
expect_fail broken-anchor '[x](operations/TROUBLESHOOTING.md#no-such-heading-anywhere)'
expect_fail broken-outside '[x](../DOES_NOT_EXIST.md)'

# 3. Positive control: existing file outside docs/ -> GitHub blob URL.
dir="$WORK/outside-ok"
make_fixture "$dir" '[changelog](../CHANGELOG.md)'
if "$MKDOCS" build --strict --config-file "$dir/mkdocs.yml" --site-dir "$dir/site" \
   && grep -q 'href="https://github.com/gsamuele78/R-studioConf/blob/main/CHANGELOG.md"' "$dir/site/index.html"; then
  pass "outside-docs link rewritten to GitHub URL"
else
  bad "outside-docs link not rewritten"
fi

exit "$fail"
