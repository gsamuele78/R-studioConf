# BIOME-CALC — Resource Optimization & User Quotas

## 1. Dati Paritetici (Parquet Sync)

Il sistema monitora i dataset massivi e applica procedure di ottimizzazione.

- **Trasparenza:** Usa i classici comandi `read.csv()` e `fread()`.
- Se esiste una variante `.parquet` mappata dalla sincronizzazione notturna, il sistema la inietta scambiando trasparentemente i percorsi, velocizzando i caricamenti fino a 10x.
- Riferimento: `converter_final.R`.

## 2. Gestione Intelligente della RAM (Fair Share)

BIOME-CALC ripartisce automaticamente i pool di RAM (`/proc/meminfo`) basandosi sul numero di utenti live per non causare crash Out-Of-Memory.

- All'avvio della sessione `R`, la quota RAM viene assegnata usando `unix::rlimit_as()`.
- Il sistema garantisce un Garbage Collector forzato (`gc()`) automatico dietro le query ad alta intensità.

**Bypass Amministrativo (Solo per task isolati critici):**
Se un utente ha bisogno di bypassare la quota assegnata, l'admin può disabilitare il bilanciamento dinamico dalla console specifica:

```R
# Disabilita ricalcolo automatico della quota
removeTaskCallback(1)

# Alza il limite a 300GB manualmente:
unix::rlimit_as(300 * 1e9)
```

## 3. Gestione Calcolo Parallelo e RAMDisk

I pacchetti `terra`, `sf`, e `future` configurano automaticamente i bilanciatori core prelevando il valore dinamico del nodo.

- **RAMDisk**: I calcoli raster (`terraOptions(tempdir = "/tmp")`) usano uno storage RAM `/tmp` evitando saturazione sulla rete NFS.
