# Operations & Maintenance Reference

Questa guida descrive le checklist Sysadmin per il mantenimento a run-time, il debug e la gestione del cluster RStudio Dockerizzato.

## 1. Monitoraggio dei Log & Health (`docker compose`)

In virtù del design "Pet", i log non sono effimeri ma aggregati dallo unit S6 del supervisor o tramite driver Compose JSON.

- **Check Stato del Cluster:**

  ```bash
  docker compose ps -a
  ```

- **Live Tail dei Servizi RStudio e Auth:**

  ```bash
  docker compose logs -f rstudio-sssd
  ```

- **Troubleshooting Proxy / Timeout (Nginx):**
  L'error log Nginx è fondamentale per i JSON RPC errors di Shiny Apps.

  ```bash
  docker compose logs -f nginx-portal | grep "error"
  ```

## 2. Gestione Archiviazione & OOM Hunter

Le logiche periodiche (es. pulizia Zombi, archiviazione AD `/nfs`) avvengono tramite crontab eseguiti sull'Host Linux:

### OOM (Out Of Memory) / Orphan Cleanup

Lo script bare-metal compilato dai template `cleanup_r_orphans.sh` intercetterà automaticamente (tramite PID mapping dell'Host network) qualsiasi `rsession` che abusi CPU Time senza padrone. L'Host lo distruggerà via `SIGTERM` salvaguardando il mount `tmpfs` RAM associato al container RStudio.

### `tmpfs` Lifecycle

Per evitare RAM saturation, i temporary files dell'istanza container (/tmp) sono mappati a run-time usando `tmpfs`. Un reset di RStudio svuoterà chirurgicamente il temporary storage:

```bash
docker compose restart rstudio-sssd
```

## 3. Gestione TLS Certificates (Step-CA/ACME)

Se i certificati SSL del portale web scadono, Nginx e il container TTYD smetteranno di funzionare. Il sistema di enrolling ACME/Step-CA esegue check nativi al boot:

### Rotazione Forzata del Certificato

In caso di compromissione o modifica URL:

1. Revocare lato root-CA.
2. Inserire nuovo Access Token nel file `.env` (`STEP_TOKEN=""`)
3. Riavviare il reverse_proxy Docker per attivare l'entrypoint ACME script.

```bash
docker compose restart nginx-portal
```

## 4. Aggiornamento Versioni (Build & Pinning)

Data la politica di "Version Pinning" sulle dipendenze Python/R:

- L'aggiornamento a una minor del portale richiederà una ricompilazione locale sfruttando la `cache`.
- I repository C2D4U di `bspm` e `CRAN` (utilizzando `Ncpus = detectCores()`) accorciano drammaticamente il build-time da 1 ora a pochi minuti.

```bash
docker compose --profile sssd build --no-cache
```
