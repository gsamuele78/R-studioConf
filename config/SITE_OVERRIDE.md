# Site-local config overlay

Real, site-specific values (AD realm/KDCs/OUs, researcher PII, PI emails, SMTP
host, internal IPs) are **never committed**. The repo ships sanitized
`*.example` templates; the live host keeps real values in `config/site/`, which
is gitignored and therefore immune to `git pull` / history rewrites.

This is the same principle as the `.env` rule (HC-12), applied to config.

## Resolution order (enforced in `lib/common_utils.sh`)

`resolve_site_config <name> <config_dir>` returns:

1. `config/site/<name>` if it exists (real values), else
2. `config/<name>.example` (placeholders) **with a loud WARN**.

For the AD/Kerberos chain, `assert_site_configured` then **aborts** if a
required value is empty or still contains the `__FILL_ME__` sentinel — a fresh
clone fails fast instead of half-joining a domain with placeholder data.

## Files under the overlay

| Committed template | Real file (gitignored) | Tier |
|---|---|---|
| `lib_kerberos_setup.vars.conf.example` | `site/lib_kerberos_setup.vars.conf` | S2 (sourced, asserted) |
| `join_domain_sssd.vars.conf.example` | `site/join_domain_sssd.vars.conf` | S2 (sourced, asserted) |
| `join_domain_samba.vars.conf.example` | `site/join_domain_samba.vars.conf` | S2 (sourced, asserted) |
| `admin_recipients.txt.example` | `site/admin_recipients.txt` | S1 (copied) |
| `user_email_map.txt.example` | `site/user_email_map.txt` | S1 (copied) |
| `scopri_progetti_known.conf.example` | `site/scopri_progetti_known.conf` | S1 (copied) |
| `setup_nodes.site.vars.conf.example` | `site/setup_nodes.site.vars.conf` | S3 (6 keys, sourced after defaults) |

`setup_nodes.vars.conf` stays committed; only its 6 sensitive keys (SMTP_HOST,
SENDER_EMAIL, MAIL_DOMAIN, MAIL_DOMAINS_USER, SMTP_DNS_SERVERS, BIOME_CONTACT)
are sanitized and overridden by `site/setup_nodes.site.vars.conf`.

## First-time setup on a host

```bash
mkdir -p config/site
for f in lib_kerberos_setup.vars.conf join_domain_sssd.vars.conf \
         join_domain_samba.vars.conf admin_recipients.txt \
         user_email_map.txt scopri_progetti_known.conf setup_nodes.site.vars.conf; do
    cp "config/${f}.example" "config/site/${f}"
done
# then edit each config/site/* and replace every __FILL_ME__ with real values
grep -rl __FILL_ME__ config/site/   # must be empty when done
```

## Migrating the CURRENTLY deployed host (one-time)

The host already has real values in the tracked `config/*` files. Stage them
into `config/site/` **before** pulling the scrub commit, or the pull will delete
them. Full runbook: `plan/secret_scrub_site_overlay_plan.md` §4.

## Backups

`config/site/` is now the only copy of these values in this checkout. Include it
in `/var/backups/r_env_manager/`, or mirror to a **private** repo.
