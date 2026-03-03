# System Overview: Docker Deploy Architecture

Questo documento descrive l'architettura ad alto livello del deploy containerizzato di **RStudio (Biome-Calc)**. Il design segue tassativamente un approccio *Sysadmin-First*, noto come **"Pet Container Pattern"**, in contrasto con l'astrazione Cloud-Native purista (Cattle).

## 1. La Filosofia "Pet Container"

L'obiettivo del modulo Docker non è l'effimero scaling orizzontale, ma l'incapsulamento portabile di un server Linux legacy (il "Pet") pre-integrato in un ecosistema di Active Directory (SSSD / Samba).

I container generati non operano in network isolati, ma sfruttano:

- **`network_mode: host`**: Per condividere l'IP stack e permettere il pass-through dei socket di autenticazione PAM (Pluggable Authentication Modules).
- **Socket Mounting (`/var/lib/sss/pipes`)**: Il demone Docker delega la risoluzione LDAP/Kerberos all'host fisico, condividendone i pipe IPC (Inter-Process Communication).

## 2. Componenti Principali e Topologia

### Modulo Proxy e UI (Nginx)

Un reverse proxy custom-built (`Dockerfile.nginx`) basato su Alpine Linux funge da varco d'accesso TLS.

- Consuma le variabili ambientali 12-Factor passate dal `docker-compose.yml`.
- Usa uno script entrypoint (`entrypoint_nginx.sh`) derivato dagli script bash Bare-Metal per renderizzare la Web UI ("Botanical Portal") sfruttando un motore di templating interno (`common_utils.sh`).
- Applica un approccio "Non-Optimistic" (Strict Sysadmin): Nessuna interpolazione lato client; i blocchi URL e il design reagiscono solo a validazioni server-side.

### Modulo di Computazione (RStudio SSSD o Samba)

Il layer applicativo (`Dockerfile.sssd` o `Dockerfile.samba`) è un container "monolitico" basato su `rocker/geospatial` fortemente ottimizzato:

- **Configurazione Dinamica (Template Engine):** Al boot, `entrypoint_rstudio.sh` genera asincronamente `rserver.conf`, `rsession.conf`, ed `Renviron.site` per calibrare i core di OpenBLAS/OMP e la RAM in conformità ai constraint imposti dal Compose.
- **Isolamento Risorse (RAMDisk & Limits):** RStudio sfrutta volumi `tmpfs` per annullare l'I/O bottleneck su disco e prevenire runout dello storage root. Tutta l'elaborazione temporanea è scaricata nella RAM volatile.
- **Compilazione Binaria PPA (BSPM):** La catena di build sfrutta `r-cran-bspm` e il PPA `c2d4u` per estrarre pacchetti precompilati da APT, minimizzando i tempi di CI/CD e parallelizzando fallback compilativi (`Ncpus = detectCores()`).

### Serverless Assistenza (Ollama API)

Un sub-modulo opzionale eroga l'assistente R Coder (`qwen2.5-coder`) via LLM.

- Isolato dal proxy tramite bind stringente all'anello di loopback (`127.0.0.1:11434`), evitando esposizione sulla LAN.
- Pre-bakato con `modelfile` sysadmin per settare i context boundaries dell'assistente.

### Microservizio Telemetria (FastAPI)

- Sub-modulo Python asincrono responsabile degli heartbeat, log reporting (User Crash Report), e Server-Sent Events (SSE).
- Integra validazioni Pydantic e protezioni OOM e gira sulla rete `host` in bind su Localhost (chiamato tramite Reverse Routing da Nginx).

## 3. Deployment Flow (Infrastruttura come Codice)

1. L'Operational Engineer delinea i constraint di perimetro (VCORES, URL, RAM, DOMAIN) in **`.env`**.
2. Esegue il provisioning tramite Compose CLI Profile (`docker compose --profile sssd up -d`).
3. L'ecosistema esegue l'instanziazione "On-Boot" tramite Entrypoint Script POSIX compliant.
4. L'integrità del container è garantita (Immutable Image con Mutable Configuration Data).
