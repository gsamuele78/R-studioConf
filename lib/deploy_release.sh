#!/usr/bin/env bash
set -euo pipefail
# lib/deploy_release.sh
# ==============================================================================
# Deployed-release stamp and downgrade guard for Step 8 (ADR-0006).
# Sourced by scripts/50_setup_nodes.sh; tested by tests/test_deploy_release_guard.sh.
#
# The stamp (default /etc/biome-calc/deployed_release) records which commit of
# this checkout Step 8 last deployed. Before the next deploy, the guard compares
# the checkout with it:
#   same commit, or a newer commit on the same history  -> deploy
#   no stamp yet (first stamped deploy)                  -> deploy, with a warning
#   older commit (downgrade), diverged branch, deployed
#   commit unknown to this checkout, local changes under
#   templates/, not a git checkout                       -> refuse
# A refusal is overridden only by an explicit allow flag (--allow-downgrade),
# which is how a production rollback to an older release is done. The stamp
# then records override=true and the commit it replaced.
#
# The stamp is key=value, read with grep/cut (never sourced).
# ==============================================================================

# Colors for callers without lib/common_utils.sh (that file defines the same names).
GREEN="${GREEN:-\033[0;32m}"; RED="${RED:-\033[0;31m}"
YELLOW="${YELLOW:-\033[1;33m}"; NC="${NC:-\033[0m}"

# Log through common_utils' log() when it is loaded, else to stderr.
_dr_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$1" "$2"
  else
    printf '[%s] %s\n' "$1" "$2" >&2
  fi
}

# git on the checkout as root: the checkout is owned by ladmin, so git would
# refuse it as "dubious ownership" without safe.directory.
_dr_git() {
  local root="$1"; shift
  git -c safe.directory="${root}" -c core.fileMode=false -C "${root}" "$@"
}

# biome_release_field STAMP KEY -> value, empty if missing
biome_release_field() {
  [[ -r "$1" ]] || return 0
  grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true
}

# biome_release_templates_dirty ROOT -> prints `git status` lines for templates/
biome_release_templates_dirty() {
  _dr_git "$1" status --porcelain --untracked-files=all -- templates/ 2>/dev/null || true
}

# biome_release_guard ROOT STAMP ALLOW
# Return: 0 deploy | 1 refused | 3 refused checks overridden by ALLOW=true
biome_release_guard() {
  local root="$1" stamp="$2" allow="${3:-false}"
  local head="" deployed="" dirty=""
  local -a problems=()

  if ! command -v git >/dev/null 2>&1; then
    problems+=("git is not installed, so the checkout cannot be compared with the deployed release")
  elif ! head="$(_dr_git "${root}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"; then
    problems+=("${root} is not a git checkout, so the release cannot be identified")
  else
    dirty="$(biome_release_templates_dirty "${root}")"
    if [[ -n "${dirty}" ]]; then
      problems+=("templates/ has local changes that no commit records: $(printf '%s' "${dirty}" | tr '\n' ';')")
    fi

    if [[ ! -e "${stamp}" ]]; then
      _dr_log "WARN" "No deployed-release stamp at ${stamp}: first stamped deploy, nothing to compare with."
    else
      deployed="$(biome_release_field "${stamp}" commit)"
      if [[ ! "${deployed}" =~ ^[0-9a-f]{40}$ ]]; then
        problems+=("${stamp} has no valid commit= line")
      elif [[ "${deployed}" == "${head}" ]]; then
        _dr_log "INFO" "Release check: redeploying the deployed commit ${head:0:12}."
      elif ! _dr_git "${root}" cat-file -e "${deployed}^{commit}" 2>/dev/null; then
        problems+=("deployed commit ${deployed:0:12} is not in this checkout (run git fetch), so it is unknown whether HEAD is older")
      elif _dr_git "${root}" merge-base --is-ancestor "${deployed}" "${head}"; then
        _dr_log "INFO" "Release check: upgrade ${deployed:0:12} -> ${head:0:12}."
      elif _dr_git "${root}" merge-base --is-ancestor "${head}" "${deployed}"; then
        problems+=("checkout ${head:0:12} is OLDER than the deployed ${deployed:0:12} ($(biome_release_field "${stamp}" release)): this is a downgrade")
      else
        problems+=("checkout ${head:0:12} has diverged from the deployed ${deployed:0:12} ($(biome_release_field "${stamp}" release)): branch $(_dr_git "${root}" branch --show-current 2>/dev/null || echo '?') does not contain it")
      fi
    fi
  fi

  (( ${#problems[@]} == 0 )) && return 0

  local p
  for p in "${problems[@]}"; do _dr_log "ERROR" "Release check: ${p}"; done
  if [[ "${allow}" == "true" ]]; then
    _dr_log "WARN" "Release check overridden by --allow-downgrade: deploying anyway (recorded in the stamp)."
    return 3
  fi
  _dr_log "ERROR" "Refusing to deploy. To roll back on purpose: git checkout <tag>, then rerun with --allow-downgrade."
  return 1
}

# biome_release_write_stamp ROOT STAMP RPROFILE_VERSION OVERRIDE
# Atomic write of the stamp; appends one line to STAMP.history.
biome_release_write_stamp() {
  local root="$1" stamp="$2" rver="$3" override="${4:-false}"
  local head release branch clean prev now tmp

  head="$(_dr_git "${root}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || echo unknown)"
  release="$(_dr_git "${root}" describe --tags --always --dirty 2>/dev/null || echo unknown)"
  branch="$(_dr_git "${root}" branch --show-current 2>/dev/null || true)"
  [[ -n "${branch}" ]] || branch="(detached)"
  if [[ -z "$(biome_release_templates_dirty "${root}")" ]]; then clean=true; else clean=false; fi
  prev="$(biome_release_field "${stamp}" commit)"
  now="$(date -Iseconds)"

  mkdir -p "$(dirname "${stamp}")"
  tmp="$(mktemp "${stamp}.XXXXXX")"
  {
    printf '# %s: written by scripts/50_setup_nodes.sh Step 8 (ADR-0006). Do not edit.\n' "${stamp}"
    printf 'release=%s\n' "${release}"
    printf 'commit=%s\n' "${head}"
    printf 'branch=%s\n' "${branch}"
    printf 'templates_clean=%s\n' "${clean}"
    printf 'rprofile_version=%s\n' "${rver}"
    printf 'deployed_at=%s\n' "${now}"
    printf 'deployed_by=%s\n' "${SUDO_USER:-$(id -un)}"
    printf 'override=%s\n' "${override}"
    printf 'previous_commit=%s\n' "${prev:-none}"
  } > "${tmp}"
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${stamp}"
  printf '%s release=%s commit=%s override=%s previous=%s\n' \
    "${now}" "${release}" "${head}" "${override}" "${prev:-none}" >> "${stamp}.history"
}

# biome_release_show ROOT STAMP: what is deployed, and whether the checkout matches
biome_release_show() {
  local root="$1" stamp="$2" head deployed
  if [[ ! -r "${stamp}" ]]; then
    _dr_log "WARN" "Deployed release: no stamp at ${stamp} (Step 8 not run since the stamp was introduced)."
    return 0
  fi
  deployed="$(biome_release_field "${stamp}" commit)"
  _dr_log "INFO" "Deployed release: $(biome_release_field "${stamp}" release) (commit ${deployed:0:12}, branch $(biome_release_field "${stamp}" branch), Rprofile v$(biome_release_field "${stamp}" rprofile_version), $(biome_release_field "${stamp}" deployed_at), override=$(biome_release_field "${stamp}" override))"
  head="$(_dr_git "${root}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"
  if [[ -z "${head}" ]]; then
    _dr_log "WARN" "  Checkout: not a git checkout, cannot compare."
  elif [[ "${head}" == "${deployed}" ]]; then
    _dr_log "INFO" "  Checkout HEAD ${head:0:12} = deployed [OK]"
  else
    _dr_log "WARN" "  Checkout HEAD ${head:0:12} differs from deployed ${deployed:0:12}: Step 8 has not been rerun since the last git pull/checkout"
  fi
}
