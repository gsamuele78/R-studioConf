# Component Reference: Nginx Gateway (Kubernetes)

Il reverse proxy Nginx all'interno di Kubernetes svolge la medesima funzione di API Gateway asincrono verso RStudio, TTYD e Telemetry, ma è stato nativamente integrato con i ConfigMap.

## Architettura del Routing e Sicurezza

A differenza del proxy in Docker Compose, questo Nginx gira in modalità totalmente **Unprivileged** (UID 101).

1. L'Ingress Kubernetes (es. Traefik) riceve il traffico su `:443` ed esegue l'offloading o il passthrough.
2. Nginx riceve internamente il traffico sulla porta non privilegiata `:8443`. Nessuna `NET_BIND_SERVICE` è richiesta.
3. Il proxy attinge la sua configurazione e le regole di headers (`HSTS`, `CSP`) dal `configmaps.yaml`, forzando sicurezza enterprise su tutte le connessioni.

## Integrazione OIDC Auth-Request

Nginx non contiene credenziali. Utilizza il sub-request routing `auth_request` per interrogare il pod limitrofo `oauth2-proxy`:

1. Qualsiasi richiesta a `/rstudio-inner/` lancia una query interna a `http://oauth2-proxy...`.
2. OIDC valida la sessione. Se fallisce redirige a Keycloak. Se passa, inocula lo Header `X-Forwarded-User` al layer backend.
