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

# 3. CPU BURN & BACKGROUND PERSISTENCE TEST
message("\n[3/3] Inizio ciclo CPU Burn (120 secondi).")
message("🚨 ORA PUOI CHIUDERE LA SCHEDA DEL BROWSER! 🚨")
message("Riconnettiti tra un paio di minuti per leggere il risultato...\n")

Sys.sleep(5) # Tempo per permettere al sysadmin di leggere e chiudere la tab

start_time <- Sys.time()
iterations <- 0
# Un ciclo while puro che consuma CPU senza fermare il thread
while (as.numeric(difftime(Sys.time(), start_time, units = "secs")) < 120) {
    # Calcoli lineari inutili ma pesanti per la CPU (Singolo Core)
    temp <- svd(matrix(rnorm(400), 20, 20))
    iterations <- iterations + 1
}

message("=== SYSADMIN STRESS TEST COMPLETATO ===")
message("Orario di fine: ", Sys.time())
message("Iterazioni computazionali eseguite: ", iterations)
message("\n✅ Se stai leggendo questo messaggio dopo esserti riconnesso,")
message("la persistenza della sessione (Backend Isolation) è FUNZIONANTE AL 100%.")
