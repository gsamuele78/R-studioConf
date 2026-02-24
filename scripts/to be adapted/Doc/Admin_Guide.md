# 🛠️ Manuale Amministratore: BIOME-CALC (v5.5)
*Guida Tecnica, Troubleshooting e Manutenzione*
## 🏗️ Architettura del Sistema
Il sistema si basa su un'integrazione profonda tra l'host (Ubuntu/TrueNAS), Docker (per la conversione) e RStudio (per l'analisi).
Componenti Chiave:
1. **run_sync.sh:** Script Bash che orchestra la conversione CSV -> Parquet e gestisce le ACL NFSv4.
2. **Rprofile.site:** Gestisce quote RAM, core CPU e wrapper trasparenti.
3. **converter_final.R:** Engine scientifico che preserva l'integrità dei dati spaziali e climatici.
## 🆘 Troubleshooting & Use Cases
### Caso 1: L'utente ha bisogno di più RAM della quota assegnata
**Sintomo:** L'utente riceve l'errore cannot allocate vector... ma il server ha RAM libera.
**Azione:** Puoi forzare un limite manuale per quella sessione specifica.
Comando (nella console dell'utente):
```
R
# Disabilita il ricalcolo automatico della quota
removeTaskCallback(1)
# Alza il limite a 300GB
unix::rlimit_as(300 * 1e9)
```

### Caso 2: Ripristino di un file Parquet corrotto
**Sintomo:** L'utente vede errori durante il caricamento di un file specifico.
**Azione:** Forza la rigenerazione del file.
1. Elimina il file .parquet incriminato nello storage.
2. Lancia manualmente lo script di sync: ./run_sync.sh.
### Caso 3: Processi R "Zombi" che occupano RAM
**Sintomo:** La quota assegnata agli utenti è molto bassa ma nessuno sta lavorando.
**Azione:** Identifica e chiudi le sessioni appese.
Comando Terminale:
```
bash
# Visualizza processi R per utente
ps aux | grep rsession
# Chiudi processi più vecchi di 2 giorni (esempio)
skill -9 -u [username] 
```

## 🆘 Scenario A: Un utente ha bisogno di "Extra RAM" (Bypass)
Se un botanico deve lanciare un calcolo critico che supera la sua quota dinamica, puoi alzare il limite manualmente per quella sessione.
**Soluzione:** Digitare nella console R dell'utente:

```
R
# Alza il limite a 300GB manualmente (solo per questa sessione)
unix::rlimit_as(300 * 1e9)
# Disattiva il ricalcolo automatico per questa sessione
removeTaskCallback(1) 
```

## 🆘 Scenario B: "Il file .parquet non è aggiornato"
Se i dati nel CSV originale sono cambiati ma il Parquet non è stato ancora rigenerato dal sistema di sync.
**Soluzione:** L'utente può forzare la lettura del CSV originale bypassando il wrapper:
```
R
df <- utils::read.csv("file.csv") # Usando il prefisso 'utils::'
```

## 🆘 Scenario C: Errore "cannot allocate vector of size..."
Accade se l'utente ha saturato la sua quota RAM o se il server è fisicamente pieno.
**Troubleshooting:**
- Verificare utenti attivi: **pgrep -c rsession.**
- Verificare processi **"morti"** ma che occupano RAM: top o htty.
- Chiedere agli utenti di eseguire **gc()** o riavviare la sessione **(Session -> Restart R)**.



## 📋 Checklist Manutenzione Settimanale Truenas (Admin)
**Controllare i log della conversione su Truenas:**
tail -n 50 /mnt/zpool/Apps/biome-converter/scripts/conversion.log
**Pulire file temporanei orfani nel RAMDisk:**
find /tmp -atime +1 -delete (Rimuove file più vecchi di un giorno).
**Monitorare lo spazio disco dello storage:**
zfs list (Per assicurarsi che il volume home non sia al limite).


## 📋 Manutenzione Ordinaria
**Settimanale:** Verificare il log di conversione sul nas: /mnt/zpool/Apps/biome-converter/scripts/conversion.log.
**Mensile:** Aggiornare l'ambiente Python centralizzato  su R-studio in /opt/r-geospatial.
**Alert:** Se il comando zfs list su Truenas mostra lo storage oltre l'85%, procedere alla rimozione dei CSV non protetti (SUCCESS_PATH_DELETE).
## 📊 Proposta: Web Dashboard Statica (Real-Time Monitoring)
Per monitorare i 21 utenti in modo professionale senza sovraccaricare il server, possiamo implementare una Dashboard HTML5 con queste caratteristiche:
- **Backend Leggero:** Uno script Bash che ogni 60 secondi legge /proc e genera un file JSON.
- **Frontend Dinamico:** Una singola pagina HTML con CSS moderno e Chart.js per grafici fluidi.
- **Visualizzazione:**
Grafico a "ciambella" per la RAM totale (Occupata/Libera).
Barre di progresso per ogni utente (RAM usata vs Quota assegnata).
Stato del sistema (Core attivi, ultimi file convertiti).