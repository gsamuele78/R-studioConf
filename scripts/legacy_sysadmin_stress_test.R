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

# 3. CPU BURN & WEBSOCKET TIMEOUT TEST (Nginx Bare-Metal)
# Assicuriamoci che l'Nginx hostato fisicamente non tagli la connessione (proxy_read_timeout).
message("\n[3/3] Inizio ciclo CPU Burn (150 secondi).")
message("🚨 ORA PUOI CHIUDERE LA SCHEDA DEL BROWSER O DISCONNETTERTI! 🚨")
message("Riconnettiti tra qualche minuto per verificare il background daemon.\n")
message("Attendiamo 8 secondi. Chiudi il tab adesso...")
Sys.sleep(8) # Finestra temporale per chiudere la scheda

start_time <- Sys.time()
iterations <- 0
# Un loop che mima l'addestramento di un modello bloccante (Single-Threaded)
while (as.numeric(difftime(Sys.time(), start_time, units = "secs")) < 150) {
    # Nessun output testuale (message/print) qui per evitare buffer overflow
    # o SIGPIPE quando il client (browser) disconnette la WebSocket.

    # Simulazione Heavy Compute
    temp <- eigen(matrix(rnorm(600), 20, 30) %*% t(matrix(rnorm(600), 20, 30)))
    iterations <- iterations + 1
}

message("=== LEGACY SYSADMIN STRESS TEST COMPLETATO ===")
message("Orario di fine: ", Sys.time())
message("Iterazioni computazionali eseguite: ", iterations)
message("\n✅ Se stai visualizzando questo messaggio dopo un rientro/riconnessione,")
message("l'architettura Bare-Metal (Nginx Proxy + RStudio Daemon) è TOTALMENTE STABILE.")
