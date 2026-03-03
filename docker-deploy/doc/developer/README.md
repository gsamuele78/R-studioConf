# Developer Reference: Docker Containers & Logic

La directory `docker-deploy/` contiene i manifesti infrastrutturali per convertire i server "Pet" bare-metal in immagini container immutabili.

## 1. Topologia dei Dockerfile

Il codice sorgente delle immagini è diviso modularmente:

### `Dockerfile.sssd` / `Dockerfile.samba`

- **Base Image**: `rocker/geospatial` (Ubuntu LTS based).
- **Ruolo**: Container primario Computazionale.
- **Sysadmin Specifics**: Installano ed espongono nativamente pacchetti per l'integrazione AD Host-Level (SSSD o Winbind). Incorporano il PPA ppa:c2d4u.team per il download binario di versioni CRAN (`r-cran-bspm`).

### `Dockerfile.nginx`

- **Base Image**: `nginx:alpine`
- **Ruolo**: Reverse Proxy e UI Portal.
- **Sysadmin Specifics**: Sostituisce la configurazione Nginx default con i template custom e inietta `gettext` per permettere l'interpolazione a runtime (Boot).

### `Dockerfile.telemetry`

- **Base Image**: `python:3.11-slim`
- **Ruolo**: API Asincrona.
- **Sysadmin Specifics**: Esegue il version-pinning stretto di FastAPI e Pydantic. Gira senza root (PID/Network = Host) per interrogare le metriche disco senza privilegi esponenziali.

## 2. Architettura degli Entrypoint Scripts

A differenza di un microservizio standard (Cattle), il container avvia script di bootstrapping complessi prima di innescare l'applicazione primaria. Tutte queste logiche ereditano la libreria `lib/common_utils.sh`.

### `scripts/entrypoint_rstudio.sh`

Esegue 4 fasi:

1. **PKI Trust Ingestion**: Controlla `$STEP_CA_URL`. Se presente, importa root certificates nell'OS trust store.
2. **Resource Constraint Injection**: Estrae limitazioni dalla stringa Compose `deploy.resources` (es. VCORE Count e Memoria RAM), convertendole per `Renviron.site` per calibrare i core di OpenBLAS/OMP.
3. **Template Sandboxing**: Utilizzando `mktemp`, inietta variabili env in `Rprofile.site` custom evitando conflitti I/O.
4. **Auth Binding**: Modifica fisicamente `/etc/nsswitch.conf` per fidarsi dei pipe dell'Host (LDAP auth spoofing).

### `scripts/entrypoint_nginx.sh`

- Verifica l'esistenza di certs validi. Se mancano o è definita un'iscrizione Step-CA, chiama `pki/enroll_cert.sh`.
- Utilizza `process_template` per stampare la UI Portal in base al feature flag `.env` `ENABLE_TELEMETRY_STRIP`.
- Sostituisce `nginx.conf` coi blueprint mitigati per DDoS (Tuning buffers limitati e Timeouts coordinati a RStudio).
