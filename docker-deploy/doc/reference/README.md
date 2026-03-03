# Configuration Reference: Parametri 12-Factor (.env)

Il sistema supporta integralmente la metodologia applicativa **12-Factor App**. Nessuna configurazione hardware o topologica vitale è hardcodata nelle immagini Docker o nei template.

Tutte le costanti di avvio, password, mount esterni e path di rete vengono inniettate dinamicamente dal file radice **`.env`** situato nella cartella corrente del deploy.

## Tassonomia del `.env`

I cluster configurativi attivi includono:

### 1. Versioning & Immagini

Tutti i tag delle immagini sono paramettrizzabili. Permette al deployment di scaricare artifact di Dev o Prod dal Registry semplicemente mutando `IMAGE_TAG`.

- `IMAGE_TAG=latest` (oppure custom git hash)
- `RSTUDIO_SSSD_IMAGE=botanical-geospatial-sssd`

### 2. Network Interface Routing

Port binding esplicito per prevenire sovrapposizioni su nodi multi-tenant.

- `RSTUDIO_PORT=8787`
- `HTTPS_PORT=443`
- `HOST_DOMAIN=tuo.dominio.edu`

### 3. Active Directory Pipes (Sicurezza)

Tutti gli IPC Socket dell'SSSD daemon Bare-Metal vengono re-diradati dinamicamente tramite costruttori ambientali, mappati da compose nei container runtime.

- `HOST_SSS_PIPES=/var/lib/sss/pipes`
- `HOST_KRB5_CONF=/etc/krb5.conf`

### 4. Telemetry Endpoint Limits

Il modulo Python rilegge l'ambiente container locale (`hostfs`). Questa direttiva avverte la logica API di scansionare dischi esatti, evitando che perlustri futili su RAMDisk virtuali consumino CPU.

- `TELEMETRY_NFS_HOME=/hostfs/nfs/home`
- `TELEMETRY_PROJECTS_DIR=/hostfs/nfs/projects`
- `TELEMETRY_TMP_DIR=/hostfs/tmp`

### 5. UI Application Logic (Feature Flags)

I template UI disabilitabili tramite variabili iniettate al Bootstrap dall'entrypoint `nginx`.

- `ENABLE_TELEMETRY_STRIP=true` (Controlla il banner live in UI prima del login Auth)

## Migrazione Sicura da Legacy (Vars)

A differenza delle vecchie dichiarazioni `config/*.vars.conf` (ora deprecate e relegate all'old layer bare-metal) che esponevano vulnerabilità parse-leak se importate malevolmente:

Il modulo `.env` viene divorato direttamente dal binario Docker-Daemon nativo ed ereditato (eslusivamente con `export`) solo ai processi Figli, limitando gli attacchi Privilege Escalation Env.
