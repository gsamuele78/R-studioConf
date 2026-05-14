# ============================================================
# BLOCK 1 OPTIMIZED - AOH TO RIJ FOR PRIORITIZR
# VERSIONE COMPLETA AGGIORNATA DOPO PREFLIGHT + HPC SAFEGUARDS
# ============================================================
#
# Obiettivo:
#   Costruire una tabella RIJ per prioritizr a partire dai raster AOH
#   delle orchidee, aggregando le celle AOH positive su una griglia globale
#   a 30 arc-min, in parallelo e per chunk.
#
# Significato per la Ricerca Botanica:
#   Questo script automatizza un passaggio cruciale nell'analisi della
#   distribuzione delle specie di orchidee. L'Area di Habitat (AOH)
#   rappresenta le aree potenzialmente idonee per una specie. Aggregando
#   queste aree su una griglia standardizzata (30 arc-min), creiamo una
#   base dati (RIJ) fondamentale per i modelli di prioritizzazione della
#   conservazione. Questo ci permette di identificare le aree prioritarie
#   per la protezione, garantendo che gli sforzi di conservazione siano
#   focalizzati dove sono più necessari.
#
# Risultato del preflight:
#   Su 10 raster controllati:
#     - 7 avevano celle non-NA
#     - 7 avevano celle > 0
#     - 0 avevano celle == 0
#     - 3 erano completamente NA
#
# Quindi la regola corretta per identificare AOH è:
#     presence_rule <- "positive"
#
# Caratteristiche (Logica scientifica mantenuta):
#   - processa i raster AOH in parallelo per chunk
#   - salva un file RIJ per chunk
#   - salva un log per chunk
#   - evita append continui su un unico CSV enorme
#   - include un preflight check sui primi raster
#   - include gestione errori a livello di specie e chunk
#   - riparte da zero cancellando i vecchi output incompatibili (se overwrite_previous_outputs = TRUE)
#   - riprende da log esistenti (se resume_from_existing_logs = TRUE)
#
# Output principali:
#   - species_table_all.csv
#   - rij_species_cell_30arcmin_AOH_direct_all.csv
#   - planning_units_30arcmin_all.csv
#   - AOH_direct_mapping_log_all.csv
#   - chunk_processing_summary_all.csv
#   - AOH_preflight_check_first_rasters.csv
#   - species_without_rij_rows.csv, se necessario
#
# ------------------------------------------------------------
# AGGIORNAMENTI PER L'ESECUZIONE SU CLUSTER HPC (Safeguards)
# Questa versione non altera in alcun modo i calcoli spaziali
# originali. Sono state introdotte protezioni strutturali per gestire
# 30.000+ rasters senza rischiare il blocco dei nodi di calcolo:
#
#   1. Motore a Blocchi (No Out-Of-Memory): L'uso di values() su rasters
#      molto estesi saturava la RAM e causava il crash del nodo.
#      I raster vengono ora letti a "fette" sequenziali (blocks).
#      Questo evita di caricare interi file raster enormi in memoria,
#      processandoli in porzioni gestibili.
#   2. Ripristino Intelligente (Auto-Resume): Attivando il parametro
#      resume_from_existing_logs, lo script riprende un lavoro interrotto
#      leggendo i log in /Rtmp ed elaborando solo le specie mancanti.
#      Questo permette di recuperare da interruzioni senza dover ricominciare
#      l'intero processo da capo.
#   3. Tolleranza di Rete (Safe I/O): La funzione safe_fwrite riprova
#      a salvare i file se il disco NFS subisce un momentaneo sovraccarico.
#      Questo previene fallimenti dovuti a instabilità temporanee della rete.
#   4. Prevenzione Stalli (Timeouts): Se un file .tif è corrotto, GDAL
#      può bloccarsi all'infinito. Inserito timeout di 20 min per specie.
#      Questo assicura che il processo non si blocchi indefinitamente su
#      singoli file problematici.
#   5. Batch Merging: L'unione finale dei 30.000 CSV viene fatta a lotti
#      di 500 file per non saturare la memoria in fase di assemblaggio.
#      Questo evita problemi di memoria durante l'aggregazione finale dei risultati.
#
# ------------------------------------------------------------
# NOTE DI PORTABILITÀ (COME USARE LO SCRIPT SU ALTRI SISTEMI):
# Questo script può girare ovunque (Linux, macOS, Windows), ma tieni
# a mente queste semplici regole per l'hardware:
#
# 1) SISTEMA OPERATIVO: Il calcolo parallelo usa `mclapply`. Su Linux e
#    macOS userà tutti i core assegnati in `n_workers`. Su Windows girerà
#    comunque senza errori, ma su 1 SOLO CORE (limite strutturale di R).
# 2) RAM e HARDWARE: Sul supercomputer usiamo 16 worker. Se lanci questo
#    script su un portatile o su un PC standard (es. 16 GB di RAM),
#    assicurati di abbassare `n_workers` a 2 o 3, altrimenti il computer
#    si congelerà.
# 3) PATHS: Se il sistema non ha una cartella `/Rtmp`, cambia la riga
#    `scratch_root` per usare la cartella temporanea automatica di R:
#    scratch_root <- file.path(tempdir(), "prioritizr_scratch_30arcmin")
# ============================================================
#
# Caricamento delle librerie necessarie per l'elaborazione dei dati spaziali e tabellari.
library(data.table)
library(terra)
library(parallel)
# Impostazione di `scipen` per evitare la notazione scientifica nei numeri, utile per ID e coordinate.
options(scipen = 999)
# ------------------------------------------------------------
# 1. PATHS E ARCHITETTURA DISCHI (NFS vs LOCAL SCRATCH)
# ------------------------------------------------------------
# Definizione dei percorsi principali per i dati di input e output.
base_dir <- "/nfs/home/michele.lussu/rabinowitz/Area of Habitat"
aoh_dir <- file.path(base_dir, "AOH_orchids")
# Directory finale per i risultati aggregati.
final_out_dir <- file.path(base_dir, "prioritizr_all_species_30arcmin")
dir.create(final_out_dir, recursive = TRUE, showWarnings = FALSE)
# --- CODICE ORIGINALE ---
# chunk_dir <- file.path(out_dir, "rij_chunks")
# log_dir <- file.path(out_dir, "rij_chunk_logs")
# ...
# --- NUOVO CODICE ---
# Spiegazione del cambiamento: Scrivere e sovrascrivere decine di migliaia di
# file temporanei direttamente su disco di rete (/nfs) è molto lento.
# Abbiamo deviato tutti i file temporanei su `/Rtmp`, che è il disco fisico
# ultra-veloce della macchina (SSD). Alla fine, copiamo solo il file finale su NFS.
# Questo migliora drasticamente le performance e riduce il carico sulla rete.
scratch_root <- "/Rtmp/biome_michele.lussu/prioritizr_scratch_30arcmin"
chunk_dir <- file.path(scratch_root, "rij_chunks")
log_dir <- file.path(scratch_root, "rij_chunk_logs")
tmp_root <- file.path(scratch_root, "terra_tmp_parallel")
# Creazione delle directory necessarie per i file temporanei e i chunk.
dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_root, recursive = TRUE, showWarnings = FALSE)
# Definizione dei percorsi per i file di output intermedi e finali, salvati inizialmente nello scratch locale.
species_file <- file.path(scratch_root, "species_table_all.csv")
rij_file <- file.path(scratch_root, "rij_species_cell_30arcmin_AOH_direct_all.csv")
log_file <- file.path(scratch_root, "AOH_direct_mapping_log_all.csv")
planning_units_file <- file.path(scratch_root, "planning_units_30arcmin_all.csv")
chunk_summary_file <- file.path(scratch_root, "chunk_processing_summary_all.csv")
species_signature_file <- file.path(scratch_root, "species_table_signature.txt")
no_rij_file <- file.path(scratch_root, "species_without_rij_rows.csv")
preflight_file <- file.path(scratch_root, "AOH_preflight_check_first_rasters.csv")
# ------------------------------------------------------------
# 2. SETTINGS
# ------------------------------------------------------------
# Risoluzione target per la griglia di output (in gradi).
target_res <- 0.5
# Proporzione target (non utilizzata direttamente in questo script, ma mantenuta per coerenza).
target_prop <- 0.05
# Configurazione per l'esecuzione su cluster HPC con elevata disponibilità di RAM.
# `n_workers` definisce quanti processi paralleli avviare.
n_workers <- 16L
# `chunk_size` definisce quante specie vengono processate da ciascun worker in un singolo blocco.
chunk_size <- 2L
# Se TRUE, cancella tutti gli output precedenti e ricomincia da capo. Utile per testare modifiche.
overwrite_previous_outputs <- TRUE
# Se TRUE, tenta di riprendere l'esecuzione da log esistenti, saltando i chunk già completati.
resume_from_existing_logs <- FALSE
# Regola per identificare le celle AOH: "positive" significa celle con valore > 0.
presence_rule <- "positive"
# Modalità di calcolo dell' "amount" (quantità) per ogni cella: "count" (conteggio) o "area_km2".
amount_mode <- "count"
# Esecuzione di un controllo preliminare su un piccolo numero di raster per verificare la correttezza.
run_preflight_check <- TRUE
# Numero di file da controllare nel preflight check.
n_preflight_files <- 10L
# Se TRUE, esegue lo script solo su un sottoinsieme limitato di specie per test rapidi.
run_limited_species_test <- FALSE
# Numero di specie da testare se `run_limited_species_test` è TRUE.
n_species_test <- 500L
# Controllo della firma dei file di input per assicurarsi che non siano cambiati tra le esecuzioni.
check_species_signature <- FALSE
# ------------------------------------------------------------
# 3. TEMPLATE 30 ARC-MIN
# ------------------------------------------------------------
# Creazione di un raster template vuoto che definisce la griglia globale di output (30 arc-minuti).
template <- rast(xmin = -180, xmax = 180, ymin = -90, ymax = 90, resolution = target_res, crs = "EPSG:4326")
# Calcolo dell'area di ciascuna cella del template in km², utile se `amount_mode` è "area_km2".
area_r <- cellSize(template, unit = "km")
area_values <- values(area_r, mat = FALSE)
# Informazioni sul template per passarlo alle funzioni worker.
template_info <- list(xmin = -180, xmax = 180, ymin = -90, ymax = 90, resolution = target_res, crs = "EPSG:4326")
# ------------------------------------------------------------
# 4. HELPER FUNCTIONS
# ------------------------------------------------------------
# --- CODICE AGGIUNTIVO ---
# Spiegazione del cambiamento: Se il disco NFS fa un "singhiozzo" di pochi secondi,
# un salvataggio classico andrebbe in crash. `safe_fwrite` riprova a salvare 3 volte
# prima di arrendersi, donando molta resilienza all'infrastruttura.
# Questo è fondamentale per processi lunghi che potrebbero incontrare problemi di rete temporanei.
safe_fwrite <- function(dt, file, append = FALSE, max_retries = 3) {
  for (i in 1:max_retries) {
    err <- tryCatch(
      {
        data.table::fwrite(dt, file, append = append)
        return(TRUE)
      },
      error = function(e) e
    )
    Sys.sleep(3) # Attende 3 secondi prima di riprovare
  }
  warning("Impossibile scrivere il file dopo ", max_retries, " tentativi: ", file)
  return(FALSE)
}
# Funzione per pulire i nomi delle specie dai file raster (.tif) e normalizzare spazi.
clean_species <- function(x) trimws(enc2utf8(gsub("\\s+", " ", gsub("_+", " ", gsub("\\.tif$", "", x, ignore.case = TRUE)))))
# Funzioni per creare nomi di file sicuri per i chunk di output e i log.
safe_chunk_file <- function(chunk_id) file.path(chunk_dir, sprintf("rij_chunk_%05d.csv", chunk_id))
safe_log_file <- function(chunk_id) file.path(log_dir, sprintf("log_chunk_%05d.csv", chunk_id))
# Funzione per creare una "firma" (checksum/metadata) dei file di input, utile per verificare se sono cambiati.
make_species_signature <- function(dt) {
  sig_dt <- copy(dt)
  sig_dt[, file_basename := basename(input_file)]
  sig_dt[, file_size := file.info(input_file)$size]
  sig_dt[, file_mtime := as.character(file.info(input_file)$mtime)]
  sig_dt <- sig_dt[, .(id, name, file_basename, file_size, file_mtime)]
  paste(capture.output(print(sig_dt)), collapse = "\n")
}
# Funzioni per scrivere e leggere la firma dei file.
write_species_signature <- function(signature, signature_file) writeLines(signature, signature_file, useBytes = TRUE)
read_species_signature <- function(signature_file) {
  if (!file.exists(signature_file)) {
    return(NULL)
  }
  paste(readLines(signature_file, warn = FALSE), collapse = "\n")
}
# Funzione per determinare quali celle soddisfano la regola di presenza (es. > 0).
get_presence_cells <- function(vals, presence_rule) {
  if (presence_rule == "positive") {
    return(which(!is.na(vals) & vals > 0))
  }
  if (presence_rule == "non_na") {
    return(which(!is.na(vals)))
  }
  if (presence_rule == "zero") {
    return(which(!is.na(vals) & vals == 0))
  }
  if (presence_rule == "positive_or_zero") {
    return(which(!is.na(vals) & vals >= 0))
  }
  stop("presence_rule non valido: ", presence_rule)
}
# Funzione per controllare un singolo raster, estraendo metadati e statistiche.
check_one_raster <- function(f) {
  r <- tryCatch(rast(f), error = function(e) e)
  if (inherits(r, "error")) {
    return(data.table(file = basename(f), status = "raster_read_error", ncell = NA_integer_, n_na = NA_integer_, n_non_na = NA_integer_, n_gt_0 = NA_integer_, n_eq_0 = NA_integer_, min_value = NA_real_, max_value = NA_real_, unique_values_head = NA_character_, xmin = NA_real_, xmax = NA_real_, ymin = NA_real_, ymax = NA_real_, crs = NA_character_, note = conditionMessage(r)))
  }
  # --- NUOVO CODICE (Preflight a Blocchi OOM-Free) ---
  # Spiegazione: Anche solo controllare un file da 1 miliardo di celle in un colpo
  # solo satura la memoria. Applichiamo la lettura sequenziale a blocchi (fette)
  # anche alla funzione di verifica iniziale. Questo evita OOM anche durante il preflight.
  bs <- blocks(r)
  n_na <- 0
  n_non_na <- 0
  n_gt_0 <- 0
  n_eq_0 <- 0
  min_v <- Inf
  max_v <- -Inf
  head_vals <- c()
  tryCatch({
    terra::readStart(r)
    for (b in 1:bs$n) {
      vals <- terra::readValues(r, row = bs$row[b], nrows = bs$nrows[b], mat = FALSE)
      not_na <- !is.na(vals)
      if (any(not_na)) {
        v_non_na <- vals[not_na]
        n_na <- n_na + sum(!not_na)
        n_non_na <- n_non_na + length(v_non_na)
        n_gt_0 <- n_gt_0 + sum(v_non_na > 0)
        n_eq_0 <- n_eq_0 + sum(v_non_na == 0)
        min_v <- min(min_v, min(v_non_na))
        max_v <- max(max_v, max(v_non_na))
        if (length(head_vals) < 10) {
          head_vals <- unique(c(head_vals, v_non_na))
          head_vals <- head_vals[!is.na(head_vals)]
          if (length(head_vals) > 10) head_vals <- head_vals[1:10]
        }
      } else {
        n_na <- n_na + length(vals)
      }
    }
  }, finally = {
    try(terra::readStop(r), silent = TRUE)
  })
  if (is.infinite(min_v)) min_v <- NA_real_
  if (is.infinite(max_v)) max_v <- NA_real_
  data.table(file = basename(f), status = "ok", ncell = ncell(r), n_na = n_na, n_non_na = n_non_na, n_gt_0 = n_gt_0, n_eq_0 = n_eq_0, min_value = min_v, max_value = max_v, unique_values_head = if (length(head_vals) > 0) paste(head_vals, collapse = ", ") else NA_character_, xmin = ext(r)$xmin, xmax = ext(r)$xmax, ymin = ext(r)$ymin, ymax = ext(r)$ymax, crs = crs(r), note = NA_character_)
}
# Funzione per rimuovere un file se esiste.
remove_if_exists <- function(f) {
  if (file.exists(f)) file.remove(f) else FALSE
}
# ------------------------------------------------------------
# 5. LIST AOH RASTERS
# ------------------------------------------------------------
# Verifica che la directory dei raster AOH esista.
if (!dir.exists(aoh_dir)) stop("AOH directory non trovata: ", aoh_dir)
# Lista tutti i file raster .tif nella directory specificata.
aoh_files <- sort(list.files(aoh_dir, pattern = "\\.tif$", full.names = TRUE, recursive = FALSE, ignore.case = TRUE))
# Controllo se sono stati trovati file raster.
if (length(aoh_files) == 0) stop("Nessun raster .tif trovato in: ", aoh_dir)
cat("\nRaster AOH trovati:", length(aoh_files), "\n")
# Pulisce i nomi dei file per ottenere nomi di specie puliti.
species_names <- clean_species(basename(aoh_files))
# Crea una tabella dati con informazioni su ogni specie/raster.
species_dt <- data.table(id = seq_along(aoh_files), name = species_names, prop = target_prop, input_file = aoh_files)
# Se `run_limited_species_test` è TRUE, limita il numero di specie per test rapidi.
if (run_limited_species_test) {
  cat("\nATTENZIONE: run limitata a", n_species_test, "specie per test.\n")
  species_dt <- species_dt[seq_len(min(n_species_test, .N))]
  species_dt[, id := seq_len(.N)]
}
# Assegna ogni specie a un chunk di elaborazione basato su `chunk_size`.
species_dt[, chunk_id := ceiling(seq_len(.N) / chunk_size)]
# Stampa le impostazioni correnti per verifica.
cat("Specie totali:", nrow(species_dt), "\n")
cat("presence_rule:", presence_rule, "\n")
cat("amount_mode:", amount_mode, "\n")
cat("n_workers:", n_workers, "\n")
cat("chunk_size:", chunk_size, "\n")
# ------------------------------------------------------------
# 6. PREFLIGHT CHECK
# ------------------------------------------------------------
# Esegue un controllo preliminare su un campione di raster se `run_preflight_check` è TRUE.
if (run_preflight_check) {
  cat("\n================ PREFLIGHT CHECK ================\n")
  cat("Controllo rapido su", min(n_preflight_files, length(aoh_files)), "raster...\n")
  preflight_files <- aoh_files[seq_len(min(n_preflight_files, length(aoh_files)))]
  # Esegue `check_one_raster` su ogni file del preflight.
  preflight_dt <- rbindlist(lapply(preflight_files, check_one_raster), fill = TRUE)
  # Salva i risultati del preflight check.
  fwrite(preflight_dt, preflight_file)
  print(preflight_dt)
  cat("\nSintesi preflight:\n")
  # Riassume i risultati del preflight check.
  preflight_summary <- preflight_dt[, .(
    n_files = .N,
    files_with_non_na = sum(n_non_na > 0, na.rm = TRUE),
    files_with_gt_0 = sum(n_gt_0 > 0, na.rm = TRUE),
    files_with_zero = sum(n_eq_0 > 0, na.rm = TRUE),
    files_only_zero_non_na = sum(n_non_na > 0 & n_gt_0 == 0 & n_eq_0 > 0, na.rm = TRUE),
    files_all_na = sum(n_non_na == 0, na.rm = TRUE)
  )]
  print(preflight_summary)
  cat("\nPreflight salvato in:\n", preflight_file, "\n")
  if (presence_rule == "positive" && preflight_summary$files_with_gt_0 == 0) {
    warning(
      "ATTENZIONE: presence_rule = 'positive', ma nessun raster del preflight ha celle > 0. ",
      "Controlla i raster o valuta un'altra presence_rule."
    )
  }
  if (presence_rule == "non_na") {
    suspicious <- preflight_dt[status == "ok" & n_non_na == ncell]
    if (nrow(suspicious) > 0) {
      warning(
        "ATTENZIONE: almeno un raster del preflight ha n_non_na == ncell. ",
        "Con presence_rule = 'non_na' questo potrebbe considerare tutto il raster come AOH."
      )
    }
  }
  cat("=================================================\n")
}
# ------------------------------------------------------------
# 7. CLEAN START / SIGNATURE CHECK
# ------------------------------------------------------------
# Genera la firma dei file di input correnti.
current_signature <- make_species_signature(species_dt)
# Legge la firma della run precedente, se esiste.
old_signature <- read_species_signature(species_signature_file)
# Se `overwrite_previous_outputs` è TRUE e non stiamo riprendendo da log esistenti, pulisce gli output precedenti.
if (overwrite_previous_outputs) {
  cat("\nPulizia output precedenti...\n")
  unlink(chunk_dir, recursive = TRUE)
  unlink(log_dir, recursive = TRUE)
  dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
  # Rimuove i file di output principali.
  files_to_remove <- c(
    rij_file,
    log_file,
    planning_units_file,
    chunk_summary_file,
    species_signature_file,
    no_rij_file
  )
  invisible(lapply(files_to_remove, remove_if_exists))
  old_signature <- NULL # Resetta la vecchia firma per forzare la riscrittura.
}
# Controlla se la firma dei file di input è cambiata rispetto alla run precedente.
if (
  check_species_signature &&
    !is.null(old_signature) &&
    !identical(current_signature, old_signature)
) {
  stop(
    "La lista dei raster/specie sembra diversa da quella della run precedente.\n",
    "Per evitare di combinare chunk incompatibili, imposta overwrite_previous_outputs <- TRUE ",
    "oppure cancella manualmente i chunk/log precedenti."
  )
}
# Salva la tabella delle specie e la sua firma.
fwrite(species_dt, species_file)
write_species_signature(current_signature, species_signature_file)
cat("\nSpecies table salvata in:\n", species_file, "\n")
# ------------------------------------------------------------
# 8. CHUNKS TO RUN
# ------------------------------------------------------------
# Ottiene la lista dei chunk ID da processare.
chunk_ids <- sort(unique(species_dt$chunk_id))
done_chunks <- integer(0)
# Se `resume_from_existing_logs` è TRUE, identifica i chunk già completati dai log esistenti.
if (resume_from_existing_logs) {
  existing_logs <- list.files(
    log_dir,
    pattern = "^log_chunk_.*\\.csv$",
    full.names = FALSE
  )
  done_chunks <- as.integer(gsub("log_chunk_|\\.csv", "", existing_logs))
  done_chunks <- done_chunks[!is.na(done_chunks)]
}
# Determina quali chunk devono ancora essere eseguiti.
chunk_ids_to_run <- setdiff(chunk_ids, done_chunks)
cat("\nChunk totali:", length(chunk_ids), "\n")
cat("Chunk già completati:", length(done_chunks), "\n")
cat("Chunk da processare:", length(chunk_ids_to_run), "\n")
# ------------------------------------------------------------
# 9. PROCESS ONE SPECIES
# ------------------------------------------------------------
# Funzione principale che processa un singolo raster AOH per una specie.
process_one_aoh_worker <- function(sp_id, sp_name, f, template_info, presence_rule, amount_mode) {
  library(data.table)
  library(terra)
  t0 <- Sys.time() # Registra l'ora di inizio per misurare il tempo di esecuzione.
  # Timeout di sicurezza: se un raster .tif è parzialmente corrotto e illeggibile,
  # la libreria GDAL non si blocca per ore o giorni. Rinuncia dopo 20 minuti.
  setTimeLimit(elapsed = 1200, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE) # Assicura che il timeout venga resettato all'uscita.
  # Inizializza una riga di log per questa specie.
  log_dt <- data.table(
    species_id = as.integer(sp_id),
    species_name = sp_name,
    input_file = f,
    status = NA_character_,
    minutes = NA_real_,
    n_cells_total = NA_integer_,
    n_cells_na = NA_integer_,
    n_cells_non_na = NA_integer_,
    n_cells_gt_0 = NA_integer_,
    n_cells_eq_0 = NA_integer_,
    n_presence_cells_original = NA_integer_,
    n_global_cells = NA_integer_,
    presence_rule = presence_rule,
    amount_mode = amount_mode,
    note = NA_character_
  )
  # Carica il raster template locale per le operazioni di proiezione e cellFromXY.
  template_local <- rast(
    xmin = template_info$xmin,
    xmax = template_info$xmax,
    ymin = template_info$ymin,
    ymax = template_info$ymax,
    resolution = template_info$resolution,
    crs = template_info$crs
  )
  # Funzione helper per finalizzare la riga di log con stato, note e tempo impiegato.
  finish_log <- function(
    status_value,
    note_value = NA_character_,
    n_global_cells_value = NA_integer_
  ) {
    log_dt[, status := status_value]
    log_dt[, note := note_value]
    log_dt[, n_global_cells := n_global_cells_value]
    log_dt[, minutes := round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 4)]
    log_dt
  }
  # Controllo se il file di input esiste.
  if (!file.exists(f)) {
    log_dt <- finish_log("file_not_found")
    return(list(rij = NULL, log = log_dt))
  }
  # Tenta di leggere il raster, gestendo eventuali errori.
  r <- tryCatch(
    rast(f),
    error = function(e) e
  )
  if (inherits(r, "error")) {
    log_dt <- finish_log(
      status_value = "raster_read_error",
      note_value = conditionMessage(r)
    )
    return(list(rij = NULL, log = log_dt))
  }
  log_dt[, n_cells_total := ncell(r)]
  r_crs <- tryCatch(
    crs(r, proj = TRUE),
    error = function(e) NA_character_
  )
  if (is.na(r_crs) || r_crs == "") {
    log_dt <- finish_log(
      status_value = "missing_crs",
      note_value = "Raster senza CRS: impossibile mappare in modo affidabile."
    )
    return(list(rij = NULL, log = log_dt))
  }
  # Se CRS diverso da EPSG:4326, prova a proiettare sul template globale.
  # method = "near" perché AOH è categorico/binario.
  if (!same.crs(r, template_local)) {
    r <- tryCatch(
      project(r, template_local, method = "near"),
      error = function(e) e
    )
    if (inherits(r, "error")) {
      log_dt <- finish_log(
        status_value = "projection_error",
        note_value = conditionMessage(r)
      )
      return(list(rij = NULL, log = log_dt))
    }
  }
  # --- NUOVO CODICE (Elaborazione a Blocchi OOM-Free) ---
  # Spiegazione: Invece di chiedere alla funzione values() di
  # estrarre tutti i miliardi di celle in RAM contemporaneamente (che causava
  # i kill di sistema "Out Of Memory" o blocchi su Cgroup), istruiamo R
  # a processare la mappa sequenzialmente a fette (blocks). I risultati ecologici
  # finali e le conte AOH sono matematicamente identici all'originale.
  bs <- blocks(r) # Ottiene le informazioni sui blocchi (fette) del raster.
  block_rijs <- list() # Lista per accumulare i risultati RIJ dai singoli blocchi.
  log_n_na <- 0L
  log_n_non_na <- 0L
  log_n_gt_0 <- 0L
  log_n_eq_0 <- 0L
  log_n_presence <- 0L # Inizializza contatori per il log.
  # Se `amount_mode` è "area_km2", pre-carica il raster delle aree per efficienza.
  if (amount_mode == "area_km2") cell_area_r <- tryCatch(cellSize(r, unit = "km"), error = function(e) e)
  # Blocco tryCatch per gestire errori durante l'elaborazione a blocchi.
  process_err <- tryCatch({
    terra::readStart(r) # Inizia la lettura del raster.
    if (amount_mode == "area_km2") terra::readStart(cell_area_r) # Inizia la lettura del raster area se necessario.
    # Itera su ogni blocco del raster.
    for (b in seq_len(bs$n)) {
      vals_b <- terra::readValues(r, row = bs$row[b], nrows = bs$nrows[b], mat = FALSE) # Legge i valori del blocco corrente.
      not_na <- !is.na(vals_b) # Identifica le celle non-NA.
      # Aggiorna i contatori del log con i dati del blocco corrente.
      log_n_na <- log_n_na + sum(!not_na)
      log_n_non_na <- log_n_non_na + sum(not_na)
      log_n_gt_0 <- log_n_gt_0 + sum(not_na & vals_b > 0)
      log_n_eq_0 <- log_n_eq_0 + sum(not_na & vals_b == 0)
      # Determina le celle di presenza secondo la regola specificata.
      idx_b <- get_presence_cells(vals_b, presence_rule)
      log_n_presence <- log_n_presence + length(idx_b)
      # Se ci sono celle di presenza nel blocco:
      if (length(idx_b) > 0) {
        start_cell <- cellFromRowCol(r, bs$row[b], 1) # Calcola l'indice della prima cella del blocco.
        global_idx <- start_cell + idx_b - 1 # Converte gli indici locali in indici globali.
        xy <- xyFromCell(r, global_idx) # Ottiene le coordinate XY delle celle di presenza.
        tmpl_cells <- cellFromXY(template_local, xy) # Trova le celle corrispondenti nel template globale.
        keep <- !is.na(tmpl_cells) # Filtra le celle che cadono fuori dal template globale.
        tmpl_cells <- tmpl_cells[keep]
        # Se ci sono celle valide nel template globale:
        if (length(tmpl_cells) > 0) {
          # Calcola l'ammontare (conteggio o area) per queste celle.
          if (amount_mode == "area_km2") {
            area_vals_b <- terra::readValues(cell_area_r, row = bs$row[b], nrows = bs$nrows[b], mat = FALSE)
            dt_b <- data.table(pu = as.integer(tmpl_cells), amount_value = as.numeric(area_vals_b[idx_b[keep]]))
            dt_b <- dt_b[!is.na(amount_value) & amount_value > 0, .(amount = sum(amount_value, na.rm = TRUE)), by = pu]
            block_rijs[[length(block_rijs) + 1]] <- dt_b
          } else { # Se amount_mode è "count" o "presence"
            dt_b <- data.table(pu = as.integer(tmpl_cells))[, .(amount = .N), by = pu]
            block_rijs[[length(block_rijs) + 1]] <- dt_b
          }
        }
      }
      # Liberiamo immediatamente la RAM consumata dai dati della singola fetta per evitare accumuli.
      rm(vals_b, not_na, idx_b)
      gc(verbose = FALSE) # Forza la garbage collection.
    }
    NULL # Se tutto va bene, restituisce NULL.
  }, error = function(e) e, finally = { # Blocco `finally` per assicurare la chiusura dei file raster.
    try(terra::readStop(r), silent = TRUE)
    if (amount_mode == "area_km2") try(terra::readStop(cell_area_r), silent = TRUE)
  })
  # Se si è verificato un errore durante l'elaborazione a blocchi, registra l'errore.
  if (inherits(process_err, "error")) {
    return(finish_log("processing_error", conditionMessage(process_err)))
  }
  # Aggiorna i contatori del log con i totali calcolati dai blocchi.
  log_dt[, n_cells_na := log_n_na]
  log_dt[, n_cells_non_na := log_n_non_na]
  log_dt[, n_cells_gt_0 := log_n_gt_0]
  log_dt[, n_cells_eq_0 := log_n_eq_0]
  log_dt[, n_presence_cells_original := log_n_presence]
  # Se non ci sono celle di presenza trovate, termina con uno stato appropriato.
  if (log_n_presence == 0) {
    return(finish_log("no_presence_AOH_cells_original", n_global_cells_value = 0L))
  }
  # Aggrega i risultati RIJ dai blocchi.
  if (length(block_rijs) > 0) {
    rij_dt <- rbindlist(block_rijs)
    if (amount_mode == "presence") { # Se amount_mode è "presence", imposta amount a 1.
      rij_dt <- rij_dt[, .(amount = 1), by = pu]
    } else { # Altrimenti, somma gli ammontari (es. aree).
      rij_dt <- rij_dt[, .(amount = sum(amount)), by = pu]
    }
  } else { # Se non ci sono blocchi RIJ validi, termina con errore.
    return(finish_log("no_valid_rij_rows", n_global_cells_value = 0L))
  }
  # Imposta la colonna 'species' e riordina le colonne.
  rij_dt[, species := as.integer(sp_id)]
  setcolorder(rij_dt, c("pu", "species", "amount"))
  # Finalizza il log con stato "ok" e il numero di planning units trovate.
  log_dt <- finish_log(
    status_value = "ok",
    n_global_cells_value = uniqueN(rij_dt$pu)
  )
  rm(r) # Libera la memoria occupata dal raster.
  gc(verbose = FALSE) # Forza la garbage collection.
  list(rij = rij_dt, log = log_dt) # Restituisce i risultati RIJ e la riga di log.
}
# ------------------------------------------------------------
# 10. PROCESS ONE CHUNK
# ------------------------------------------------------------
# Funzione che processa un intero chunk di specie in parallelo.
process_chunk <- function(this_chunk_id, species_dt, template_info, tmp_root, presence_rule, amount_mode) {
  library(data.table)
  library(terra)
  # Crea una directory temporanea specifica per questo chunk e worker.
  worker_tmp <- file.path(tmp_root, paste0("chunk_", sprintf("%05d", this_chunk_id)))
  dir.create(worker_tmp, recursive = TRUE, showWarnings = FALSE)
  # --- CODICE ORIGINALE ---
  # terraOptions(memfrac = 0.25, memmax = 8, tempdir = worker_tmp, todisk = TRUE, progress = 0)
  # --- NUOVO CODICE ---
  # Spiegazione del cambiamento: Concediamo a `terra` un ottimo quantitativo di RAM (8 GB)
  # che permette ai lavoratori di estrarre e manipolare pacchetti più grandi riducendo
  # il numero di richieste ai dischi di rete (NFS). Le performance aumentano senza OOM.
  # Questo è cruciale per gestire raster di grandi dimensioni in modo efficiente.
  terraOptions(memfrac = 0.8, memmax = 8, tempdir = worker_tmp, todisk = TRUE, progress = 0)
  # Seleziona le specie appartenenti a questo chunk.
  chunk_species <- species_dt[chunk_id == this_chunk_id]
  # Se il chunk è vuoto, restituisce un risultato vuoto.
  if (nrow(chunk_species) == 0) {
    return(data.table(
      chunk_id = this_chunk_id,
      n_species = 0L,
      n_rij_rows = 0L,
      n_ok = 0L,
      n_empty = 0L,
      status = "empty_chunk",
      error = NA_character_
    ))
  }
  # Inizializza liste per raccogliere i risultati RIJ e i log da ogni specie nel chunk.
  rij_list <- vector("list", nrow(chunk_species))
  log_list <- vector("list", nrow(chunk_species))
  # Itera su ogni specie nel chunk.
  for (i in seq_len(nrow(chunk_species))) {
    sp_id <- chunk_species$id[i]
    sp_name <- chunk_species$name[i]
    f <- chunk_species$input_file[i]
    # Processa la specie, gestendo eventuali errori non catturati internamente.
    res <- tryCatch(
      process_one_aoh_worker(
        sp_id = sp_id,
        sp_name = sp_name,
        f = f,
        template_info = template_info,
        presence_rule = presence_rule,
        amount_mode = amount_mode
      ),
      error = function(e) {
        list(
          rij = NULL,
          log = data.table(
            species_id = as.integer(sp_id),
            species_name = sp_name,
            input_file = f,
            status = "species_unhandled_error",
            minutes = NA_real_,
            n_cells_total = NA_integer_,
            n_cells_na = NA_integer_,
            n_cells_non_na = NA_integer_,
            n_cells_gt_0 = NA_integer_,
            n_cells_eq_0 = NA_integer_,
            n_presence_cells_original = NA_integer_,
            n_global_cells = NA_integer_,
            presence_rule = presence_rule,
            amount_mode = amount_mode,
            note = conditionMessage(e)
          )
        )
      }
    )
    rij_list[[i]] <- res$rij
    log_list[[i]] <- res$log
    rm(res) # Libera memoria.
    # Esegue garbage collection periodicamente per evitare accumuli di memoria.
    if (i %% 10 == 0) {
      terra::tmpFiles(remove = TRUE)
      gc(verbose = FALSE)
    }
  }
  # Aggrega i risultati RIJ e i log dal chunk.
  rij_chunk <- rbindlist(rij_list, fill = TRUE)
  log_chunk <- rbindlist(log_list, fill = TRUE)
  # Definisce i nomi dei file di output per questo chunk.
  rij_out <- safe_chunk_file(this_chunk_id)
  log_out <- safe_log_file(this_chunk_id)
  # Salva il file RIJ del chunk se contiene dati.
  if (nrow(rij_chunk) > 0) {
    rij_chunk[, pu := as.integer(pu)]
    rij_chunk[, species := as.integer(species)]
    rij_chunk[, amount := as.numeric(amount)]
    # Filtra righe non valide prima di salvare.
    rij_chunk <- rij_chunk[
      !is.na(pu) & !is.na(species) & !is.na(amount) & amount > 0
    ]
    safe_fwrite(rij_chunk, rij_out)
  } else { # Altrimenti, salva un file vuoto per coerenza.
    safe_fwrite(
      data.table(pu = integer(), species = integer(), amount = numeric()),
      rij_out
    )
  }
  # Salva il file di log del chunk.
  safe_fwrite(log_chunk, log_out)
  # Pulisce la directory temporanea specifica del worker per questo chunk.
  unlink(worker_tmp, recursive = TRUE, force = TRUE)
  # Restituisce un riepilogo dell'elaborazione del chunk.
  data.table(
    chunk_id = this_chunk_id,
    n_species = nrow(chunk_species),
    n_rij_rows = nrow(rij_chunk),
    n_ok = sum(log_chunk$status == "ok", na.rm = TRUE),
    n_empty = sum(log_chunk$status == "no_presence_AOH_cells_original", na.rm = TRUE),
    status = "ok",
    error = NA_character_
  )
}
# ------------------------------------------------------------
# 11. RUN PARALLEL
# ------------------------------------------------------------
cat("\n================ PARALLEL AOH DIRECT MAPPING START ================\n")
# Esegue `process_chunk` in parallelo per tutti i chunk da processare.
if (length(chunk_ids_to_run) > 0) {
  res_chunks_raw <- mclapply(
    chunk_ids_to_run,
    FUN = function(cid) {
      tryCatch(
        process_chunk(
          this_chunk_id = cid,
          species_dt = species_dt,
          template_info = template_info,
          tmp_root = tmp_root,
          presence_rule = presence_rule,
          amount_mode = amount_mode
        ),
        error = function(e) {
          data.table(
            chunk_id = cid,
            n_species = NA_integer_,
            n_rij_rows = NA_integer_,
            n_ok = NA_integer_,
            n_empty = NA_integer_,
            status = "chunk_unhandled_error",
            error = conditionMessage(e)
          )
        }
      )
    },
    mc.cores = n_workers, mc.preschedule = FALSE # `mc.preschedule = FALSE` per una migliore gestione delle risorse.
  )
  # Gestisce potenziali errori o uccisioni di processi worker da parte del sistema operativo.
  res_chunks_list <- lapply(res_chunks_raw, function(x) {
    if (is.data.table(x)) {
      return(x)
    }
    return(data.table(chunk_id = NA_integer_, status = "worker_killed_by_os", error = as.character(x[[1]])))
  })
  res_chunks <- rbindlist(res_chunks_list, fill = TRUE)
  cat("\nChunk completati in questa run:\n")
  print(res_chunks)
  # Aggiorna il file di riepilogo dei chunk, combinando i risultati della run corrente con quelli precedenti.
  if (file.exists(chunk_summary_file)) {
    old_summary <- fread(chunk_summary_file)
    summary_dt <- rbindlist(list(old_summary, res_chunks), fill = TRUE)
    summary_dt <- unique(summary_dt, by = "chunk_id", fromLast = TRUE) # Mantiene solo l'ultima entry per chunk ID.
  } else {
    summary_dt <- res_chunks
  }
  safe_fwrite(summary_dt, chunk_summary_file)
} else {
  cat("Tutti i chunk risultano già completati.\n")
}
cat("\n================ PARALLEL AOH DIRECT MAPPING END ================\n")
# ------------------------------------------------------------
# 12. COMBINE LOGS
# ------------------------------------------------------------
cat("\nCombino log...\n")
# Trova tutti i file di log dei chunk.
log_files <- list.files(
  log_dir,
  pattern = "^log_chunk_.*\\.csv$",
  full.names = TRUE
)
if (length(log_files) == 0) {
  stop("Nessun log chunk trovato.")
}
# Legge e aggrega tutti i log in un unico data.table.
log_dt <- rbindlist(lapply(log_files, fread), fill = TRUE)
setorder(log_dt, species_id) # Ordina per ID specie.
log_dt <- unique(log_dt, by = "species_id", fromLast = TRUE) # Mantiene solo l'ultima entry per specie ID.
safe_fwrite(log_dt, log_file) # Salva il log aggregato.
cat("\nLog summary:\n")
print(log_dt[, .N, by = status][order(-N)]) # Mostra un riepilogo degli stati di completamento.
missing_log_species <- setdiff(species_dt$id, log_dt$species_id)
if (length(missing_log_species) > 0) {
  warning(
    "Alcune specie non sono presenti nel log finale. Numero specie mancanti: ",
    length(missing_log_species)
  )
}
# ------------------------------------------------------------
# 13. COMBINE RIJ CHUNKS
# ------------------------------------------------------------
cat("\nCombino RIJ chunks...\n")
rij_files <- list.files(
  chunk_dir,
  pattern = "^rij_chunk_.*\\.csv$",
  full.names = TRUE
)
if (length(rij_files) == 0) {
  stop("Nessun RIJ chunk trovato.")
}
# --- CODICE ORIGINALE ---
# rij_final <- rbindlist(lapply(rij_files, fread), fill = TRUE)
# --- NUOVO CODICE ---
# Spiegazione del cambiamento: L'unione (rbindlist) di 30.000 CSV tutti insieme
# costringe il server a caricare l'intera e mastodontica matrice RIJ in RAM.
# Per non rischiare il fallimento all'ultima operazione, i file vengono ora
# caricati, accorpati e scaricati a piccoli "lotti" (batch_size).
# Questo evita problemi di memoria durante l'aggregazione finale dei risultati.
batch_size <- 500 # Definisce la dimensione del lotto per l'unione.
if (file.exists(rij_file)) file.remove(rij_file) # Rimuove il file RIJ finale se esiste già.
all_species_in_rij <- integer() # Inizializza un vettore per tenere traccia delle specie presenti nel RIJ finale.
# Itera sui file RIJ in lotti.
for (i in seq(1, length(rij_files), by = batch_size)) {
  # Legge un lotto di file CSV.
  batch_dt <- rbindlist(lapply(rij_files[i:min(i + batch_size - 1, length(rij_files))], fread), fill = TRUE)
  if (nrow(batch_dt) > 0) {
    # Aggrega i dati all'interno del lotto e filtra righe non valide.
    batch_dt <- batch_dt[!is.na(pu) & amount > 0, .(amount = sum(amount, na.rm = TRUE)), by = .(pu, species)]
    setorder(batch_dt, species, pu) # Ordina per specie e PU.
    all_species_in_rij <- unique(c(all_species_in_rij, unique(batch_dt$species))) # Aggiorna la lista delle specie processate.
    safe_fwrite(batch_dt, rij_file, append = TRUE) # Salva il lotto aggregato nel file RIJ finale (in append).
  }
  rm(batch_dt) # Libera memoria.
  gc(verbose = FALSE) # Forza la garbage collection tra i lotti.
}
# Controllo finale se il file RIJ finale è stato creato e non è vuoto.
if (!file.exists(rij_file) || file.info(rij_file)$size == 0) {
  cat("\nATTENZIONE: i file RIJ chunk esistono, ma sono tutti vuoti.\n")
  cat("Controllo il log per capire il motivo...\n")
  # Mostra le righe problematiche dal log per diagnosi.
  diagnostic_cols <- intersect(
    c(
      "species_id",
      "species_name",
      "status",
      "n_cells_total",
      "n_cells_na",
      "n_cells_non_na",
      "n_cells_gt_0",
      "n_cells_eq_0",
      "presence_rule",
      "amount_mode",
      "note"
    ),
    names(log_dt)
  )
  print(log_dt[status != "ok"][1:20, ..diagnostic_cols])
  stop("Nessuna riga RIJ prodotta. Vedi status summary sopra.")
}
# Identifica le specie che non hanno prodotto righe RIJ.
species_without_rij <- setdiff(species_dt$id, all_species_in_rij)
cat("Specie senza righe RIJ:", length(species_without_rij), "\n")
if (length(species_without_rij) > 0) safe_fwrite(species_dt[id %in% species_without_rij], no_rij_file) # Salva la lista di queste specie.
# ------------------------------------------------------------
# 14. PLANNING UNITS
# ------------------------------------------------------------
cat("\nCreo planning units...\n")
# --- CODICE ORIGINALE ---
# pu_ids <- sort(unique(rij_final$pu))
# --- NUOVO CODICE ---
# Spiegazione del cambiamento: Siccome la tabella matrice rij_final non vive
# più integralmente in RAM, ne leggiamo in un baleno solo la primissima
# colonna (ID) direttamente dal file su disco tramite `fread`. Questo è un'ottimizzazione
# per evitare di caricare l'intero file RIJ finale solo per ottenere gli ID delle PU.
pu_ids <- sort(unique(fread(rij_file, select = 1L)[[1]])) # Legge solo la prima colonna (pu) dal file RIJ finale.
xy_pu <- xyFromCell(template, pu_ids) # Ottiene le coordinate XY per ogni ID di PU.
# Crea la tabella delle planning units con ID, coordinate, area e costo.
pu_dt <- data.table(
  id = as.integer(pu_ids),
  x = xy_pu[, 1],
  y = xy_pu[, 2],
  cost_area_km2 = as.numeric(area_values[pu_ids]),
  cost_constant = 1
)
# Default: costo proporzionale all'area della planning unit.
pu_dt[, cost := cost_area_km2]
pu_dt[is.na(cost), cost := median(pu_dt$cost, na.rm = TRUE)]
safe_fwrite(pu_dt, planning_units_file) # Salva la tabella delle planning units.
# ------------------------------------------------------------
# 15. SYNC FINALE
# ------------------------------------------------------------
cat("\nTrasferimento sicuro su /nfs in corso...\n")
# Copia tutti i file di output finali dalla directory scratch locale (/Rtmp) alla directory NFS finale.
file.copy(species_file, file.path(final_out_dir, basename(species_file)), overwrite = TRUE)
file.copy(rij_file, file.path(final_out_dir, basename(rij_file)), overwrite = TRUE)
file.copy(log_file, file.path(final_out_dir, basename(log_file)), overwrite = TRUE)
file.copy(planning_units_file, file.path(final_out_dir, basename(planning_units_file)), overwrite = TRUE)
file.copy(chunk_summary_file, file.path(final_out_dir, basename(chunk_summary_file)), overwrite = TRUE)
file.copy(species_signature_file, file.path(final_out_dir, basename(species_signature_file)), overwrite = TRUE)
# Copia anche i file opzionali se esistono.
if (file.exists(preflight_file)) file.copy(preflight_file, file.path(final_out_dir, basename(preflight_file)), overwrite = TRUE)
if (file.exists(no_rij_file)) file.copy(no_rij_file, file.path(final_out_dir, basename(no_rij_file)), overwrite = TRUE)
# ------------------------------------------------------------
# 16. FINAL SUMMARY
# ------------------------------------------------------------
# Messaggio finale di completamento con i percorsi dei file generati.
cat("\n================ COMPLETATO CON SUCCESSO ================\n")
cat("Species table:\n", file.path(final_out_dir, basename(species_file)), "\n")
cat("RIJ:\n", file.path(final_out_dir, basename(rij_file)), "\n")
cat("Planning units:\n", file.path(final_out_dir, basename(planning_units_file)), "\n")
cat("Log:\n", file.path(final_out_dir, basename(log_file)), "\n")
cat("Chunk summary:\n", file.path(final_out_dir, basename(chunk_summary_file)), "\n")
