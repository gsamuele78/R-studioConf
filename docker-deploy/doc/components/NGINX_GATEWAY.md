# Component Reference: Nginx Gateway (Dockerized)

Il reverse proxy basato su Alpine Linux svolge l'identica funzione del deployment Bare-Metal implementato nello script `31_setup_web_portal.sh`. Costituisce l'edge unificato per RStudio, il Web Portal Botanico (UI), TrueNAS (Files) e il cluster TTYD (Terminale).

## Web Portal Templating

A differenza dei normali container Nginx che espongono pagine statiche, questo cluster genera il frontend attivamente *al Boot*:

1. `entrypoint_nginx.sh` estrae il file `portal_index.html.template`.
2. Applica la funzione sysadmin POSIX `process_template` (iniettata da `common_utils.sh`), compilando variabili logiche (es. `%%TELEMETRY_STRIP_DISPLAY%%`).
3. Applica feature flag condizionali presi da `docker-compose.yml` (es. Spegnimento della UI Telemetrica Pre-Login).

## Architettura del Routing

Tutto il traffico ingressa da Nginx (`:443`/`:80`) e viene smistato al loopback Host via `upstream` nativo.

- `/`: Indirizza alle grafiche HTML del Portal (Statica, ma generata dinamicamente al boot e segregata dalle cache cross-origin).
- `/rstudio-inner/`: Rewritten URL che sfocia nel container RStudio (`:8787`). Gestisce sia RPC (JSON Payload) che sessioni WebSocket.
- `/api/telemetry/`: Puntatore localhost all'API Python Uvicorn.
- `/files/` & `/status/`: Moduli Iframe per Nextcloud e Grafana.
- `/terminal/`: Inoltro TCP/WebSocket al TTYD service perimetrale.

## PRD Compliance: Tunning Ottimizzato

Sono state rimosse direttive compiacenti (logiche ottimistiche proxy), imponendo mitigazioni rigorose:

- **Timeouts Allineati:** Nginx disintegra la sessione in syncro con RStudio (es. `RSESSION_TIMEOUT_MINUTES`), non persistendo connessioni client ghosted (Socket Leakage prevention).
- **Buffer Tunnings:** Incremento limitato e scalare di `proxy_buffer_size`, idoneo per le transazioni JSON-RPC corpose di Shiny Apps senza esporre vulnerabilità OOM all'Nginx master process.
- **Risoluzione Socket IPv6:** Rimozione dei conflitti binding IPv6 che forzavano Nginx al crash o all'early-exit su Linux Kernel configurati solo su stack IPv4 legacy.
