# COMPOSE_OPERATOR_RUNBOOK.md — Operator runbook for the T2 (docker) tier

> **Tier status:** T2 = `MIGRATION_IN_PROGRESS` (`.ai/project.yml → deployment_tiers.T2_docker`).
> **Authoritative behavior:** T1 host. T2 must mirror T1; recorded deviations only.
> **Audience:** single LPIC-3 sysadmin. No babysitting capacity.

## 1. Pre-flight (do this every time)

```bash
cd docker-deploy/
[ -f .env ] || cp .env.sandbox .env && $EDITOR .env   # HC-08: never commit .env
./scripts/validate_deployment.sh                       # HC-03 strict mode
```

If `validate_deployment.sh` fails, **fix before deploying**. The stub returns 0 today but enforces:

- HC-07 (no `:latest` on external images)
- HC-08 (`.env` is gitignored)
- HC-09 (no rogue `/var/run/docker.sock` mounts)

The full validation surface (HC-01/02/04/05/06/10/11 + healthchecks) is documented in `scripts/validate_deployment.sh` `[VALIDATE TODO]` block — promotion past `MIGRATION_IN_PROGRESS` requires that surface to be implemented.

## 2. Deploy

```bash
./deploy.sh
```

`deploy.sh` runs:

1. Pre-flight validation (above).
2. Optional PKI trust reminder (`scripts/manage_pki_trust.sh`).
3. `docker compose --profile $AUTH_BACKEND --profile portal up -d --build`.
4. Quick health probe on the RStudio port.

**HC-03/HC-10:** `deploy.sh` uses `set -euo pipefail` and traps `ERR` to surface the failing line.

## 3. Service profiles

| Profile     | Services started |
|-------------|------------------|
| `sssd`      | `rstudio-sssd` (R workspace via SSSD) |
| `samba`     | `rstudio-samba` (R workspace via Samba/winbind) — **XOR** with `sssd` |
| `portal`    | `nginx-portal`, `telemetry-api`, `docker-socket-proxy` |
| `oidc`      | `oauth2-proxy` |
| `ai`        | `ollama-ai` |

`AUTH_BACKEND` in `.env` selects `sssd` or `samba` — never both on the same host.

## 4. Pinned image policy (HC-07)

| Image | Pin | Source |
|---|---|---|
| `rocker/geospatial` | `4.4.1` | `Dockerfile`, `Dockerfile.sssd`, `Dockerfile.samba` |
| `nginx` | `1.27-alpine` | `Dockerfile.nginx` |
| `ollama/ollama` | `0.5.4` | `Dockerfile.ollama` |
| `python` | `3.11-slim` | `Dockerfile.telemetry` |
| `quay.io/oauth2-proxy/oauth2-proxy` | `v7.6.0` | compose service |
| `tecnativa/docker-socket-proxy` | `0.3.0` | compose service |
| `botanical-*`, `rstudio-botanical-*` | `:latest` (locally built) | **documented HC-07 exception** |

## 5. Health & status

```bash
docker compose ps                       # service state
docker compose logs -f --tail=200 <svc> # follow logs
docker stats                            # resource use
```

Health probes:

- RStudio: `curl -fs http://localhost:${RSTUDIO_PORT:-8787}` returns 200/302.
- Portal: `curl -fIs https://${HOST_DOMAIN}/healthz`.
- Telemetry: `curl -fs http://localhost:${TELEMETRY_PORT}/metrics`.

## 6. Common failure modes (honest, observed)

| Symptom | First action | Reference |
|---|---|---|
| `validate_deployment.sh` skipped silently | Confirm file exists & is executable; if missing, regenerate from this repo. | T2 stub |
| RStudio session crashes mid-NIMBLE | Verify BLAS = `libopenblas0-serial` inside container (HC); check `/Rtmp` bind mount; see T1 `99_diagnose_lussu_hang.sh` and `LUSSU_HANG_BISECTION.md`. | T1 doc |
| oauth2-proxy 502 | OIDC issuer URL or cookie secret wrong in `.env`. Validate with `oauth2-proxy --validate-config`. | T2 |
| `docker.sock` mount error | Only `docker-socket-proxy` may mount it (HC-09). Inspect compose for stray mounts. | HC-09 |
| Container chown errors | HC-10 — entrypoint must `exit 1` on chown failure. Inspect `entrypoint_*.sh`. | HC-10 |

## 7. Tear-down

```bash
docker compose --profile sssd --profile samba --profile portal --profile oidc --profile ai down
```

Bind-mount data (HC-02) survives tear-down; nothing is in named volumes.

## 8. Promotion to T3 (kubernetes)

Do **not** promote T2 changes to T3 until:

- `validate_deployment.sh` enforces the full HC surface (currently a stub).
- `oauth2-proxy` and `docker-socket-proxy` have working healthchecks.
- Any T1↔T2 divergence is recorded in `.ai/project.yml → tier_deltas`.

See `docs/deployment/TIER_PROMOTION.md` for the contract.

## 9. References

- T1 operator quickstart: `docs/operations/OPERATOR_QUICKSTART.md`
- Tier contract: `docs/deployment/TIER_PROMOTION.md`
- Architecture & invariants: `.ai/agents.md`
- Constraint definitions: `.ai/project.yml`
- T2 audit skill: `.agents/skills/compose-constraint-audit/SKILL.md`
