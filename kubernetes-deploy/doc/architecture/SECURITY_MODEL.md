# Kubernetes Security Model

L'ecosistema Kubernetes RKE2 di Biome-Calc non eredita solo i paradigmi sysadmin di hardening Bare-Metal, ma sfrutta nativamente i constraint di sicurezza di Kubernetes per sigillare ulteriormente il perimetro di attacco in logica **Zero-Trust**.

## 1. Container Defense Boundaries (Phase 2 Hardened)

* **Capability Drops**: All `runAsUser: 0` pods immediately drop `CAP_SYS_ADMIN`, `SYS_CHROOT` (from RStudio), and `NET_BIND_SERVICE` (by shifting Nginx to internal port `8443` running as `UID 101`).
* **Non-Optimistic Initialization**: The RStudio container features a shell `postStart` lifecycle hook (`until wbinfo -p; do sleep 2; done`) protecting against race conditions if the AD sidecar boots slowly, ensuring PAM lookups never fail randomly on startup.
* **Noisy Neighbor Protection**: AI engine limits (Ollama) are brutally constrained to `2500m` CPU to prevent scheduler starvation across the Kubernetes worker nodes.
* **Telemetry via API**: The legacy Telemetry API which relied on mounting `/var/run/docker.sock` has been completely rewritten. It now uses a K8s `ServiceAccount` and `ClusterRoleBinding` to query metrics securely from the `metrics.k8s.io` API.
* Probes are strictly non-optimistic (e.g., Nginx will not report `Ready` until the TCP socket actually opens).

## 2. API Edge & Gateway Security

* **Unprivileged Nginx Bind**: Lo shifting interno al porto `8443` permette in Kubernetes di far girare il frontend come user non privilegiato (`101`), bloccando binding di basso livello.
* **Enterprise Web Security**: Nginx natively injects strict `HSTS`, `X-Frame-Options`, and `Content-Security-Policy` HTTP headers on all proxied traffic.

## 3. PKI Trust Implicit

Il container è in grado di importare autonomamente "Root of Trust" (step-ca) all'avvio. Tramite un `initContainer` in esecuzione prima dello startup asincrono, i manifest forzano il downloading del certificato Root dal cluster PKI interno. Se il download fallisce, il POD abortisce la partenza `Fail-Closed`.
