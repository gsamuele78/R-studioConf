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

# 4. KERAS/TENSORFLOW MULTI-THREAD TEST
# Verifica che il setup CPU-Only con OneDNN sia funzionante senza crash.
message("\n[4/5] Inizializzazione Deep Learning (Keras/TF CPU Test)...")
tryCatch(
    {
        suppressMessages(library(tensorflow))
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
        rm(tf_matrix_a, tf_matrix_b, tf_result)
        gc()
    },
    error = function(e) {
        message("--> ERRORE Keras/TF: ", e$message)
    }
)

# 5. PURE R PARALLEL STABILITY TEST (future.apply)
# Forza l'uso di tutti i core logici per dimostrare la stabilità sotto massimo carico R.
message("\n[5/6] Test di Stabilità Multi-Core R (future.apply)...")
tryCatch(
    {
        suppressMessages(library(future.apply))
        # Pianifica futuro multi-processo su tutti i core disponibili meno 1
        workers <- max(1, parallel::detectCores(logical = TRUE) - 1)
        plan(multisession, workers = workers)
        message("--> Avvio elaborazione parallela su ", workers, " worker...")

        # Una computazione pesante (SVD su grosse matrici ripetuto su ogni core)
        parallel_compute <- function(x) {
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

# 6. CPU BURN & WEBSOCKET TIMEOUT TEST (Nginx Bare-Metal)
# Assicuriamoci che l'Nginx hostato fisicamente non tagli la connessione (proxy_read_timeout).
message("\n[6/6] Inizio ciclo CPU Burn (150 secondi).")
message("🚨 ORA PUOI CHIUDERE LA SCHEDA DEL BROWSER O DISCONNETTERTI! 🚨")
message("Riconnettiti tra qualche minuto per verificare il background daemon.\n")
message("Attendiamo 8 secondi. Chiudi il tab adesso...")
Sys.sleep(8) # Finestra temporale per chiudere la scheda

start_time <- Sys.time()
iterations <- 0
duration_sec <- 150

# Creazione della barra di progresso
pb <- txtProgressBar(min = 0, max = duration_sec, style = 3)

# Un loop che mima l'addestramento di un modello bloccante (Single-Threaded)
while (TRUE) {
    elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
    if (elapsed >= duration_sec) break

    # Aggiorna la barra di progresso
    setTxtProgressBar(pb, min(floor(elapsed), duration_sec))

    # Nessun output testuale (message/print) qui per evitare buffer overflow
    # o SIGPIPE quando il client (browser) disconnette la WebSocket.

    # Simulazione Heavy Compute
    temp <- eigen(matrix(rnorm(600), 20, 30) %*% t(matrix(rnorm(600), 20, 30)))
    iterations <- iterations + 1
}
close(pb)

message("=== LEGACY SYSADMIN STRESS TEST COMPLETATO ===")
message("Orario di fine: ", Sys.time())
message("Iterazioni computazionali eseguite: ", iterations)
message("\n✅ Se stai visualizzando questo messaggio dopo un rientro/riconnessione,")
message("l'architettura Bare-Metal (Nginx Proxy + RStudio Daemon) è TOTALMENTE STABILE.")
