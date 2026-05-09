# ============================================================
# BLOCK 1 OPTIMIZED - AOH TO RIJ FOR PRIORITIZR
# VERSIONE COMPLETA AGGIORNATA DOPO PREFLIGHT
# ============================================================
#
# Obiettivo:
#   Costruire una tabella RIJ per prioritizr a partire dai raster AOH
#   delle orchidee, aggregando le celle AOH positive su una griglia globale
#   a 30 arc-min, in parallelo e per chunk.
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
# Caratteristiche:
#   - processa i raster AOH in parallelo per chunk
#   - salva un file RIJ per chunk
#   - salva un log per chunk
#   - evita append continui su un unico CSV enorme
#   - include un preflight check sui primi raster
#   - include gestione errori a livello di specie e chunk
#   - riparte da zero cancellando i vecchi output incompatibili
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
# ============================================================

library(data.table)
library(terra)
library(parallel)

options(scipen = 999)

# ============================================================
# SAFEGUARDS — solo variabili d'ambiente, nessun cambio di logica
# ------------------------------------------------------------
# Queste variabili vengono ereditate dai processi figli di mclapply()
# tramite fork. Non toccano lo script: se le commenti tutte,
# il comportamento torna identico all'originale.
#
# Formato: per ogni impostazione c'è prima la riga commentata con
# il valore "PRIMA" (default o ereditato), poi la riga attiva "DOPO".
# ============================================================

# ---- BLAS / OpenMP ----------------------------------------------------
# Con n_workers alti (es. 30 fork di mclapply), ogni worker eredita i
# thread BLAS del padre. 30 worker * N thread = contention pesante su CPU.
# Per raster AOH + project(method="near") il BLAS multi-thread NON serve:
# meglio 1 thread per worker, che dà throughput migliore e niente thrashing.
#
# PRIMA (ereditato, può essere vuoto = unlimited):
#   Sys.getenv("OPENBLAS_NUM_THREADS")
#   Sys.getenv("OMP_NUM_THREADS")
#   Sys.getenv("MKL_NUM_THREADS")
# DOPO:
# Sys.setenv(OPENBLAS_NUM_THREADS = "1")
# Sys.setenv(OMP_NUM_THREADS = "1")
# Sys.setenv(MKL_NUM_THREADS = "1")

# ---- GDAL (lettura raster AOH via terra) -----------------------------
# I raster AOH stanno su NFS (biome-store03:/mnt/zpool/home via nfs4.2,
# rsize=wsize=1M, nconnect=4). GDAL per default può aprire molti thread
# interni e allocare cache ~5% RAM *per worker*: con 30 worker può esplodere.
#
# PRIMA: non impostato (default GDAL, ogni worker = molti thread + molta cache).
# DOPO: 1 thread GDAL per worker, cache contenuta a 256 MB/worker,
#       VSI cache abilitato (utile per NFS).
# Sys.setenv(GDAL_NUM_THREADS = "1")
# Sys.setenv(GDAL_CACHEMAX = "256")
# Sys.setenv(VSI_CACHE = "TRUE")
# Sys.setenv(VSI_CACHE_SIZE = "67108864") # 64 MB
# Sys.setenv(CPL_VSIL_CURL_CACHE_SIZE = "67108864") # 64 MB

# ---- TMPDIR -> /Rtmp (disco ext4 locale dedicato, 400 GB) -------------
# /Rtmp è un disco locale per VM (NON tmpfs, NON NFS). terra / GDAL
# ci scrivono intermediate: tenerli sul disco locale evita round-trip NFS.
# Lo script usa comunque tmp_root su NFS per `worker_tmp` (compatibilità),
# ma i tempfile() nascosti di R/terra/GDAL andranno su /Rtmp.
#
# PRIMA: TMPDIR = /tmp (systemd potrebbe pulire) oppure non settato.
# DOPO:  TMPDIR = /Rtmp se disponibile e scrivibile.
# if (dir.exists("/Rtmp") && file.access("/Rtmp", mode = 2L) == 0L) {
#  Sys.setenv(TMPDIR = "/Rtmp")
#  Sys.setenv(TMP = "/Rtmp")
#  Sys.setenv(TEMP = "/Rtmp")
# }

# ============================================================
# FINE SAFEGUARDS — da qui lo script è identico all'originale.
# ============================================================

# ------------------------------------------------------------
# 1. PATHS
# ------------------------------------------------------------

base_dir <- "/nfs/home/gianfranco.samuele2/test_Michele/rabinowitz/Area of Habitat"
aoh_dir <- file.path(base_dir, "AOH_orchids")

out_dir <- file.path(base_dir, "prioritizr_all_species_30arcmin")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

chunk_dir <- file.path(out_dir, "rij_chunks")
log_dir <- file.path(out_dir, "rij_chunk_logs")

dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)

species_file <- file.path(out_dir, "species_table_all.csv")
rij_file <- file.path(out_dir, "rij_species_cell_30arcmin_AOH_direct_all.csv")
log_file <- file.path(out_dir, "AOH_direct_mapping_log_all.csv")
planning_units_file <- file.path(out_dir, "planning_units_30arcmin_all.csv")
chunk_summary_file <- file.path(out_dir, "chunk_processing_summary_all.csv")
species_signature_file <- file.path(out_dir, "species_table_signature.txt")
no_rij_file <- file.path(out_dir, "species_without_rij_rows.csv")
preflight_file <- file.path(out_dir, "AOH_preflight_check_first_rasters.csv")

# Cartella temporanea per terra
tmp_root <- file.path(base_dir, "terra_tmp_prioritizr_all_parallel")
dir.create(tmp_root, recursive = TRUE, showWarnings = FALSE)

# ------------------------------------------------------------
# 2. SETTINGS
# ------------------------------------------------------------

target_res <- 0.5
target_prop <- 0.05

# Run completa: prudente ma più veloce del test.
# n_workers <- 1L
# chunk_size <- 1L

n_workers <- 10L
chunk_size <- 5L
# TRUE = cancella i vecchi chunk/log/output e rifà tutto.
overwrite_previous_outputs <- TRUE

# FALSE = non considera vecchi log come chunk già completati.
resume_from_existing_logs <- FALSE

# Regola per identificare le celle AOH.
presence_rule <- "positive"

# Modalità di calcolo di amount.
amount_mode <- "count"

# Controllo iniziale su alcuni raster.
run_preflight_check <- TRUE
n_preflight_files <- 10L

# Run completa su tutte le specie.
run_limited_species_test <- FALSE
# n_species_test <- 500L
n_species_test <- 23000L

# Disattivato perché abbiamo fatto test limitati e run diverse.
check_species_signature <- FALSE
# ------------------------------------------------------------
# 3. TEMPLATE 30 ARC-MIN
# ------------------------------------------------------------

template <- rast(
  xmin = -180, xmax = 180,
  ymin = -90, ymax = 90,
  resolution = target_res,
  crs = "EPSG:4326"
)

area_r <- cellSize(template, unit = "km")
area_values <- values(area_r, mat = FALSE)

template_info <- list(
  xmin = -180,
  xmax = 180,
  ymin = -90,
  ymax = 90,
  resolution = target_res,
  crs = "EPSG:4326"
)

# ------------------------------------------------------------
# 4. HELPER FUNCTIONS
# ------------------------------------------------------------

clean_species <- function(x) {
  x <- gsub("\\.tif$", "", x, ignore.case = TRUE)
  x <- gsub("_+", " ", x)
  x <- gsub("\\s+", " ", x)
  trimws(enc2utf8(x))
}

safe_chunk_file <- function(chunk_id) {
  file.path(chunk_dir, sprintf("rij_chunk_%05d.csv", chunk_id))
}

safe_log_file <- function(chunk_id) {
  file.path(log_dir, sprintf("log_chunk_%05d.csv", chunk_id))
}

make_species_signature <- function(dt) {
  sig_dt <- copy(dt)
  sig_dt[, file_basename := basename(input_file)]
  sig_dt[, file_size := file.info(input_file)$size]
  sig_dt[, file_mtime := as.character(file.info(input_file)$mtime)]
  sig_dt <- sig_dt[, .(id, name, file_basename, file_size, file_mtime)]
  paste(capture.output(print(sig_dt)), collapse = "\n")
}

write_species_signature <- function(signature, signature_file) {
  writeLines(signature, signature_file, useBytes = TRUE)
}

read_species_signature <- function(signature_file) {
  if (!file.exists(signature_file)) {
    return(NULL)
  }
  paste(readLines(signature_file, warn = FALSE), collapse = "\n")
}

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

check_one_raster <- function(f) {
  r <- tryCatch(rast(f), error = function(e) e)

  if (inherits(r, "error")) {
    return(data.table(
      file = basename(f),
      status = "raster_read_error",
      ncell = NA_integer_,
      n_na = NA_integer_,
      n_non_na = NA_integer_,
      n_gt_0 = NA_integer_,
      n_eq_0 = NA_integer_,
      min_value = NA_real_,
      max_value = NA_real_,
      unique_values_head = NA_character_,
      xmin = NA_real_,
      xmax = NA_real_,
      ymin = NA_real_,
      ymax = NA_real_,
      crs = NA_character_,
      note = conditionMessage(r)
    ))
  }

  vals <- tryCatch(values(r, mat = FALSE), error = function(e) NULL)

  if (is.null(vals)) {
    return(data.table(
      file = basename(f),
      status = "values_read_error",
      ncell = ncell(r),
      n_na = NA_integer_,
      n_non_na = NA_integer_,
      n_gt_0 = NA_integer_,
      n_eq_0 = NA_integer_,
      min_value = NA_real_,
      max_value = NA_real_,
      unique_values_head = NA_character_,
      xmin = ext(r)$xmin,
      xmax = ext(r)$xmax,
      ymin = ext(r)$ymin,
      ymax = ext(r)$ymax,
      crs = crs(r),
      note = NA_character_
    ))
  }

  non_na_vals <- vals[!is.na(vals)]

  data.table(
    file = basename(f),
    status = "ok",
    ncell = ncell(r),
    n_na = sum(is.na(vals)),
    n_non_na = length(non_na_vals),
    n_gt_0 = sum(non_na_vals > 0),
    n_eq_0 = sum(non_na_vals == 0),
    min_value = if (length(non_na_vals) > 0) min(non_na_vals) else NA_real_,
    max_value = if (length(non_na_vals) > 0) max(non_na_vals) else NA_real_,
    unique_values_head = if (length(non_na_vals) > 0) {
      paste(head(sort(unique(non_na_vals)), 10), collapse = ", ")
    } else {
      NA_character_
    },
    xmin = ext(r)$xmin,
    xmax = ext(r)$xmax,
    ymin = ext(r)$ymin,
    ymax = ext(r)$ymax,
    crs = crs(r),
    note = NA_character_
  )
}

remove_if_exists <- function(f) {
  if (file.exists(f)) {
    file.remove(f)
  } else {
    FALSE
  }
}

# ------------------------------------------------------------
# 5. LIST AOH RASTERS
# ------------------------------------------------------------

if (!dir.exists(aoh_dir)) {
  stop("AOH directory non trovata: ", aoh_dir)
}

aoh_files <- sort(list.files(
  aoh_dir,
  pattern = "\\.tif$",
  full.names = TRUE,
  recursive = FALSE,
  ignore.case = TRUE
))

if (length(aoh_files) == 0) {
  stop("Nessun raster .tif trovato in: ", aoh_dir)
}

cat("\nRaster AOH trovati:", length(aoh_files), "\n")

species_names <- clean_species(basename(aoh_files))

species_dt <- data.table(
  id = seq_along(aoh_files),
  name = species_names,
  prop = target_prop,
  input_file = aoh_files
)

if (run_limited_species_test) {
  cat("\nATTENZIONE: run limitata a", n_species_test, "specie per test.\n")
  species_dt <- species_dt[seq_len(min(n_species_test, .N))]
  species_dt[, id := seq_len(.N)]
}

species_dt[, chunk_id := ceiling(seq_len(.N) / chunk_size)]

cat("Specie totali:", nrow(species_dt), "\n")
cat("presence_rule:", presence_rule, "\n")
cat("amount_mode:", amount_mode, "\n")
cat("n_workers:", n_workers, "\n")
cat("chunk_size:", chunk_size, "\n")

# ------------------------------------------------------------
# 6. PREFLIGHT CHECK
# ------------------------------------------------------------

if (run_preflight_check) {
  cat("\n================ PREFLIGHT CHECK ================\n")
  cat("Controllo rapido su", min(n_preflight_files, length(aoh_files)), "raster...\n")

  preflight_files <- aoh_files[seq_len(min(n_preflight_files, length(aoh_files)))]
  preflight_dt <- rbindlist(lapply(preflight_files, check_one_raster), fill = TRUE)

  fwrite(preflight_dt, preflight_file)

  print(preflight_dt)

  cat("\nSintesi preflight:\n")
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

current_signature <- make_species_signature(species_dt)
old_signature <- read_species_signature(species_signature_file)

if (overwrite_previous_outputs) {
  cat("\nPulizia output precedenti...\n")

  unlink(chunk_dir, recursive = TRUE)
  unlink(log_dir, recursive = TRUE)

  dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)

  files_to_remove <- c(
    rij_file,
    log_file,
    planning_units_file,
    chunk_summary_file,
    species_signature_file,
    no_rij_file
  )

  invisible(lapply(files_to_remove, remove_if_exists))

  old_signature <- NULL
}

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

fwrite(species_dt, species_file)
write_species_signature(current_signature, species_signature_file)

cat("\nSpecies table salvata in:\n", species_file, "\n")

# ------------------------------------------------------------
# 8. CHUNKS TO RUN
# ------------------------------------------------------------

chunk_ids <- sort(unique(species_dt$chunk_id))

done_chunks <- integer(0)

if (resume_from_existing_logs) {
  existing_logs <- list.files(
    log_dir,
    pattern = "^log_chunk_.*\\.csv$",
    full.names = FALSE
  )

  done_chunks <- as.integer(gsub("log_chunk_|\\.csv", "", existing_logs))
  done_chunks <- done_chunks[!is.na(done_chunks)]
}

chunk_ids_to_run <- setdiff(chunk_ids, done_chunks)

cat("\nChunk totali:", length(chunk_ids), "\n")
cat("Chunk già completati:", length(done_chunks), "\n")
cat("Chunk da processare:", length(chunk_ids_to_run), "\n")

# ------------------------------------------------------------
# 9. PROCESS ONE SPECIES
# ------------------------------------------------------------

# ------------------------------------------------------------
# 9. PROCESS ONE SPECIES
# ------------------------------------------------------------

process_one_aoh_worker <- function(sp_id, sp_name, f, template_info, presence_rule, amount_mode) {
  library(data.table)
  library(terra)

  t0 <- Sys.time()

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

  template_local <- rast(
    xmin = template_info$xmin,
    xmax = template_info$xmax,
    ymin = template_info$ymin,
    ymax = template_info$ymax,
    resolution = template_info$resolution,
    crs = template_info$crs
  )

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

  if (!file.exists(f)) {
    log_dt <- finish_log("file_not_found")
    return(list(rij = NULL, log = log_dt))
  }

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

  vals <- tryCatch(
    values(r, mat = FALSE),
    error = function(e) NULL
  )

  if (is.null(vals)) {
    log_dt <- finish_log("values_read_error")
    return(list(rij = NULL, log = log_dt))
  }

  non_na_vals <- vals[!is.na(vals)]

  log_dt[, n_cells_na := sum(is.na(vals))]
  log_dt[, n_cells_non_na := length(non_na_vals)]
  log_dt[, n_cells_gt_0 := sum(non_na_vals > 0)]
  log_dt[, n_cells_eq_0 := sum(non_na_vals == 0)]

  presence_cells <- tryCatch(
    get_presence_cells(vals, presence_rule),
    error = function(e) e
  )

  if (inherits(presence_cells, "error")) {
    log_dt <- finish_log(
      status_value = "presence_rule_error",
      note_value = conditionMessage(presence_cells)
    )
    return(list(rij = NULL, log = log_dt))
  }

  log_dt[, n_presence_cells_original := length(presence_cells)]

  if (length(presence_cells) == 0) {
    log_dt <- finish_log(
      status_value = "no_presence_AOH_cells_original",
      n_global_cells_value = 0L
    )
    return(list(rij = NULL, log = log_dt))
  }

  xy <- tryCatch(
    xyFromCell(r, presence_cells),
    error = function(e) NULL
  )

  if (is.null(xy)) {
    log_dt <- finish_log("xy_extraction_error")
    return(list(rij = NULL, log = log_dt))
  }

  global_cells <- cellFromXY(template_local, xy)
  keep <- !is.na(global_cells)

  global_cells <- global_cells[keep]
  presence_cells_kept <- presence_cells[keep]

  if (length(global_cells) == 0) {
    log_dt <- finish_log(
      status_value = "presence_cells_outside_template",
      n_global_cells_value = 0L
    )
    return(list(rij = NULL, log = log_dt))
  }

  if (amount_mode == "count") {
    rij_dt <- data.table(
      pu = as.integer(global_cells)
    )[, .(
      amount = as.numeric(.N)
    ), by = pu]
  } else if (amount_mode == "presence") {
    rij_dt <- data.table(
      pu = as.integer(global_cells)
    )[, .(
      amount = 1
    ), by = pu]
  } else if (amount_mode == "area_km2") {
    cell_area_r <- tryCatch(
      cellSize(r, unit = "km"),
      error = function(e) e
    )

    if (inherits(cell_area_r, "error")) {
      log_dt <- finish_log(
        status_value = "cell_area_error",
        note_value = conditionMessage(cell_area_r)
      )
      return(list(rij = NULL, log = log_dt))
    }

    area_vals <- tryCatch(
      values(cell_area_r, mat = FALSE),
      error = function(e) NULL
    )

    if (is.null(area_vals)) {
      log_dt <- finish_log("cell_area_values_error")
      return(list(rij = NULL, log = log_dt))
    }

    amount_values <- area_vals[presence_cells_kept]

    rij_dt <- data.table(
      pu = as.integer(global_cells),
      amount_value = as.numeric(amount_values)
    )[
      !is.na(amount_value) & amount_value > 0,
      .(amount = sum(amount_value, na.rm = TRUE)),
      by = pu
    ]
  } else {
    log_dt <- finish_log(
      status_value = "invalid_amount_mode",
      note_value = paste0("amount_mode non valido: ", amount_mode)
    )
    return(list(rij = NULL, log = log_dt))
  }

  if (nrow(rij_dt) == 0) {
    log_dt <- finish_log(
      status_value = "no_valid_rij_rows",
      n_global_cells_value = uniqueN(global_cells)
    )
    return(list(rij = NULL, log = log_dt))
  }

  rij_dt[, species := as.integer(sp_id)]
  setcolorder(rij_dt, c("pu", "species", "amount"))

  log_dt <- finish_log(
    status_value = "ok",
    n_global_cells_value = uniqueN(global_cells)
  )

  rm(r, vals, non_na_vals, presence_cells, xy, global_cells, presence_cells_kept)
  gc(verbose = FALSE)

  list(rij = rij_dt, log = log_dt)
}

# ------------------------------------------------------------
# 10. PROCESS ONE CHUNK
# ------------------------------------------------------------

process_chunk <- function(this_chunk_id, species_dt, template_info, tmp_root, presence_rule, amount_mode) {
  library(data.table)
  library(terra)

  worker_tmp <- file.path(tmp_root, paste0("chunk_", sprintf("%05d", this_chunk_id)))
  dir.create(worker_tmp, recursive = TRUE, showWarnings = FALSE)

  terraOptions(
    memfrac = 0.25,
    memmax = 8,
    tempdir = worker_tmp,
    todisk = TRUE,
    progress = 0
  )

  chunk_species <- species_dt[chunk_id == this_chunk_id]

  # --- progress: 1 riga a inizio chunk (commentabile per tornare al comportamento originale) ---
  cat(sprintf(
    "[%s] [pid=%d] chunk %05d START  species=%d\n",
    format(Sys.time(), "%H:%M:%S"), Sys.getpid(),
    this_chunk_id, nrow(chunk_species)
  ))
  flush.console()

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

  rij_list <- vector("list", nrow(chunk_species))
  log_list <- vector("list", nrow(chunk_species))

  for (i in seq_len(nrow(chunk_species))) {
    sp_id <- chunk_species$id[i]
    sp_name <- chunk_species$name[i]
    f <- chunk_species$input_file[i]

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

    rm(res)

    if (i %% 10 == 0) {
      terra::tmpFiles(remove = TRUE)
      gc(verbose = FALSE)
    }
  }

  rij_chunk <- rbindlist(rij_list, fill = TRUE)
  log_chunk <- rbindlist(log_list, fill = TRUE)

  rij_out <- safe_chunk_file(this_chunk_id)
  log_out <- safe_log_file(this_chunk_id)

  if (nrow(rij_chunk) > 0) {
    rij_chunk[, pu := as.integer(pu)]
    rij_chunk[, species := as.integer(species)]
    rij_chunk[, amount := as.numeric(amount)]

    rij_chunk <- rij_chunk[
      !is.na(pu) & !is.na(species) & !is.na(amount) & amount > 0
    ]

    fwrite(rij_chunk, rij_out)
  } else {
    fwrite(
      data.table(pu = integer(), species = integer(), amount = numeric()),
      rij_out
    )
  }

  fwrite(log_chunk, log_out)

  terra::tmpFiles(remove = TRUE)
  gc(verbose = FALSE)

  # --- progress: 1 riga a fine chunk (commentabile per tornare al comportamento originale) ---
  cat(sprintf(
    "[%s] [pid=%d] chunk %05d DONE   species=%d  rij_rows=%d  ok=%d  empty=%d\n",
    format(Sys.time(), "%H:%M:%S"), Sys.getpid(),
    this_chunk_id, nrow(chunk_species), nrow(rij_chunk),
    sum(log_chunk$status == "ok", na.rm = TRUE),
    sum(log_chunk$status == "no_presence_AOH_cells_original", na.rm = TRUE)
  ))
  flush.console()

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

if (length(chunk_ids_to_run) > 0) {
  res_chunks <- mclapply(
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
    mc.cores = n_workers,
    mc.preschedule = FALSE
  )

  res_chunks <- rbindlist(res_chunks, fill = TRUE)

  cat("\nChunk completati in questa run:\n")
  print(res_chunks)

  if (file.exists(chunk_summary_file)) {
    old_summary <- fread(chunk_summary_file)
    summary_dt <- rbindlist(list(old_summary, res_chunks), fill = TRUE)
    summary_dt <- unique(summary_dt, by = "chunk_id", fromLast = TRUE)
  } else {
    summary_dt <- res_chunks
  }

  fwrite(summary_dt, chunk_summary_file)
} else {
  cat("Tutti i chunk risultano già completati.\n")
}

cat("\n================ PARALLEL AOH DIRECT MAPPING END ================\n")

# ------------------------------------------------------------
# 12. COMBINE LOGS
# ------------------------------------------------------------

cat("\nCombino log...\n")

log_files <- list.files(
  log_dir,
  pattern = "^log_chunk_.*\\.csv$",
  full.names = TRUE
)

if (length(log_files) == 0) {
  stop("Nessun log chunk trovato.")
}

log_dt <- rbindlist(lapply(log_files, fread), fill = TRUE)
setorder(log_dt, species_id)
log_dt <- unique(log_dt, by = "species_id", fromLast = TRUE)

fwrite(log_dt, log_file)

cat("\nLog summary:\n")
print(log_dt[, .N, by = status][order(-N)])

cat("\nSpecie totali nella species table:", nrow(species_dt), "\n")
cat("Specie totali nel log:", uniqueN(log_dt$species_id), "\n")

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

rij_final <- rbindlist(
  lapply(rij_files, fread),
  fill = TRUE
)

if (nrow(rij_final) == 0) {
  cat("\nATTENZIONE: i file RIJ chunk esistono, ma sono tutti vuoti.\n")
  cat("Controllo il log per capire il motivo...\n")

  cat("\nStatus summary:\n")
  print(log_dt[, .N, by = status][order(-N)])

  cat("\nPrime righe problematiche:\n")

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
      "n_positive_cells_original",
      "n_presence_cells_original",
      "n_global_cells",
      "presence_rule",
      "amount_mode",
      "note"
    ),
    names(log_dt)
  )

  print(log_dt[status != "ok"][1:20, ..diagnostic_cols])

  stop("Nessuna riga RIJ prodotta. Vedi status summary sopra.")
}

rij_final[, pu := as.integer(pu)]
rij_final[, species := as.integer(species)]
rij_final[, amount := as.numeric(amount)]

rij_final <- rij_final[
  !is.na(pu) &
    !is.na(species) &
    !is.na(amount) &
    amount > 0
]

if (nrow(rij_final) == 0) {
  stop("RIJ finale vuoto dopo il filtro amount > 0. Controlla amount_mode e presence_rule.")
}

rij_final <- rij_final[, .(
  amount = sum(amount, na.rm = TRUE)
), by = .(pu, species)]

setorder(rij_final, species, pu)

fwrite(rij_final, rij_file)

cat("RIJ finale rows:", nrow(rij_final), "\n")
cat("Specie in RIJ:", uniqueN(rij_final$species), "\n")
cat("PU in RIJ:", uniqueN(rij_final$pu), "\n")
cat("RIJ finale salvato in:\n", rij_file, "\n")

species_without_rij <- setdiff(species_dt$id, unique(rij_final$species))

cat("Specie senza righe RIJ:", length(species_without_rij), "\n")

if (length(species_without_rij) > 0) {
  fwrite(species_dt[id %in% species_without_rij], no_rij_file)
  cat("Lista specie senza RIJ salvata in:\n", no_rij_file, "\n")
}

# ------------------------------------------------------------
# 14. PLANNING UNITS
# ------------------------------------------------------------

cat("\nCreo planning units...\n")

pu_ids <- sort(unique(rij_final$pu))
xy_pu <- xyFromCell(template, pu_ids)

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

fwrite(pu_dt, planning_units_file)

cat("Planning units:", nrow(pu_dt), "\n")
cat("Planning units salvate in:\n", planning_units_file, "\n")

# ------------------------------------------------------------
# 15. FINAL SUMMARY
# ------------------------------------------------------------

cat("\n================ FINAL SUMMARY ================\n")
cat("Species table:\n", species_file, "\n")
cat("RIJ:\n", rij_file, "\n")
cat("Planning units:\n", planning_units_file, "\n")
cat("Log:\n", log_file, "\n")
cat("Chunk summary:\n", chunk_summary_file, "\n")
cat("Preflight:\n", preflight_file, "\n")
cat("Presence rule:\n", presence_rule, "\n")
cat("Amount mode:\n", amount_mode, "\n")
cat("================================================\n")
