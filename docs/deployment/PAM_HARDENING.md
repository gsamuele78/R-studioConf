<!-- docs/deployment/PAM_HARDENING.md -->
# PAM Hardening — Eliminating the `passwd` SIGSEGV

> **Tier:** T1 host.  
> **Applies to:** AD-joined **Ubuntu 24.04 LTS** nodes.  
> **Scripts:** [`scripts/13_harden_pam_password.sh`](../../scripts/13_harden_pam_password.sh)
> (new install) and [`scripts/fix_pam_segfault_inplace.sh`](../../scripts/fix_pam_segfault_inplace.sh)
> (retrofit).  
> **Last updated:** 2026-05-09.

---

## 1. Symptom

On AD-joined Ubuntu 24.04 hosts shipped by earlier R-studioConf
releases, running `passwd` for a local user (uid < 10000) crashes with
SIGSEGV:

```
$ sudo passwd alice
Changing password for alice.
Current password:
Segmentation fault (core dumped)
```

The crash also affects every PAM consumer that walks the password
stack (e.g. `chpasswd`, batch user-creation tools).

---

## 2. Root cause

Two independent defects, often present together:

1. **`libpam-krb5` NULL-deref in multi-realm krb5.conf.**  
   Our `/etc/krb5.conf` carries three realms (DIR / PERSONALE /
   STUDENTI). When a local user (not in any realm) hits the password
   stack, `pam_krb5.so` dereferences NULL on the missing principal and
   the process aborts. This is upstream-known and unfixed in 24.04.

2. **The legacy `biome-localguard` pam-config profile.**  
   Older R-studioConf releases shipped a hand-rolled
   `/usr/share/pam-configs/biome-localguard` profile that attempted to
   short-circuit local users away from the AD modules. Under Ubuntu
   24.04's `pam-auth-update` it merge-orders incorrectly and itself
   triggers the crash on `passwd`.

The Debian/Ubuntu default stack — `pam_unix` plus
`pam_winbind` (Samba) **or** `pam_sss` (SSSD) with success-branching —
already routes local users to `pam_unix` and AD users to the AD module.
**No custom guard is needed.**

---

## 3. Fix

### 3.1 New deployments — `scripts/13_harden_pam_password.sh`

Run after the AD-join script (`10_join_domain_sssd.sh` or
`11_join_domain_samba.sh`) and before `20_configure_rstudio.sh`. The
script:

1. `apt-get purge libpam-krb5` (and removes the `krb5` pam-config profile entry).
2. Removes `/usr/share/pam-configs/biome-localguard` if present.
3. Re-runs `pam-auth-update --force` to regenerate `/etc/pam.d/common-*`
   from the supported profile set only (`unix`, `winbind` or `sss`,
   `mkhomedir`).
4. Sanity-tests with a dry-run `chpasswd` against a synthetic local
   account.

The script is **idempotent** and safe to re-run.

### 3.2 Existing deployments — `scripts/fix_pam_segfault_inplace.sh`

For nodes already running an older release. Modes:

```bash
# Diagnosis only (dry-run, exit 0 if clean):
sudo bash scripts/fix_pam_segfault_inplace.sh --check

# Apply the minimal corrective changes:
sudo bash scripts/fix_pam_segfault_inplace.sh
```

Behavior:

1. Detects current PAM state (krb5 profile, residual `pam_krb5.so`
   lines, `biome-localguard`, hand-edits, AD provider).
2. Prints a structured diagnosis.
3. With no `--check`: applies only the changes needed to reach the
   sound state (purge package, remove profile, refresh stack).

Both scripts log to `/var/log/biome-log/core/`.

---

## 4. Post-fix verification

```bash
# Service-level
systemctl is-active sssd      # or smbd/winbind, depending on backend
realm list                    # joined realm visible

# PAM-level: should NOT segfault
sudo passwd <local-uid-under-10000>

# Stack inspection
grep -E 'pam_(unix|sss|winbind|krb5|mkhomedir)\.so' /etc/pam.d/common-*

# Should NOT see pam_krb5.so anywhere
# Should NOT see biome-localguard anywhere
ls /usr/share/pam-configs/ | grep -i guard   # → empty
```

If any of those checks fail, file an issue and attach the output of:

```bash
sudo bash scripts/99_postmortem_forensics.sh --user <affected-user> \
  --output /tmp/pam_postmortem.txt
```

---

## 5. Why we don't ship a custom PAM module

* **Smallest blast radius.** The default Debian stack already implements
  the local-vs-AD branch correctly. Adding a custom module increases
  the surface for upstream-merge breakage.
* **Pessimistic engineering.** Each extra module is one more place
  where a future Ubuntu point-release can NULL-deref us. We removed,
  not added.
* **HC-13 alignment.** This fix is a system-side change; user R code
  and user shells are unaffected.

---

## 6. Cross-references

* Step-by-step deployment → [`INSTALLATION_GUIDE.md`](INSTALLATION_GUIDE.md) §5 Phase 1
* SSSD vs Samba comparison → [`../reference/NGINX_AUTH_BACKENDS.md`](../reference/NGINX_AUTH_BACKENDS.md)
* Domain-join sanity tool → `scripts/99_verify_domain_join.sh`
* Postmortem collector → `scripts/99_postmortem_forensics.sh`
* Hard rules HR-7, HR-8 → `.ai/agents.md`, `.ai/project.yml`
