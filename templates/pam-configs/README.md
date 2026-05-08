# `templates/pam-configs/` — Debian `pam-auth-update` profiles

This directory ships custom `pam-auth-update` profile(s) deployed to
`/usr/share/pam-configs/` by `scripts/13_harden_pam_password.sh` and
`scripts/fix_pam_segfault_inplace.sh`.

> **Important format rule** — Debian pam-auth-update profile files **do NOT
> accept `#` comments**. Every non-blank line must be a `Field: value` line
> or a continuation of a block (indented with a TAB). If a `#` line is
> present you will see a cascade of Perl warnings:
>
> ```
> Use of uninitialized value $fieldname in hash element at /usr/sbin/pam-auth-update line 733
> ```
>
> Therefore the `.template` files here are kept pristine (no comments) and
> all rationale lives in this README.

---

## `biome-localguard.template`

### Purpose

Prevent `SIGSEGV` / `EPERM` on `passwd` (and `su`, `chpasswd`, ...) for
**local** users by skipping the AD-backed (winbind / sss) password-change
modules when `uid < 10000`.

### Rationale — idmap ranges used in this project

Source: `config/join_domain_samba.vars.conf`

| Range | Use |
|---|---|
| `uid < 1000` | System accounts |
| `1000 ≤ uid ≤ 9999` | Local sysadmins (`ladmin`, ...) |
| `10000 ≤ uid` | Winbind `*` tdb default + AD trust (PERSONALE rid: 163.6M–263.6M) |

Everything with `uid ≥ 10000` is AD/trust-mapped. Everything with
`uid < 10000` is strictly local and **must** use `pam_unix` only.

`pam_krb5` (from `libpam-krb5`) has a long-standing SIGSEGV in the password
stage when used with a multi-realm `krb5.conf`
(`DIR.UNIBO.IT` / `PERSONALE.DIR.UNIBO.IT` / `STUDENTI.DIR.UNIBO.IT` with
`capaths`) and a principal that does not exist in the default realm —
which is always the case for local accounts. `libpam-krb5` is therefore
NOT installed in this project. This profile additionally guards the
winbind / sss password path against local users so `passwd` and
`chpasswd` behave deterministically.

### Priority

`900` places this profile **before** winbind (~704) and sss (~252) in the
Primary Password-Type block, so the guard runs first.

### Logic (password stack only)

```
[success=ignore default=2]  pam_succeed_if.so  quiet uid >= 10000
```

- `success -> ignore` — continue through winbind/sss/unix as the normal AD path.
- `failure -> default=2` — skip the next 2 modules (winbind Primary + its
  `pam_deny`), falling through to `pam_unix.so` Primary for local users.

### What is NOT touched

`common-auth`, `common-session`, `common-session-noninteractive` — AD login
and session setup remain exactly as pam-auth-update configures them from
winbind/sss. Only the `password` stack gets the guard.

### Verification

```bash
sudo grep -n 'uid >= 10000' /etc/pam.d/common-password
# → must print: pam_succeed_if.so quiet uid >= 10000

sudo grep -nE '^[^#]*pam_krb5\.so' /etc/pam.d/common-*
# → must print nothing

ls /usr/share/pam-configs/biome-localguard    # must exist
ls /usr/share/pam-configs/krb5 2>/dev/null    # must NOT exist
```

### Rollback

```bash
sudo rm /usr/share/pam-configs/biome-localguard
sudo pam-auth-update --force --package
```
