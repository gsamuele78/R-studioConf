# Risposta al Ricercatore — Sessioni RStudio Condivise tra Nodi

**Data:** 4 Giugno 2026
**Destinatario:** Ricercatore che ha segnalato il problema
**Oggetto:** Perché aprendo RStudio su due nodi diversi la sessione è la stessa

---

Cara/o Collega,

ti ringraziamo per la segnalazione. Ci hai fatto notare che collegandoti a RStudio Server su due nodi diversi del cluster (es. `biome-calc01` e `biome-calc02`) con lo stesso account, la sessione risultava essere la stessa, oppure una delle due veniva disconnessa. Abbiamo analizzato a fondo il problema: ecco cosa abbiamo scoperto.

## 1. Cosa sta succedendo esattamente

Il comportamento che hai osservato **non è un bug** del nostro sistema, ma una **limitazione architetturale di RStudio Server Open Source (OSS)** — la versione gratuita e open-source che utilizziamo sul cluster BIOME-CALC.

In pratica:

- RStudio Server OSS gestisce **un solo processo R (`rsession`) per utente**.
- Quando provi ad aprire una seconda sessione RStudio (da un altro browser, tab, o nodo), il server rileva che esiste già una sessione attiva per il tuo utente e **ricicla quella esistente** invece di crearne una nuova.
- Per questo motivo le due sessioni "collassano" in una sola: stai vedendo lo stesso ambiente R da due finestre diverse.

## 2. Cosa abbiamo testato per cercare di risolvere il problema

Abbiamo condotto un'indagine approfondita per capire se fosse possibile isolare le sessioni RStudio per nodo. Ecco tutte le strade che abbiamo esplorato:

### Tentativo 1 — Iniezione di variabili d'ambiente via `rsession-profile`

Abbiamo provato a esportare variabili `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` e `XDG_CACHE_HOME` puntando a percorsi specifici per nodo (es. `~/.biome-test/rstudio/biome-calc01/`) tramite lo script `/etc/rstudio/rsession-profile`.

- **Risultato:** Fallito. Le variabili non venivano ereditate dalla sessione R. RStudio continuava a scrivere i suoi file di stato nei percorsi standard (`~/.config/rstudio`, `~/.local/share/rstudio`).

### Tentativo 2 — Iniezione via script di login (`/etc/profile.d/`)

Abbiamo creato uno script di test (`/etc/profile.d/00_rstudio_user_logins.sh`) che esportava le variabili XDG con percorsi nodo-specifici per l'utente di test `sysadmin.user`.

- **Risultato:** Fallito. Le variabili erano visibili nel terminale (`env` le mostrava correttamente), ma dentro R (`Sys.getenv()`) risultavano vuote. RStudio scriveva ancora nei percorsi condivisi.

### Tentativo 3 — Ricerca di opzioni di configurazione

Abbiamo esaminato i file di configurazione di RStudio (`/etc/rstudio/rsession.conf`, `/etc/rstudio/rserver.conf`) e la documentazione ufficiale alla ricerca di parametri per controllare dove RStudio salva i file di sessione.

- **Risultato:** Non esistono opzioni di configurazione nella versione OSS per reindirizzare le directory di stato delle sessioni. Le opzioni `session-default-working-dir` e `session-default-new-project-dir` controllano solo la directory di lavoro, non lo stato della sessione.

La tabella riassuntiva delle prove è documentata in: `docs/user_guides/rstudio_session_isolation.md`

## 3. Fonti ufficiali e forum che confermano questa limitazione

Non siamo i soli ad aver incontrato questo problema. Ecco le fonti che confermano che si tratta di una limitazione nota di RStudio Server OSS:

### Documentazione ufficiale Posit (RStudio)

La guida ufficiale dell'amministratore di RStudio Server Professional (v0.99.902) afferma esplicitamente:

> *"RStudio Server Professional enables users to have multiple concurrent R sessions on a single server or load balanced cluster of servers (**the open-source version of RStudio Server supports only a single session at a time**)."*

Fonte: [RStudio Server Pro Administrator's Guide, §5.3 Multiple R Sessions](https://s3.amazonaws.com/rstudio-server/rstudio-server-pro-0.99.902-admin-guide.pdf)

La versione commerciale (oggi chiamata **Posit Workbench**) supporta sessioni multiple con l'opzione `server-multiple-sessions=1`, che **non esiste** nella versione OSS.

### Forum e comunità

Lo stesso problema è stato discusso in diverse sedi:

1. **Stack Overflow** — "Multiple simultaneous sessions of R studio in Linux Environment":
   Un utente riporta esattamente il tuo stesso problema: *"if two sessions try to log in at the same time it disconnects the previous session"*. La risposta conferma che RStudio Server OSS permette una sola sessione per utente.
   🔗 <https://stackoverflow.com/questions/56444182/multiple-simultaneous-sessions-of-r-studio-in-linux-environment>

2. **Posit Community** — "How to configure RStudio server to set the location of .local":
   Un amministratore di sistema tenta (senza successo) di usare `XDG_DATA_HOME` per spostare i file di sessione. La community conferma che nella versione OSS questo approccio non funziona.
   🔗 <https://forum.posit.co/t/on-linux-how-to-configure-rstudio-server-to-set-the-location-of-local-and-other-user-related-directories/107960>

3. **Open OnDemand Discourse** — "Is it possible to have multiple rstudio-server sessions":
   La discussione tecnica spiega che per avere sessioni multiple servono `/tmp` separati e isolamento a livello di container (Singularity/Docker), non ottenibile con la sola configurazione.
   🔗 <https://discourse.openondemand.org/t/is-it-possible-to-have-multiple-rstudio-server-sessions-on-the-same-server/526>

4. **GitHub OSC/bc_osc_rstudio_server Issue #1** — "Unable to run multiple RStudio Server sessions":
   Gli sviluppatori dell'Ohio Supercomputer Center hanno affrontato lo stesso identico problema e concluso che la causa è la directory condivisa `~/.rstudio`. Anche loro non hanno trovato una soluzione nella versione OSS.
   🔗 <https://github.com/OSC/bc_osc_rstudio_server/issues/1>

## 4. A cosa servono davvero i nodi multipli e il NAS condiviso

È importante chiarire **perché** abbiamo più nodi (`biome-calc01`, `biome-calc02`, …) e uno storage NAS condiviso, anche se non puoi avere due sessioni RStudio contemporanee.

### I nodi multipli servono per ospitare PIÙ UTENTI contemporaneamente

Il cluster non è pensato per dare a un singolo utente più sessioni RStudio in parallelo, ma per distribuire **persone diverse** su hardware diverso:

```
Ricercatore A (Mario)  →  biome-calc01  (sessione RStudio)
Ricercatore B (Anna)   →  biome-calc02  (sessione RStudio)
Ricercatore C (Luigi)  →  biome-calc01  (sessione RStudio)
```

Ogni ricercatore ha **una** sessione RStudio attiva su **un** nodo. Il portale web (Nginx) smista automaticamente le richieste al nodo meno carico, come un semaforo che regola il traffico.

### Il NAS condiviso (NFS) serve per accedere ai tuoi file da qualsiasi nodo

La directory home su NFS (`/nfs/home/tuo_utente`) è montata su **tutti** i nodi. Questo significa che:

- I tuoi script, dati, e risultati sono visibili da qualsiasi nodo a cui ti colleghi.
- Non devi copiare o ricaricare dataset enormi se cambi nodo (es. dopo un riavvio per manutenzione).
- Le librerie R che installi (`~/R/x86_64-pc-linux-gnu-library/`) sono disponibili su tutto il cluster.
- Se un nodo è pieno, puoi passare a un altro nodo senza perdere l'accesso ai tuoi file.

**In sintesi:** I nodi multipli danno **scalabilità orizzontale** (più persone possono lavorare insieme), il NAS condiviso dà **portabilità dei dati** (i tuoi file ti seguono ovunque). Non sono pensati per il multi-tasking individuale via RStudio.

## 5. Cosa puoi fare se ti servono più ambienti R contemporaneamente

Se il tuo flusso di lavoro richiede di eseguire più analisi R in parallelo, ecco le alternative disponibili **oggi** sul cluster:

| Metodo | Descrizione | Pro | Contro |
|--------|-------------|-----|--------|
| **RStudio Background Jobs** | Usa il pannello "Jobs" di RStudio per lanciare script in background | Resti nell'IDE RStudio | Solo esecuzione script, non interattivo |
| **`biome_make_cluster()`** | Parallelizza dentro una singola sessione R usando più core | Già disponibile, ottimizzato per il cluster | Stesso processo R, memoria condivisa |
| **Terminale TTYD + `tmux`** | Apri il terminale dal portale, usa `tmux` per gestire più sessioni R via `Rscript` | Sessioni multiple reali, indipendenti | Niente interfaccia grafica RStudio |
| **RStudio Desktop in locale** | Installa RStudio sul tuo laptop come secondo ambiente | Interfaccia completa | Devi trasferire i dati; richiede installazione locale |

Per il futuro, se la necessità di sessioni multiple per utente diventasse critica, le opzioni sul tavolo sono:

- **Posit Workbench** (versione commerciale a pagamento, supporta sessioni multiple in modo nativo)
- **Containerizzazione** (eseguire istanze RStudio separate in container Docker/Singularity — complesso, non ancora implementato)
- **IDE alternativi** come Positron (la nuova generazione di IDE Posit) o VS Code con estensioni R

## 6. Documentazione di riferimento sul nostro sistema

Per approfondire, abbiamo preparato due documenti:

- **`docs/user_guides/User_guide.md`** — Sezione 10: FAQ sul perché non puoi aprire più sessioni RStudio. Linguaggio semplice, pensato per tutti gli utenti.
- **`docs/user_guides/rstudio_session_isolation.md`** — Documento tecnico completo con tutta la cronologia dell'indagine, i test effettuati, i risultati, e i riferimenti alle fonti ufficiali.

---

Speriamo che questa spiegazione chiarisca il comportamento che hai osservato. Non è un problema del nostro sistema, ma una caratteristica (anzi, un limite) della versione open-source di RStudio Server che abbiamo scelto di adottare per evitare costi di licenza. Se hai altre domande o se il tuo flusso di lavoro richiede soluzioni diverse, siamo a disposizione per discuterne.

Cordiali saluti,
Il team BIOME-CALC
