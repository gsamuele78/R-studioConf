# Plan — Scrub sensitive data from GitHub, keep it live on the deployed server

> Status: DESIGN / RUNBOOK — no code changed yet (docs-only by request).
> Tier: T1 (host) authoritative. T2/T3 mirrors (telemetry, portal fonts) follow per HARD RULE 3.
> Ethos: pessimistic. Fresh clone must FAIL LOUD on placeholder data, never half-configure.
> Decisions locked: S3 = redact 6 lines only. Git history purge = deferred, operator's call (§6).

---

## 1. Sensitive inventory (verified against the tree, not assumed)

| Tier | File | Sensitive content | How it is consumed |
|---|---|---|---|
| **S1 — third-party PII** | `config/scopri_progetti_known.conf` | researcher → supervisor → funded-project map | **copied** at deploy: `50_setup_nodes.sh:1657-1659`, `:2214` |
| **S1** | `config/admin_recipients.txt` | sysadmin + PI emails, prod IP `137.204.21.170`, Teams group | **copied**: `50_setup_nodes.sh:1650-1652`, `:2121`; read by `99_check_pkg_drift.sh:53`, `telemetry/telemetry_api.py:566-570` |
| **S1** | `config/user_email_map.txt` | currently only examples; PII surface going forward | **copied**: `50_setup_nodes.sh:2122` |
| **S2 — AD/infra topology** | `config/lib_kerberos_setup.vars.conf` | realm, KDC hostnames, OU DNs, allow-groups, admin UPN | **sourced**: `12_lib_kerberos_setup.sh:25-27` |
| **S2** | `config/join_domain_sssd.vars.conf` | realm/OU/home template w/ real username example | **sourced** by `10_join_domain_sssd.sh` |
| **S2** | `config/join_domain_samba.vars.conf` | realm/OU/groups | **sourced** by `11_join_domain_samba.sh` |
| **S3 — institutional, low** | `config/setup_nodes.vars.conf` | `SMTP_HOST=smtp.unibo.it` (50), `SENDER_EMAIL` (52), `MAIL_DOMAIN` (54), `MAIL_DOMAINS_USER` (61), `SMTP_DNS_SERVERS=137.204.25.x` (62), `BIOME_CONTACT=…@live.unibo.it` (305) | sourced; 16 KB, rest is generic tuning |

**S3 decision (locked): redact only lines 50/52/54/61/62/305 into the override. The remaining ~16 KB of tuning stays committed.** Full-file overlay was rejected as higher-risk than the data is sensitive.

---

## 2. Design — `config/site/` overlay (one mechanism, two adapters)

Mirrors the existing `.env` rule (HC-12): real data lives where git never looks; repo ships sanitized `.example` templates.

```
config/
├── lib_kerberos_setup.vars.conf.example      # committed (placeholders + __FILL_ME__ sentinel)
├── join_domain_sssd.vars.conf.example        # committed
├── join_domain_samba.vars.conf.example       # committed
├── admin_recipients.txt.example              # committed
├── user_email_map.txt.example                # committed
├── scopri_progetti_known.conf.example        # committed
├── setup_nodes.site.vars.conf.example        # committed (the 6 redacted S3 lines only)
└── site/                                      # .gitignore'd — NEVER tracked, immune to pull
    ├── lib_kerberos_setup.vars.conf
    ├── join_domain_sssd.vars.conf
    ├── join_domain_samba.vars.conf
    ├── admin_recipients.txt
    ├── user_email_map.txt
    ├── scopri_progetti_known.conf
    └── setup_nodes.site.vars.conf             # 6 real S3 values; sourced AFTER setup_nodes.vars.conf
```

**Why a separate `site/` dir, not gitignoring the real filename in place:** a `git rm --cached config/X` commit, when pulled on the live host, deletes `config/X` from the working tree. A path git has *never tracked* (`config/site/`) cannot be clobbered by any future pull. This is the pessimistic-safe choice and the crux of the whole design.

### Resolver — one helper in `lib/common_utils.sh`, not N scattered edits

```bash
# lib/common_utils.sh — add near the config helpers

# resolve_site_config <basename> <config_base_dir>
#   echoes config/site/<basename> if present, else <base>/<basename>.example (loud warn).
resolve_site_config() {
    local name="$1" base_dir="$2"
    if [[ -f "${base_dir}/site/${name}" ]]; then
        printf '%s\n' "${base_dir}/site/${name}"; return 0
    fi
    log "WARN" "Site config '${name}' not in ${base_dir}/site/ — falling back to .example (placeholder data)."
    printf '%s\n' "${base_dir}/${name}.example"
}

# source_site_config <basename> <config_base_dir>
#   sources the resolved vars file; ABORTS if the placeholder sentinel survived (pessimistic gate).
source_site_config() {
    local f; f="$(resolve_site_config "$1" "$2")"
    # shellcheck disable=SC1090
    source "$f"
    if grep -q '__FILL_ME__' "$f"; then
        log "ERROR" "Unconfigured site value in $f. Copy ${1}.example to config/site/${1} and fill real values."
        exit 1
    fi
}
```

### Adapter A — sourced files (S2 + S3 override)
Replace `source "$VARS_FILE"` with:
```bash
source_site_config "lib_kerberos_setup.vars.conf" "${SCRIPT_DIR}/../config"
```
For S3: keep `source setup_nodes.vars.conf` as-is (committed defaults), then layer the override:
```bash
[[ -f "${CFG}/site/setup_nodes.site.vars.conf" ]] && source "${CFG}/site/setup_nodes.site.vars.conf"
```
Fresh clone with no `site/` → S2 sourcing hits the sentinel and **aborts** instead of half-joining a domain with placeholder OUs. Stricter than today.

### Adapter B — copied files (S1)
In `50_setup_nodes.sh` (3 sites) and `99_check_pkg_drift.sh:53`, swap the literal path for:
```bash
cp -f "$(resolve_site_config "admin_recipients.txt" "${WORKSPACE_ROOT}/config")" "${BIOME_CONF}/conf/admin_recipients.txt"
```

### telemetry_api.py
`/etc/biome-calc/conf/...` (already-deployed location) stays first and is unaffected. Drop or env-gate the hardcoded `/home/administrator/configServices/...` fallback (`telemetry_api.py:570`).

---

## 3. Repo-side changes (one PR on a branch)

1. Generate the 7 `.example` files from the real ones (sanitize values, keep structure + comments; insert `__FILL_ME__` sentinels in S2).
2. `git rm --cached` the 6 S1/S2 real files (S3 stays committed; only the new `setup_nodes.site.vars.conf` is gitignored).
3. `.gitignore`: add `config/site/` plus the 6 real S1/S2 filenames (belt + suspenders).
4. Add `resolve_site_config` / `source_site_config` to `lib/common_utils.sh`.
5. Patch consumers: `12_lib_kerberos_setup.sh`, `10_join_domain_sssd.sh`, `11_join_domain_samba.sh`, `50_setup_nodes.sh` (3 copy sites + S3 override line), `99_check_pkg_drift.sh`, `telemetry/telemetry_api.py`.
6. Docs: `config/SITE_OVERRIDE.md` runbook; update `docs/reference/CONFIGURATION_MAP*`.
7. Grep guard — confirm nothing else reads the old paths:
   `grep -rn 'config/\(admin_recipients\|scopri_progetti_known\|user_email_map\|lib_kerberos_setup\|join_domain_\)' scripts lib`
8. Apply `host-install-audit` + `script-safety-review` to the edited scripts before opening the PR.

---

## 4. Live-server migration runbook — ORDER IS CRITICAL

Run **on the deployed host, BEFORE pulling the scrub commit.** Until you next run `50_setup_nodes.sh`, this is read-only against the running system (no `/etc` writes, no service restarts).

```bash
cd /path/to/R-studioConf                       # the live checkout

# 0. Full safety net
tar czf /var/backups/r_env_manager/config_pre_scrub_$(date +%F).tgz config/

# 1. Stage real data into the untracked overlay BEFORE git can touch it
mkdir -p config/site
for f in lib_kerberos_setup.vars.conf join_domain_sssd.vars.conf join_domain_samba.vars.conf \
         admin_recipients.txt user_email_map.txt scopri_progetti_known.conf; do
    cp -p "config/$f" "config/site/$f"
done
# S3: extract the 6 real lines into the override (one-time)
{ grep -E '^(SMTP_HOST|SENDER_EMAIL|MAIL_DOMAIN|MAIL_DOMAINS_USER|SMTP_DNS_SERVERS|BIOME_CONTACT)=' \
    config/setup_nodes.vars.conf; } > config/site/setup_nodes.site.vars.conf

# 2. NOW pull. The scrub commit deletes the tracked config/X from the working tree —
#    harmless: real values already live in config/site/ (never tracked).
git pull --ff-only

# 3. Verify resolver sees real data, not placeholders
grep -L __FILL_ME__ config/site/*.conf config/site/*.txt   # must list ALL; none with sentinel

# 4. Dry-run a consumer (no domain mutation) to prove sourcing works
bash -n scripts/12_lib_kerberos_setup.sh && \
  ( source lib/common_utils.sh
    source_site_config lib_kerberos_setup.vars.conf "$PWD/config" && \
    echo "OK realm=$DEFAULT_PERSONALE_UNIBO_REALM" )
```

**Rollback:** `tar xzf /var/backups/r_env_manager/config_pre_scrub_*.tgz` restores the pre-scrub tree. Nothing irreversible happened on the host.

---

## 5. Ongoing workflow

- **Routine deploys:** edit code → commit → push → `git pull --ff-only` on the host. Exactly as today. `config/site/` is gitignored, so pulls never touch it. Real data is never re-entered.
- **Change a real value later:** edit `config/site/X` directly on the host.
- **Upstream adds a new key:** it lands in `X.example`; copy the one new line into `config/site/X` once.
- **Backup:** `config/site/` is now the only copy in this repo. Fold it into the existing `/var/backups/r_env_manager/` job (7 small text files). Optional: mirror to a **private** repo for versioning.

---

## 6. Deferred decision — git history purge (operator's call)

§1–5 stop *future* exposure only. The data is already in public history; assume it is crawled.
`git filter-repo` is **irreversible**, rewrites every commit hash, and breaks all existing clones/forks and open PRs.

Recommended sequence:
1. Land the scrub PR now (stops the bleeding going forward).
2. Treat realm/KDC/PI-email/researcher-map as already-leaked: notify affected PIs; nothing here is a rotatable secret except awareness. (KDC/realm names were partly DNS-discoverable anyway; the PI list + user→project map are the real spear-phishing assets.)
3. Decide history purge separately. **Do not run `filter-repo` without an explicit go.**

---

## 7. Verification gates (definition of done)

- [ ] `git grep -nE 'chiarucci|sabatini|nascimbene|cazzolla|lussu|137\.204\.21\.170|dcrpersonale|Dip-BIGEA|Str00968'` on the scrub branch returns **nothing** in tracked files.
- [ ] Fresh clone (no `config/site/`) → `12_lib_kerberos_setup.sh` aborts with the `__FILL_ME__` error, does not proceed.
- [ ] Live host after runbook → step 3 lists all site files, step 4 prints the real realm.
- [ ] `grep` guard (§3.7) shows zero stale references to old paths.
- [ ] `.example` files contain no real values.
