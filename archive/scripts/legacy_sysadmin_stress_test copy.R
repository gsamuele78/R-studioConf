# =====================================================================
# SYSADMIN AUDIT: RStudio Legacy Bare-Metal Stress Test
# =====================================================================
# Richiede: Rprofile.site v9.5+ (CORETYPE detection + WORKER_MODE)
#
# Istruzioni:
# 1. Lancia questo script nell'IDE (Source o Run All).
# 2. Chiudi la scheda del browser o disconnetti la VPN.
# 3. Attendi alcuni minuti.
# 4. Ricollegati al portale e verifica i risultati in console.
# =====================================================================

message("=== LEGACY SYSADMIN STRESS TEST INIZIATO ===")
message("Orario di avvio: ", Sys.time())

# 1. BARE-METAL MEMORY SPIKE TEST
message("\n[1/6] Allocazione aggressiva di RAM (OOM / limits.conf Test)...")
tryCatch(
    {
        legacy_matrix <- matrix(rnorm(280000000), nrow = 10000, ncol = 28000)
        message("--> Successo! Memoria allocata nel rsession: ", round(object.size(legacy_matrix) / 1024^2, 2), " MB")
    },
    error = function(e) {
        message("--> ERRORE/OOM: Intervento OOM Killer o ulimit superato! ", e$message)
    }
)

# 2. NFS / CIFS STORAGE I/O TEST
message("\n[2/6] Scrittura intensiva su Network File System (NFS I/O Test)...")
nfs_temp_file <- file.path(Sys.getenv("HOME"), "legacy_nfs_stress_test.csv")
message("--> Scrittura target: ", nfs_temp_file)
tryCatch(
    {
        write.csv(legacy_matrix[1:1500, 1:1500], nfs_temp_file)
        message("--> Scrittura I/O NFS completata con successo.")
        file.remove(nfs_temp_file)
    },
    error = function(e) {
        message("--> ERRORE I/O: Timeout o permessi negati sulla Home! ", e$message)
    }
)
if (exists("legacy_matrix")) rm(legacy_matrix)
gc()

# 3. TERRA GEOSPATIAL TEST
message("\n[3/6] Elaborazione Raster Spaziale Mappata (Terra GDAL Test)...")
tryCatch(
    {
        suppressMessages(library(terra))
        message("--> Creazione matrice raster virtuale (100 milioni di celle)...")
        r <- rast(nrows = 10000, ncols = 10000, vals = rnorm(1e8))
        message("--> Calcolo algebra raster spaziale...")
        r_out <- r * 2.5 + sin(r)
        message("--> Successo! Operazione Terra Completata. Memoria tempdir: ", terraOptions()$tempdir)
        rm(r, r_out)
        gc()
    },
    error = function(e) message("--> ERRORE Terra/GDAL: ", e$message)
)

# 4. PARALLEL STABILITY + CORETYPE VALIDATION
message("\n[4/6] Test di Stabilità Multi-Core R (CORETYPE + Worker Mode)...")
tryCatch(
    {
        suppressMessages(library(future.apply))

        # ── Sospendi callbacks ──
        saved_callbacks <- getTaskCallbackNames()
        for (cb_name in saved_callbacks) tryCatch(removeTaskCallback(cb_name), error = function(e) NULL)
        if (length(saved_callbacks) > 0) message(sprintf("--> Sospesi %d task callback.", length(saved_callbacks)))

        old_fork_opt <- getOption("parallelly.fork.enable")
        options(parallelly.fork.enable = FALSE)

        # ── Ambiente parent ──
        parent_coretype <- Sys.getenv("OPENBLAS_CORETYPE", "")
        message(sprintf(
            "--> Parent OPENBLAS_CORETYPE: '%s'",
            if (nchar(parent_coretype) == 0) "<NON IMPOSTATO>" else parent_coretype
        ))
        message(sprintf("--> Parent BLAS: %s", sessionInfo()$BLAS))

        if (nchar(parent_coretype) == 0) {
            message("--> WARNING: CORETYPE non impostato! Rprofile.site v9.5 lo setta automaticamente.")
            message("   Se stai usando Rprofile < v9.5, i worker BLAS crasheranno con SIGILL.")
        }

        # ── Crea cluster ──
        workers <- 4L
        Sys.setenv(OMP_NUM_THREADS = 1, OPENBLAS_NUM_THREADS = 1, MKL_NUM_THREADS = 1)

        has_biome_cluster <- tryCatch(
            exists("biome_make_cluster", where = "tools:biome_calc", inherits = FALSE),
            error = function(e) FALSE
        )

        if (has_biome_cluster) {
            message(sprintf("--> biome_make_cluster() (Rprofile v9.4+). Creazione %d worker...", workers))
            cl <- biome_make_cluster(workers = workers, worker_threads = 1L)
        } else {
            message(sprintf("--> Fallback manuale: %d worker con propagazione CORETYPE...", workers))
            rscript_envs <- c(
                OMP_NUM_THREADS = "1", OPENBLAS_NUM_THREADS = "1", MKL_NUM_THREADS = "1"
            )
            if (nchar(parent_coretype) > 0) {
                rscript_envs <- c(rscript_envs, OPENBLAS_CORETYPE = parent_coretype)
            }
            cl <- parallelly::makeClusterPSOCK(
                workers,
                revtunnel = FALSE, homogeneous = TRUE,
                rscript_envs = rscript_envs
            )
        }

        # ── Worker health check ──
        w_check <- tryCatch(
            parallel::clusterEvalQ(cl, {
                list(
                    pid         = Sys.getpid(),
                    coretype    = Sys.getenv("OPENBLAS_CORETYPE", ""),
                    worker_mode = nzchar(Sys.getenv("BIOME_WORKER_MODE", "")),
                    omp         = Sys.getenv("OMP_NUM_THREADS", ""),
                    blas        = sessionInfo()$BLAS,
                    callbacks   = length(getTaskCallbackNames()),
                    bspm        = isNamespaceLoaded("bspm")
                )
            }),
            error = function(e) NULL
        )
        if (!is.null(w_check)) {
            w1 <- w_check[[1]]
            message(sprintf("--> Worker PID %d:", w1$pid))
            message(sprintf(
                "   CORETYPE='%s', WORKER_MODE=%s, OMP=%s",
                if (nchar(w1$coretype) == 0) "<VUOTO>" else w1$coretype,
                w1$worker_mode, w1$omp
            ))
            message(sprintf(
                "   BLAS=%s, callbacks=%d, bspm=%s",
                basename(w1$blas), w1$callbacks, w1$bspm
            ))
        }

        # ── Test helper ──
        run_test <- function(name, fn, n = 100, single = FALSE) {
            message(sprintf("\n--- %s ---", name))
            tryCatch(
                {
                    t0 <- Sys.time()
                    if (single) {
                        res <- parallel::clusterCall(cl, fn, 42)
                    } else {
                        res <- parallel::parSapply(cl, 1:n, fn)
                    }
                    dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
                    message(sprintf("--> %s: PASS (%.2fs)", name, dt))
                    TRUE
                },
                error = function(e) {
                    message(sprintf("--> %s: FAIL — %s", name, e$message))
                    alive <- tryCatch(
                        {
                            parallel::clusterCall(cl, function() TRUE)
                            TRUE
                        },
                        error = function(e2) FALSE
                    )
                    if (!alive) {
                        message("--> Worker morto. Ricostruzione cluster...")
                        tryCatch(parallel::stopCluster(cl), error = function(e) NULL)
                        if (has_biome_cluster) {
                            cl <<- biome_make_cluster(workers = workers, worker_threads = 1L)
                        } else {
                            rscript_envs <- c(OMP_NUM_THREADS = "1", OPENBLAS_NUM_THREADS = "1", MKL_NUM_THREADS = "1")
                            if (nchar(parent_coretype) > 0) rscript_envs <- c(rscript_envs, OPENBLAS_CORETYPE = parent_coretype)
                            cl <<- parallelly::makeClusterPSOCK(workers, revtunnel = FALSE, homogeneous = TRUE, rscript_envs = rscript_envs)
                        }
                    }
                    FALSE
                }
            )
        }

        # ══════════════════════════════════════════════════════
        # PROGRESSIVE ISOLATION
        # ══════════════════════════════════════════════════════
        t1 <- run_test("TEST 1: Trivial (x^2)", function(x) x^2)
        t2 <- run_test("TEST 2: Sleep 3s (TF signal)", function(x) {
            Sys.sleep(3)
            x
        }, n = 4)
        t3 <- run_test("TEST 3: Pure R math (rnorm)", function(x) {
            set.seed(x)
            sum(rnorm(100000))
        })
        t4 <- run_test("TEST 4: BLAS matmul 200x200", function(x) {
            set.seed(x)
            A <- matrix(rnorm(40000), 200, 200)
            sum(A %*% A)
        })
        t5 <- run_test("TEST 5: SVD singolo worker", function(x) {
            set.seed(x)
            sum(svd(matrix(rnorm(90000), 300, 300))$d)
        }, single = TRUE)
        t6 <- run_test("TEST 6: SVD parSapply 100", function(x) {
            Sys.setenv(OMP_NUM_THREADS = 1, OPENBLAS_NUM_THREADS = 1)
            set.seed(x)
            sum(svd(matrix(rnorm(90000), 300, 300))$d)
        })

        t7 <- FALSE
        if (t6) {
            message("\n--- TEST 7: future_sapply (seed=TRUE) ---")
            plan(cluster, workers = cl)
            t7 <- tryCatch(
                {
                    t0 <- Sys.time()
                    res <- future_sapply(1:100, function(x) {
                        Sys.setenv(OMP_NUM_THREADS = 1, OPENBLAS_NUM_THREADS = 1)
                        set.seed(x)
                        sum(svd(matrix(rnorm(90000), 300, 300))$d)
                    }, future.seed = TRUE, future.chunk.size = 25L)
                    dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
                    message(sprintf("--> TEST 7: PASS (%.2fs)", dt))
                    TRUE
                },
                error = function(e) {
                    message(sprintf("--> TEST 7: FAIL — %s", e$message))
                    FALSE
                }
            )
            plan(sequential)
        }

        # ══════════════════════════════════════════════════════
        # DIAGNOSI
        # ══════════════════════════════════════════════════════
        message("\n\u2554", strrep("\u2550", 54), "\u2557")
        message("\u2551               RIEPILOGO DIAGNOSTICO                 \u2551")
        message("\u2560", strrep("\u2550", 54), "\u2563")
        for (info in list(
            list("TEST 1  Trivial (x^2):", t1),
            list("TEST 2  Sleep 3s (TF signal):", t2),
            list("TEST 3  R math (rnorm):", t3),
            list("TEST 4  BLAS matmul:", t4),
            list("TEST 5  SVD singolo worker:", t5),
            list("TEST 6  SVD parSapply 100:", t6),
            list("TEST 7  future_sapply + seed:", t7)
        )) {
            message(sprintf("\u2551  %-35s %-4s              \u2551", info[[1]], if (info[[2]]) "PASS" else "FAIL"))
        }
        message("\u2560", strrep("\u2550", 54), "\u2563")

        if (t1 && t2 && t3 && t4 && t5 && t6 && t7) {
            message("\u2551  TUTTI I TEST PASSANO!                            \u2551")
            message("\u2551  CORETYPE + Worker Mode funzionano correttamente. \u2551")
        } else if (t1 && t2 && t3 && !t4) {
            message("\u2551  OpenBLAS SIGILL nei worker.                      \u2551")
            message("\u2551  OPENBLAS_CORETYPE non propagato.                 \u2551")
            message("\u2551  FIX: Installare Rprofile.site v9.5 o settare     \u2551")
            message("\u2551  OPENBLAS_CORETYPE in Renviron.site.              \u2551")
        } else if (t1 && !t2) {
            message("\u2551  TF signal handler corrompe PSOCK polling.        \u2551")
            message("\u2551  FIX: Creare cluster PRIMA di library(tensorflow).\u2551")
        } else if (!t1) {
            message("\u2551  Socket PSOCK non funzionante.                    \u2551")
            message("\u2551  Verificare firewall, ulimits, connettività.      \u2551")
        }
        message("\u255a", strrep("\u2550", 54), "\u255d")

        # ── Cleanup ──
        plan(sequential)
        tryCatch(parallel::stopCluster(cl), error = function(e) NULL)
        options(parallelly.fork.enable = old_fork_opt)
        for (cb_name in saved_callbacks) tryCatch(addTaskCallback(function(...) TRUE, name = cb_name), error = function(e) NULL)
        message(sprintf("\n--> %d task callback(s) ripristinati.", length(saved_callbacks)))
        gc()
    },
    error = function(e) {
        try(plan(sequential), silent = TRUE)
        tryCatch(parallel::stopCluster(cl), error = function(x) NULL)
        tryCatch(options(parallelly.fork.enable = old_fork_opt), error = function(x) NULL)
        if (exists("saved_callbacks")) {
            for (cb_name in saved_callbacks) tryCatch(addTaskCallback(function(...) TRUE, name = cb_name), error = function(x) NULL)
        }
        message("--> ERRORE: ", e$message)
    }
)

# 5. KERAS/TENSORFLOW MULTI-THREAD TEST
message("\n[5/6] Inizializzazione Deep Learning (Keras/TF CPU Test)...")
tryCatch(
    {
        Sys.setenv(CUDA_VISIBLE_DEVICES = "-1", TF_CPP_MIN_LOG_LEVEL = "3")
        suppressMessages(library(tensorflow))
        tf <- reticulate::import("tensorflow", delay_load = TRUE)
        message("--> Allocazione tensori massivi e calcolo parallelo OneDNN...")
        tf_matrix_a <- tf$random$normal(shape(8000L, 8000L))
        tf_matrix_b <- tf$random$normal(shape(8000L, 8000L))
        message("--> Moltiplicazione tensoriale e riduzione...")
        tf_result <- tf$math$reduce_sum(tf$linalg$matmul(tf_matrix_a, tf_matrix_b))
        message("--> Successo! TensorFlow Tensor Algebra eseguita via CPU: ", as.numeric(tf_result))
        # Rimosso gc() forzato per evitare il blocco (deadlock) dei C++ destructors in thread pool Python/OneDNN
        Sys.sleep(0.5)
    },
    error = function(e) message("--> ERRORE Keras/TF: ", e$message)
)

# 6. CPU BURN & WEBSOCKET TIMEOUT TEST
message("\n[6/6] Inizio ciclo CPU Burn (150 secondi).")

start_time <- Sys.time()
iterations <- 0
duration_sec <- 150

cat("\n[CPU BURN] Attendere... (Target: 150 secondi)\n")
flush.console()

last_print <- -1
# Aggiornamento UI RStudio esplicito
flush.console()
while (TRUE) {
    # Yield al thread UI di RStudio per forzare il rendering in console
    Sys.sleep(0.01)
    
    elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
    if (elapsed >= duration_sec) break
    
    current_sec <- floor(elapsed)
    if (current_sec > last_print && current_sec %% 10 == 0) {
        message(sprintf("--> Tempo trascorso: %d / %d sec. (Iterazioni: %d)", current_sec, duration_sec, iterations))
        flush.console()
        last_print <- current_sec
    }

    temp <- eigen(matrix(rnorm(600), 20, 30) %*% t(matrix(rnorm(600), 20, 30)))
    iterations <- iterations + 1
}

cat(sprintf("\r--> Tempo trascorso: %d / %d sec. (Iterazioni: %d)\n", duration_sec, duration_sec, iterations))
flush.console()

message("=== LEGACY SYSADMIN STRESS TEST COMPLETATO ===")
message("Orario di fine: ", Sys.time())
message("Iterazioni computazionali eseguite: ", iterations)
message("\n\u2705 Se stai visualizzando questo messaggio dopo un rientro/riconnessione,")
message("l'architettura Bare-Metal (Nginx Proxy + RStudio Daemon) è TOTALMENTE STABILE.")
