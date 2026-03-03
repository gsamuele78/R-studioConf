# Security Model: Docker Architecture & Constraints

L'ecosistema Dockerizzato di Biome-Calc non eredita solo i paradigmi sysadmin di hardening Bare-Metal, ma sfrutta intrinsecamente i container namespace per sigillare ulteriormente il perimetro di attacco.

La progettazione segue il modello "Defence-in-Depth" e aderisce al PRD "Non-Optimistic UI/Logic" (ogni input è malevolo fino a prova contraria server-side).

## 1. Container Defense Boundaries

### CPU/Mem Constraints & Livelock Prevention

Per prevenire attacchi DoS o saturazione delle risorse Host (OOM Kernel Panic):

- Il file `docker-compose.yml` impiega blocchi `deploy.resources.limits` coercitivi (es: limite a 16GB su Ollama e 60GB su RStudio).
- La direttiva `TMPFS` rimpiazza le mount standard sul `/tmp` vettoriale dell'applicativo. Non solo previene Storage Runout (100% inode exhaust), ma distrugge forensicamente le cache di pacchetto ad ogni restart.

### Ephemeral Configuration & File System Isolation

Nessun file testuale `conf` viene generato permanentemente (es. `Rprofile.site`, `00_audit.R`).

- All'avvio, l'entrypoint bash adopera il comando `mktemp` per assemblare la configurazione partendo dalle variabili `.env`.
- Questo previene severamente *Race Conditions*, *Symlink Attacks* e Type-squatting, tipici dei filesystem layer multipli, scrivendo su UUID randomizzati temporanei prima del mapping atomico.

## 2. API Edge and Network Topology

### Host-Only AI e Telemetry Bindings

Tutti i microservizi secondari (Ollama, Biome Telemetry FastAPI, RStudio RPC) sono segregati dalla LAN pubblica.

- Le direttive di expose vengono disarmulate forzando l'indirizzo `127.0.0.1` nel runtime ENV, come in `OLLAMA_HOST=127.0.0.1:11434`. Nessuna porta aperta oltrepassa lo stack di Nginx Reverse Proxy.
- Previene access-bypass qualora un firewall `iptables` dell'host fisico crollasse.

### Nginx Strict Gateway & CSRF Verification

- Le route di Auth (come la `/auth-sign-out`) per l'RStudio RPC non supportano JSON fallbacks ottimistici; richiedono validazione stretta dei token CSRF iniettati *Solo* dal Web Portal originario (Referer validation).
- I Buffer TTY (`client_max_body_size`, `proxy_buffers`) sono ridotti al minimo essenziale per assorbire i Payload WebSocket mitigando "Slowloris" stack flood.

## 3. Software Lifecycle Reliability

- L'installatore di pacchetti R (`install_botanical_packages.R`) adotta `r-cran-bspm` disabilitando l'RCE compilativa standard a favore dei pacchetti binari digitalmente firmati (c2d4u apt repository). Se fallisce, il multithreading ne ammortizza il tempo.
- FastAPI, Uvicorn, e Pydantic sono "Version Pinned" in fase di `pip install`. Le dipendenze fantasma upstream non comprometteranno più, silenzianti, le versioni Docker compilate mesi dopo la stesura del codice.

## 4. PKI Trust Implicit

Il container è in grado di importare autonomamente "Root of Trust" (es. certificate server Step-CA o AD-CS) all'avvio. Tramite `manage_pki_trust.sh`, il container invoca `.env` parameters per iniettare e processare il fingerprint SHA256 prima che ogni reverse-proxy possa avviare la convalida SSL, bloccando attacchi Man-In-The-Middle all'interno della demilitarized zone (DMZ) aziendale.
