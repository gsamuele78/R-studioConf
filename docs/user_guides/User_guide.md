---
title: "Guida BIOME-CALC per ricercatori (italiano)"
audience: researcher
status: current
source_path: docs/user_guides/User_guide.md
last_verified: 2026-10-07
sharepoint_section: Researcher Hub
---
<!-- docs/user_guides/User_guide.md -->
# Guida BIOME-CALC per ricercatori

BIOME-CALC è il server RStudio condiviso del laboratorio, pensato per raster
grandi, statistica spaziale e modelli bayesiani. Questa guida spiega cosa
cambia rispetto al vostro portatile e come scrivere codice R che qui gira
bene. Le stesse informazioni, più dettagliate, sono nelle guide in inglese
(*User Guide* e *Common Problems and Solutions*).

**In una frase:** se il vostro script gira sul vostro portatile, gira anche
qui. Non serve, e non va aggiunto, codice specifico per il server.

---

## 1. Entrare nel server

1. Aprite nel browser l'indirizzo del portale che vi hanno dato gli admin.
2. Inserite **una sola volta** nome utente e password di Ateneo.
3. Nel portale trovate le tessere:
   - **RStudio** — il vostro RStudio, nel browser;
   - **Terminal** — una riga di comando sul server (per `tmux`, `Rscript`, `git`);
   - **Files** — caricamento di file dal vostro PC, se attivo sul vostro nodo.
4. Cliccate su RStudio: non vi viene chiesta di nuovo la password.

Non servono VPN né client SSH. Non condividete la password con colleghi:
ognuno usa il proprio account.

**Una sessione per persona.** Potete avere una sola sessione R alla volta.
Se aprite RStudio in un secondo browser o su un secondo server, la prima
finestra si scollega con il messaggio *"another browser connected"*. Il
lavoro non è perso: la seconda finestra mostra la stessa sessione. È un
limite della versione gratuita di RStudio Server, non un guasto.

**La sessione vi aspetta.** Se chiudete il browser, la sessione R resta
attiva sul server per circa 48 ore. Dopo 48 ore di inattività viene chiusa.

---

## 2. Dove salvare i file

| Posto | Che cos'è | Per cosa | Attenzione |
|---|---|---|---|
| Cartella home (`~`) | Spazio di rete, uguale su tutti i server | Script, dati di partenza, risultati finali | Ha un **limite personale di spazio**; leggere migliaia di piccoli file è lento |
| `tempdir()` / `tempfile()` | Disco veloce da 400 GB dentro il server (`/Rtmp`) | File intermedi, pezzi di calcolo, file temporanei dei raster | Cancellato in automatico circa **48 ore** dopo l'ultimo uso; non è visibile dagli altri server |
| `/mnt/ProjectStorage` | Archivio condiviso dei progetti | Condividere dati nel progetto | Il permesso di scrittura è dato per progetto |
| `/tmp` | Piccola cartella di sistema | Niente | File grandi qui possono far cadere la sessione |

Non serve mai scrivere `/Rtmp`: `tempdir()` e `tempfile()` puntano già lì,
così lo stesso codice funziona anche sul portatile.

```r
saveRDS(risultato_intermedio, file.path(tempdir(), "pezzo_01.rds"))  # veloce, temporaneo
saveRDS(risultato_finale, "~/progetto/risultati/finale.rds")          # da conservare
```

---

## 3. Memoria e processori condivisi

Molte persone usano il server insieme, quindi ognuno ha una **quota equa**
di memoria e processori. La quota cresce quando il server è libero e cala
quando è pieno.

- `parallel::detectCores()` restituisce **la vostra** quota: scrivete sempre
  `makeCluster(parallel::detectCores() - 1)`, mai un numero fisso.
- `status()` mostra memoria, processori e disco veloce disponibili adesso.
- Le librerie matematiche usano un thread per processo, così il codice
  parallelo non sovraccarica il server. Non dovete impostare variabili sui
  thread.

**Avvisi prima del crash.** Alcune funzioni (`solve()`, `dist()`, `outer()`,
`expand.grid()`) su dati grandi possono chiedere più memoria di quella che
c'è. Prima di eseguirle il server stima la memoria necessaria e stampa un
avviso `BIOME-CALC:` con un'alternativa (per esempio `Matrix::Cholesky()` o
metodi sparsi). Leggetelo prima di proseguire: se la memoria finisce
davvero, la sessione R viene chiusa e si perde tutto ciò che non era salvato.

---

## 4. Le dieci abitudini

1. **Processori:** `parallel::detectCores()`, mai un numero fisso.
2. **Thread delle librerie matematiche:** non scrivete niente
   (niente `OPENBLAS_NUM_THREADS`, niente `blas_set_num_threads()`).
3. **File temporanei:** `tempfile()` e `tempdir()`, mai `/tmp`.
4. **Stan / cmdstanr / brms:** lasciate le impostazioni predefinite; non
   mandate l'output nella home.
5. **NIMBLE / TMB:** lasciate le impostazioni predefinite; la compilazione
   avviene già sul disco veloce.
6. **Raster grandi:** fidatevi di `terra` e `sf`; non alzate `memfrac` o
   `threads` in `terraOptions()`.
7. **`~/.Rprofile`:** solo impostazioni estetiche (prompt, cifre, colori),
   mai thread, `mc.cores` o `setwd()`.
8. **Pacchetti:** `install.packages("foo")` va nella vostra libreria
   personale; `bspm::install_sys("foo")` installa un binario pronto in
   pochi secondi; `renv` registra le versioni del progetto.
9. **Analisi lunghe:** in background (sezione 6), non nella console.
10. **Quando qualcosa si rompe:** raccogliete le informazioni (sezione 8),
    non scrivete solo "non funziona".

---

## 5. Calcolo parallelo: il cuoco e il forno

Molti usano `parLapply()` o `foreach` per parallelizzare. A volte i
worker cadono subito con errori come `unserialize(node$con)`. Succede con
pacchetti come nimble, terra, rstan, TMB o keras, perché i loro oggetti
vivono nel C++, fuori dalla memoria normale di R, e non si possono spedire
a un altro processo (lo dice il manuale di R: `?serialize`).

Un'analogia:

- la sessione R principale è il **cuoco**;
- i dati grezzi e il codice sono la **ricetta**;
- i worker paralleli sono i **forni**;
- compilare un modello o aprire un raster è **cuocere la torta**.

Non si può spedire ai forni una torta già cotta. **La regola d'oro: ai
forni si mandano solo ricetta e ingredienti; ogni forno compila il modello
o apre il file da solo.**

Quando sono caricati terra, sf o GDAL, il server trasforma in automatico
`mclapply()` in un cluster sicuro. Resta comunque meglio usare un cluster
esplicito, come negli esempi qui sotto.

### A. Modelli MCMC con nimble

Sbagliato: compilare `nimbleModel()` fuori e passarlo a `parLapply()`.
Giusto: compilare tutto **dentro** la funzione del worker.

```r
library(parallel)

run_mcmc_worker <- function(chain_id, dati_grezzi, codice_testo, inits) {
  library(nimble)
  modello <- nimbleModel(code = codice_testo, data = dati_grezzi,
                         inits = inits[[chain_id]])
  cmodello <- compileNimble(modello)            # compilato nel worker
  mcmc  <- buildMCMC(modello)
  cmcmc <- compileNimble(mcmc, project = modello)
  runMCMC(cmcmc, niter = 5000)                  # restituisce solo numeri
}

cl <- makeCluster(min(4, max(1, detectCores() - 1)), type = "PSOCK")
risultati <- parLapply(cl, 1:4, run_mcmc_worker,
                       dati_grezzi = miei_dati, codice_testo = mio_codice,
                       inits = lista_inits)
stopCluster(cl)
```

### B. Dati spaziali con terra

I raster non si passano ai worker. Soluzione migliore: passare il
**percorso del file**.

```r
worker_spaziale <- function(percorso_file) {
  library(terra)
  r <- rast(percorso_file)              # il worker apre il file da solo
  global(r, "mean", na.rm = TRUE)
}
```

Se il raster è già in memoria, usate `wrap()` / `unwrap()`:

```r
raster_imballato <- terra::wrap(mio_raster)

worker_spaziale <- function(raster_pacchetto) {
  library(terra)
  r <- unwrap(raster_pacchetto)
  global(r, "mean", na.rm = TRUE)
}
```

### C. Cicli paralleli con foreach

Stesse regole: la compilazione va dentro il blocco `%dopar%`.

```r
library(foreach)
library(doParallel)

cl <- parallel::makeCluster(min(4, max(1, parallel::detectCores() - 1)))
registerDoParallel(cl)

risultati <- foreach(i = 1:4, .packages = "nimble") %dopar% {
  modello  <- nimbleModel(mio_codice, data = miei_dati, inits = inits[[i]])
  cmodello <- compileNimble(modello)
  cmcmc <- compileNimble(buildMCMC(modello), project = modello)
  runMCMC(cmcmc, niter = 1000)
}
parallel::stopCluster(cl)
```

### D. Machine learning con keras / tensorflow

I modelli keras non viaggiano tra processi, e TensorFlow tende a usare
tutti i processori. Limitate i thread in ogni worker, salvate il modello su
file e restituite solo il nome del file.

```r
train_keras_worker <- function(learning_rate, dati_x, dati_y) {
  library(keras3)
  tensorflow::tf$config$threading$set_intra_op_parallelism_threads(2L)
  tensorflow::tf$config$threading$set_inter_op_parallelism_threads(2L)

  modello <- keras_model_sequential(input_shape = ncol(dati_x)) |>
    layer_dense(units = 64, activation = "relu") |>
    layer_dense(units = 1)
  modello |> compile(optimizer = optimizer_adam(learning_rate), loss = "mse")
  modello |> fit(dati_x, dati_y, epochs = 10, verbose = 0)

  nome_file <- file.path(tempdir(), paste0("modello_lr_", learning_rate, ".keras"))
  save_model(modello, nome_file)
  nome_file                              # il nome del file, non il modello
}
```

---

## 6. Analisi lunghe e grafici in background

Se lo script dura ore, non lanciatelo con "Run" nella console: se il
browser si chiude male o la memoria finisce, il lavoro non salvato si perde.

**Metodo A — RStudio Background Jobs (per tutti).** Nella scheda
**Background Jobs**, accanto alla Console, scegliete *Start Background Job*,
selezionate lo script e premete Start. Il calcolo continua sul server anche
se chiudete RStudio e spegnete il PC.

**Metodo B — tmux (per utenti esperti).** Nel **Terminal** del portale:

```bash
tmux                         # compare una barra verde in basso
Rscript il_mio_script.R      # avvia l'analisi
# Ctrl+B, rilasciate, poi D  → uscite lasciandola in esecuzione
tmux attach                  # il giorno dopo: ci tornate
```

Nei cicli lunghi salvate i risultati con `saveRDS()` ogni tanto: un
problema costerà solo l'ultimo pezzo.

**I grafici dei processi in background non compaiono nel pannello Plots**,
perché quei processi non hanno uno schermo. Salvateli su file:

```r
# ggplot2
ggsave("risultato.png", plot = mio_grafico, width = 8, height = 6)

# grafica di base
png("risultato.png", width = 800, height = 600)
plot(dati)
dev.off()   # chiude e salva il file
```

Nel pannello Plots, dentro RStudio, i grafici compaiono normalmente. Per
provarlo: `plot(1, 1, main = "prova")`. Se non compare, riavviate R
(Session → Restart R) e riprovate; se ancora non compare, scrivete agli
admin (sezione 8).

**Niente `.RData` automatico.** Alla chiusura l'ambiente di lavoro non viene
salvato, perché ricaricare un `.RData` di molti GB fa crollare il browser
("Aw, Snap!"). Salvate ciò che vi serve con `saveRDS()`.

---

## 7. Problemi più comuni

| Cosa vedete | Cosa fare |
|---|---|
| `cannot open compressed file ... Disk quota exceeded` quando salvate | La vostra cartella home è piena (limite personale). Cancellate file inutili, salvate gli intermedi in `tempdir()`, chiedete più spazio agli admin |
| `Permission denied` su `/mnt/ProjectStorage` | Non avete il permesso di scrittura su quel progetto: salvate nella home e chiedete agli admin |
| `cannot allocate vector of size ...` o avviso `BIOME-CALC:` sulla memoria | Controllate `status()`, seguite l'alternativa proposta, lavorate a pezzi |
| "R session aborted" | La memoria è finita. Ripartite dall'ultimo `saveRDS()`; se avevate usato `biome_save_session()`, ripristinate con `biome_load_session()` |
| Codice parallelo fermo allo 0 % di CPU | Usate un cluster esplicito e caricate pacchetti e dati dentro i worker (sezione 5) |
| `detectCores()` dà meno processori del previsto | È la vostra quota: è voluto |
| Avviso `safe_setwd` e file salvati nella cartella sbagliata | La cartella non esiste (spesso un errore di battitura): la cartella di lavoro **non è cambiata**. Correggete il percorso; meglio ancora usate `here::here()` |
| I file in `/Rtmp` sono spariti | È spazio temporaneo: viene pulito dopo circa 48 ore. Copiate i risultati nella home |

La guida in inglese *Common Problems and Solutions* spiega ogni caso in
dettaglio.

---

## 8. Come chiedere aiuto

Non scrivete solo "non funziona". Incollate nel messaggio, come testo (non
come screenshot):

1. `status()`;
2. `sessionInfo()`;
3. `traceback()`, eseguito subito dopo l'errore;
4. il messaggio di errore esatto;
5. il percorso dello script e l'ora approssimativa;
6. se R non parte proprio: il contenuto di `/tmp/biome_boot_errors_*.log`
   (nel Terminal: `cat /tmp/biome_boot_errors_*.log`).

Mandate tutto al referente BIOME-CALC del vostro laboratorio (il contatto
compare nel messaggio di benvenuto di R e del Terminal).

Gli admin non vi chiederanno mai di modificare il vostro script per
adattarlo al server: se il codice gira sul portatile deve girare anche qui,
e le correzioni si fanno sul server.

---

## 9. Impostazioni vecchie da cancellare

Negli script vecchi potreste trovare queste impostazioni. Oggi non fanno
niente: toglietele.

`BIOME_FORCE_NFS_TMP`, `BIOME_FORCE_TMP=/tmp`, `R_DISABLE_QUOTA`,
`BIOME_LEGACY_BLAS`.

---

## 10. Per approfondire

- **BIOME-CALC R Cheat Sheet** — le regole in una pagina.
- **Common Problems and Solutions** — messaggi di errore e soluzioni.
- **Safe Parallel R — Do's and Don'ts** — esempi di codice parallelo.
- **Working with Large Spatial Correlation Matrices** — `terra` / `sf` su
  dati molto grandi.
- **NIMBLE User Guide** — catene MCMC parallele.
