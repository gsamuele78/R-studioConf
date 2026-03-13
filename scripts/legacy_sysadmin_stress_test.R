# =====================================================================
# SYSADMIN AUDIT: RStudio Legacy Bare-Metal Stress Test
# =====================================================================
# Scopo: Testare la resilienza del demone 'rsession' sul server fisico
# (o VM) Bare-Metal gestito tramite systemd e le direttive PAM/SSSD.
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
# Testa i cgroups e i limiti fisici imposti da 'configure_rstudio.vars.conf'
# o eventuali limitazioni PAM (es. ulimit).
message("\n[1/3] Allocazione aggressiva di RAM (OOM / limits.conf Test)...")
tryCatch(
    {
        # Alloca circa ~2GB di dati sequenziali
        legacy_matrix <- matrix(rnorm(280000000), nrow = 10000, ncol = 28000)
        message("--> Successo! Memoria allocata allocata nel rsession: ", round(object.size(legacy_matrix) / 1024^2, 2), " MB")
    },
    error = function(e) {
        message("--> ERRORE/OOM: Intervento OOM Killer o ulimit superato! ", e$message)
    }
)

# 2. NFS / CIFS STORAGE I/O TEST
# Il progetto legacy monta pesantemente la home UTENTE via NFS CIFS (/nfs/home)
# Scrivere qui dentro testa la latenza della rete storage di Ateneo e l'RStudio File-Lock.
message("\n[2/3] Scrittura intensiva su Network File System (NFS I/O Test)...")
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

# Liberiamo la RAM per evitare che il processo CPU-Burn vada in OOM (Out Of Memory)
if (exists("legacy_matrix")) rm(legacy_matrix)
gc()

# 3. TERRA GEOSPATIAL TEST (RAMDisk / NFS Fallback)
# Testa le direttive BIOME per l'allocazione dinamica della memoria raster.
message("\n[3/5] Elaborazione Raster Spaziale Mappata (Terra GDAL Test)...")
tryCatch(
    {
        suppressMessages(library(terra))
        # Crea un raster 10k x 10k (circa 800MB in RAM)
        message("--> Creazione matrice raster virtuale (100 milioni di celle)...")
        r <- rast(nrows = 10000, ncols = 10000, vals = rnorm(1e8))
        # Calcolo algebra raster pesante (usando l'engine C++ GDAL)
        message("--> Calcolo algebra raster spaziale...")
        r_out <- r * 2.5 + sin(r)
        message("--> Successo! Operazione Terra Completata. Memoria tempdir: ", terraOptions()$tempdir)
        rm(r, r_out)
        gc()
    },
    error = function(e) {
        message("--> ERRORE Terra/GDAL: ", e$message)
    }
)

# 4. PURE R PARALLEL STABILITY TEST (future.apply)
# Forza l'uso di tutti i core logici per dimostrare la stabilità sotto massimo carico R.
message("\n[4/5] Test di Stabilità Multi-Core R (future.apply)...")
tryCatch(
    {
        suppressMessages(library(future.apply))
        
        # Rispetta CPU Quota dei container e limiti fisici PAM (max 4 per sicurezza PAM)
        workers <- min(4, max(1, future::availableCores() - 1))
        
        # Cgroups OOM Prevention: riduciamo i worker in base alla RAM disponibile del container
        mem_limit_mb <- tryCatch({
            val <- Inf
            if (file.exists("/sys/fs/cgroup/memory.max")) {
                txt <- trimws(readLines("/sys/fs/cgroup/memory.max", n = 1, warn = FALSE))
                if (txt != "max") val <- as.numeric(txt) / 1024^2
            } else if (file.exists("/sys/fs/cgroup/memory/memory.limit_in_bytes")) {
                val <- as.numeric(readLines("/sys/fs/cgroup/memory/memory.limit_in_bytes", n = 1, warn = FALSE)) / 1024^2
            }
            val
        }, warning = function(w) Inf, error = function(e) Inf)
        
        if (is.finite(mem_limit_mb) && mem_limit_mb > 0) {
            max_workers <- max(1, floor(mem_limit_mb / 400)) # ~400MB base per worker in multisession
            if (workers > max_workers) {
                message(sprintf("--> Cgroups RAM Limit: %d MB. Limitazione workers: %d -> %d per prevenire OOM Killer.", round(mem_limit_mb), workers, max_workers))
                workers <- max_workers
            }
        }
        
        # Evita la "Thread Explosion" di OpenBLAS/MKL nei processi paralleli
        Sys.setenv(OMP_NUM_THREADS = 1, OPENBLAS_NUM_THREADS = 1, MKL_NUM_THREADS = 1)
        
        # Passiamo a 'multisession' (PSOCK) per evitare i deadlock da fork post-TensorFlow
        plan(multisession, workers = workers)
        message("--> Avvio elaborazione parallela su ", workers, " worker (multisession PSOCK)...")

        # Una computazione pesante (SVD su grosse matrici ripetuto su ogni core)
        parallel_compute <- function(x) {
            # Forza i worker a usare un solo thread per l'algebra lineare
            Sys.setenv(OMP_NUM_THREADS = 1, OPENBLAS_NUM_THREADS = 1, MKL_NUM_THREADS = 1)
            if (requireNamespace("RhpcBLASctl", quietly = TRUE)) {
                RhpcBLASctl::blas_set_num_threads(1)
                RhpcBLASctl::omp_set_num_threads(1)
            }
            set.seed(x)
            sum(svd(matrix(rnorm(90000), 300, 300))$d)
        }

        # Lancia 100 task distribuiti
        results <- future_sapply(1:100, parallel_compute, future.seed = TRUE)
        message("--> Successo! Computazione parallela completata senza errori.")
        rm(results)
        gc()
    },
    error = function(e) {
        message("--> ERRORE Future Parallel: ", e$message)
    }
)

# 5. KERAS/TENSORFLOW MULTI-THREAD TEST
# Verifica che il setup CPU-Only con OneDNN sia funzionante senza crash.
message("\n[5/6] Inizializzazione Deep Learning (Keras/TF CPU Test)...")
tryCatch(
    {
        suppressMessages(library(tensorflow))
        tf <- reticulate::import("tensorflow", delay_load = TRUE)
        message("--> Allocazione tensori massivi e calcolo parallelo OneDNN...")
        # Forziamo l'uso esclusivo della CPU e disabilitiamo i warning CUDA (cuInit)
        Sys.setenv(CUDA_VISIBLE_DEVICES = "-1")
        Sys.setenv(TF_CPP_MIN_LOG_LEVEL = "2")

        # Evitiamo keras_model_sequential() per aggirare bug delle callback di TF 2.16+ in R
        # Eseguiamo algebra tensoriale pura sforzando tutti i thread CPU disponibili.
        tf_matrix_a <- tf$random$normal(shape(8000L, 8000L))
        tf_matrix_b <- tf$random$normal(shape(8000L, 8000L))

        message("--> Moltiplicazione tensoriale e riduzione...")
        tf_result <- tf$math$reduce_sum(tf$linalg$matmul(tf_matrix_a, tf_matrix_b))

        message("--> Successo! TensorFlow Tensor Algebra eseguita via CPU: ", as.numeric(tf_result))
        # Rimosso gc() forzato per evitare il blocco (deadlock) dei C++ destructors in thread pool Python/OneDNN
        Sys.sleep(0.5)
    },
    error = function(e) {
        message("--> ERRORE Keras/TF: ", e$message)
    }
)

# 6. CPU BURN & WEBSOCKET TIMEOUT TEST (Nginx Bare-Metal)
# Assicuriamoci che l'Nginx hostato fisicamente non tagli la connessione (proxy_read_timeout).
message("\n[6/6] Inizio ciclo CPU Burn (150 secondi).")

start_time <- Sys.time()
iterations <- 0
duration_sec <- 150

cat("\n[CPU BURN] Attendere... (Target: 150 secondi)\n")
flush.console()

last_print <- -1
# Aggiornamento UI RStudio esplicito
flush.console()
# Un loop che mima l'addestramento di un modello bloccante (Single-Threaded)
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

    # Nessun output testuale (message/print) qui per evitare buffer overflow
    # o SIGPIPE quando il client (browser) disconnette la WebSocket.

    # Simulazione Heavy Compute
    temp <- eigen(matrix(rnorm(600), 20, 30) %*% t(matrix(rnorm(600), 20, 30)))
    iterations <- iterations + 1
}

cat(sprintf("\r--> Tempo trascorso: %d / %d sec. (Iterazioni: %d)\n", duration_sec, duration_sec, iterations))
flush.console()

message("=== LEGACY SYSADMIN STRESS TEST COMPLETATO ===")
message("Orario di fine: ", Sys.time())
message("Iterazioni computazionali eseguite: ", iterations)
message("\n✅ Se stai visualizzando questo messaggio dopo un rientro/riconnessione,")
message("l'architettura Bare-Metal (Nginx Proxy + RStudio Daemon) è TOTALMENTE STABILE.")
