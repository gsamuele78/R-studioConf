# Deployment Guide: Orchestration & Topology

L'orchestrazione applicativa viene gestita interamente in modalità Infrastructure-as-Code tramite `docker-compose.yml` e la libreria di configurazioni `.env`.

## 1. Topologia dei Servizi (Compose Profiles)

Il deployment non usa "Replicas" orizzontali ma architetture isolate abilitabil via i **Docker Compose Profiles**.
Non tutti i container si attivano contemporaneamente.

### Basic Setup (SSSD backend)

- **Servizi Attivi**: `rstudio-sssd`, `nginx-portal`, `telemetry-api`, `terminal-tty`.
- **Lancio**: `docker compose --profile sssd up -d`

### Basic Setup (Samba backend)

- **Servizi Attivi**: `rstudio-samba`, `nginx-portal`, `telemetry-api`, `terminal-tty`.
- **Lancio**: `docker compose --profile samba up -d`

### Cloud-Native Setup (OIDC / OAuth2 Proxy)

Per l'integrazione ad Open OnDemand o Portali Istituzionali centralizzati, si inietta un sidecar di validazione token JWT.

- **Servizi Aggiuntivi**: `oauth2-proxy`.
- **Lancio**: `docker compose --profile sssd --profile oidc up -d`

## 2. Resource Mapping e Kernel Constraints

Il PRD System Design richiede che nessun container possa paralizzare l'Host.

- **CPU Cores (`cpus`)**: Il container RStudio è hard-limited nel `docker-compose.yml` (`cpus: "16.0"`). L'entrypoint estrae questo numero per definire `OMP_NUM_THREADS` prevenendo cache thrashing sulle CPU non allocate.
- **Memoria RAM (`memory`)**: Impostata a tetti coercitivi (`memory: "64g"`). Impedisce un leak OOM dall'analitica Dplyr.
- **RAMDisk (`tmpfs`)**: Invece di una bind mount Host su dischi SSD SATA limitati in I/O, il temporary storage (che assorbe lo snapshot del Dataframe) viene smistato da Docker in una regione `/tmp` volatile caricata virtualmente e istantanea, cancellata al container shutdown preventivamente configurata nei block params di compose.

## 3. Storage Mounting (Il Pattern "Pet")

Differenza fondamentale da un SaaS puro: I volumi utente persistono in base all'Infrastruttura Active Directory dell'Ateneo.
Queste locazioni host (`/home`, `/nfs/projects`) vengono montate attivamente `read/write` nei container per pareggiare le autorizzazioni UNIX derivanti dal backend di logging in-memory (SSSD). Non ci sono `named volumes` per i dati utente.
