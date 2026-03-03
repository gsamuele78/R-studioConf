# =====================================================================
# SYSADMIN AUDIT: RStudio Session Persistence & Stress Test
# =====================================================================
# Scopo: Testare la resilienza del demone 'rsession' in background.
# Verifica che Nginx o il Browser non causino la perdita di dati
# in caso di disconnessione della WebSocket (Tab sleep/chiusura).
#
# Istruzioni:
# 1. Lancia questo script nell'IDE (Source o Run All).
# 2. Chiudi la scheda del browser IMMEDIATAMENTE.
# 3. Attendi 2 minuti.
# 4. Riapri il portale, ricollegati a RStudio e controlla la console.
# =====================================================================

message("=== SYSADMIN STRESS TEST INIZIATO ===")
message("Orario di avvio: ", Sys.time())

# 1. MEMORY SPIKE TEST (Allocazione Massiva)
# Verifica i limiti 'deploy.resources.limits' del Compose impostati.
message("\n[1/3] Allocazione di ~1.8GB in RAM (Memory Constraint Test)...")
tryCatch(
    {
        large_matrix <- matrix(rnorm(250000000), nrow = 10000, ncol = 25000)
        message("--> Successo! Memoria allocata: ", round(object.size(large_matrix) / 1024^2, 2), " MB")
    },
    error = function(e) {
        message("--> ERRORE/OOM: Limite memoria superato! ", e$message)
    }
)

# 2. DISK I/O TEMPORARY TEST (/tmpfs)
# Verifica la velocità del RAMDisk montato in Docker.
message("\n[2/3] Scrittura su filesystem temporaneo (Tmpfs/RAMDisk Test)...")
tmp_file <- tempfile()
write.csv(large_matrix[1:1000, 1:1000], tmp_file)
message("--> Scrittura I/O completata in: ", tmp_file)
file.remove(tmp_file)

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

# 6. CPU BURN & BACKGROUND PERSISTENCE TEST
message("\n[6/6] Inizio ciclo CPU Burn (120 secondi).")
message("🚨 ORA PUOI CHIUDERE LA SCHEDA DEL BROWSER! 🚨")
message("Riconnettiti tra un paio di minuti per leggere il risultato...\n")

Sys.sleep(5) # Tempo per permettere al sysadmin di leggere e chiudere la tab

start_time <- Sys.time()
iterations <- 0
duration_sec <- 120

# Creazione della barra di progresso
pb <- txtProgressBar(min = 0, max = duration_sec, style = 3)

# Un ciclo while puro che consuma CPU senza fermare il thread
while (TRUE) {
    elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
    if (elapsed >= duration_sec) break

    # Aggiorna la barra di progresso
    setTxtProgressBar(pb, min(floor(elapsed), duration_sec))

    # Calcoli lineari inutili ma pesanti per la CPU (Singolo Core)
    temp <- svd(matrix(rnorm(400), 20, 20))
    iterations <- iterations + 1
}
close(pb)

message("=== SYSADMIN STRESS TEST COMPLETATO ===")
message("Orario di fine: ", Sys.time())
message("Iterazioni computazionali eseguite: ", iterations)
message("\n✅ Se stai leggendo questo messaggio dopo esserti riconnesso,")
message("la persistenza della sessione (Backend Isolation) è FUNZIONANTE AL 100%.")
