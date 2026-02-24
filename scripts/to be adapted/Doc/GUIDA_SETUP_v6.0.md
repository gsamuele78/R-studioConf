# 🚀 SETUP NODES v6.0 ULTIMATE - GUIDA MODIFICHE

## 📋 MODIFICHE PRINCIPALI vs v5.8

### ✅ **1. GESTIONE THREADING DINAMICA**

**Prima (v5.8):**
```bash
# Nessuna gestione threading
# Utenti impostavano manualmente in .Renviron:
OMP_NUM_THREADS=32
OPENBLAS_NUM_THREADS=32
```

**Dopo (v6.0):**
```bash
# Threading gestito DINAMICAMENTE da Rprofile.site v8.2
# - Calcolo automatico basato su sessioni attive
# - Fair-share tra utenti
# - Ribilanciamento real-time
# - Variabili rimosse da .Renviron utente
```

**Benefici:**
- ✅ 1 utente → 32 threads
- ✅ 2 utenti → 16 threads ciascuno
- ✅ 4 utenti → 8 threads ciascuno
- ✅ Zero conflitti risorse

---

### ✅ **2. INSTALLAZIONE bspm (Binary Package Manager)**

**Nuovo in v6.0:**
```bash
# bspm permette installazione binari invece di compilazione
sudo R -e "install.packages('bspm'); bspm::enable()"
```

**Vantaggi:**
- ⚡ **10-20x più veloce** installazione pacchetti
- 💾 Risparmio spazio (no build artifacts)
- 🔧 Meno problemi compilazione
- 🎯 Configurato system-wide automaticamente

---

### ✅ **3. CONFIGURAZIONE OpenBLAS/OpenMP**

**Aggiunto in v6.0:**
```bash
# Installazione esplicita
sudo apt install -y libopenblas-dev libomp-dev

# Configurazione Haswell in /etc/environment
OPENBLAS_CORETYPE=Haswell

# Verifica installazione
ldconfig -p | grep libopenblas
ldconfig -p | grep libomp
```

**Benefici:**
- ✅ Performance ottimizzate per CPU Haswell
- ✅ Verifica automatica installazione
- ✅ Configurazione persistente

---

### ✅ **4. RAMDISK /tmp OTTIMIZZATO**

**Migliorato in v6.0:**
```bash
# Verifica e rimonta RAMDisk
sudo systemctl daemon-reload
sudo mount -o remount /tmp

# Log dimensione effettiva
df -h /tmp
```

**Gestione in Renviron.site:**
```bash
TMPDIR=/tmp
TMP=/tmp
TEMP=/tmp
R_TEMPDIR=/tmp
TF_CPP_MIN_LOG_LEVEL=2
KERAS_HOME=/tmp/keras  # TensorFlow usa RAMDisk
```

**Benefici:**
- ✅ TensorFlow/Keras usano RAMDisk (100GB)
- ✅ Calcoli pesanti senza I/O disco
- ✅ 100GB esclusi da quota RAM R
- ✅ Performance 10-100x su operazioni temporanee

---

### ✅ **5. RENVIRON.SITE ENTERPRISE**

**Prima (v5.8):**
```bash
# Minimalista
R_LIBS_SITE="..."
OPENBLAS_CORETYPE=Haswell
TMPDIR=/tmp
```

**Dopo (v6.0):**
```bash
# Completo e documentato
R_LIBS_SITE="/usr/local/lib/R/site-library/..."
OPENBLAS_CORETYPE=Haswell

# Temporary directories (RAMDisk)
TMPDIR=/tmp
TMP=/tmp
TEMP=/tmp
R_TEMPDIR=/tmp

# TensorFlow/Keras optimization
TF_CPP_MIN_LOG_LEVEL=2
KERAS_HOME=/tmp/keras

# Compilation security
_R_CHECK_COMPILATION_FLAGS_KNOWN_='-Wformat -Werror=format-security -Wdate-time'

# Threading: managed by Rprofile.site (DYNAMIC)
```

---

### ✅ **6. TEMPLATE UTENTE .Renviron**

**Nuovo in v6.0:**

Creato `/etc/skel/.Renviron` per nuovi utenti:
```bash
# Template automatico per nuovi utenti
# Include warning su threading dinamico
# Pre-configurato con best practices
```

**Script migrazione utenti esistenti:**
```bash
# Rimuove thread settings statici
sed -i '/^OMP_NUM_THREADS=/d' ~/.Renviron
sed -i '/^OPENBLAS_NUM_THREADS=/d' ~/.Renviron

# Aggiunge warning
cat >> ~/.Renviron <<EOF
# Threading gestito dinamicamente dal sistema
# NON impostare OMP/OPENBLAS_NUM_THREADS qui
EOF
```

---

### ✅ **7. RPROFILE.SITE v8.2 ULTIMATE**

**Prima (v5.7):**
- Base resource management
- Smart I/O Parquet
- Python integration

**Dopo (v8.2):**
- **Tutto da v5.7 +**
- ✅ OpenBLAS/OpenMP dinamico
- ✅ TensorFlow CPU/GPU threading
- ✅ terra/GDAL optimization
- ✅ Arrow/Parquet threading
- ✅ future adaptive strategy
- ✅ Ollama/AI optimization
- ✅ rgee advanced

**644 righe vs 200 righe precedenti**

---

### ✅ **8. LOGGING E DEBUG**

**Nuovo sistema di log:**
```bash
# Colorato e strutturato
log_info()    # Blu
log_success() # Verde
log_warn()    # Giallo
log_error()   # Rosso

# Log file sistema
/var/log/r_biome_system.log
```

**Benefici:**
- ✅ Setup più leggibile
- ✅ Errori facilmente identificabili
- ✅ Log persistenti per audit

---

### ✅ **9. VERIFICA FINALE AUTOMATICA**

**Nuovo in v6.0:**
```bash
# Alla fine dello script:
- RAM totale
- RAMDisk size
- OpenBLAS version
- Python version
- Ollama version
- Checklist prossimi passi
```

---

## 🔧 CONFIGURAZIONI CRITICHE

### **A. /etc/R/Renviron.site**

```bash
# Sistema-wide, caricato per TUTTI gli utenti
# Priorità: PRIMA di .Renviron utente

Key settings:
- R_LIBS_SITE          # Percorsi librerie
- OPENBLAS_CORETYPE    # Ottimizzazione CPU
- TMPDIR/TMP/TEMP      # RAMDisk
- KERAS_HOME           # TensorFlow cache
- TF_CPP_MIN_LOG_LEVEL # Soppressione log TF
```

### **B. ~/.Renviron (utente)**

```bash
# Per-user, caricato DOPO Renviron.site
# Usa per override personali

Permitted overrides:
- RETICULATE_PYTHON    # Python venv personale
- EARTHENGINE_PYTHON   # GEE Python personale
- R_LIBS_USER          # Librerie personali

FORBIDDEN (gestiti dinamicamente):
- OMP_NUM_THREADS
- OPENBLAS_NUM_THREADS
- MKL_NUM_THREADS
- TF_NUM_*_THREADS
```

### **C. /etc/R/Rprofile.site**

```bash
# Logica applicativa R
# 644 righe di ottimizzazioni

Gestisce:
- Threading dinamico (tutti i framework)
- Fair-share RAM/CPU
- GPU detection
- Ribilanciamento automatico
- Smart I/O
- Logging
```

---

## 📊 IMPATTO CONFIGURAZIONE RAMDISK

### **Sistema con 250GB RAM, RAMDisk 100GB**

```
RAM Host:              250 GB
RAMDisk /tmp:          100 GB  (escluso da R)
OS Reserve:             15 GB  (escluso da R)
─────────────────────────────
RAM disponibile R:     135 GB

Con 4 utenti:
- RAM per utente:      30 GB  (135/4 * 0.9)
- Cores per utente:    8      (32/4)
- Threads BLAS:        8
- Threads TF:          4/8    (inter/intra)
```

**Benefici RAMDisk:**
```
TensorFlow model cache:     /tmp/keras (RAMDisk)
Terra temporary rasters:    /tmp/terra_USER (RAMDisk)
Arrow temporary files:      /tmp/arrow_USER (RAMDisk)
R temporary objects:        /tmp/Rtmp* (RAMDisk)

→ I/O disk: 0
→ Speed: 10-100x più veloce
→ SSD wear: ridotto a zero
```

---

## 🎯 CONFIGURAZIONE UTENTE RSTUDIO

### **File: ~/.config/rstudio/rstudio-prefs.json**

**Settings ottimali per BIOME-CALC:**

```json
{
    "always_save_history": false,
    "load_workspace": false,
    "save_workspace": "never",
    "python_type": "system",
    "python_path": "/opt/r-geospatial/bin/python",
    "code_formatter": "styler",
    "reformat_on_save": true,
    "show_diagnostics_other": true,
    "check_arguments_to_r_function_calls": true
}
```

**Note:**
- `python_path` → usa environment system
- `save_workspace: never` → evita .RData overhead
- `reformat_on_save` → code quality

---

## 🚀 INSTALLAZIONE

### **Step 1: Preparazione**

```bash
# Download files
wget https://your-server/setup_nodes_v6.0_ULTIMATE.sh
wget https://your-server/Rprofile.site_v8.2_ULTIMATE

# Verifica integrità
sha256sum setup_nodes_v6.0_ULTIMATE.sh
```

### **Step 2: Esecuzione**

```bash
# Rendi eseguibile
chmod +x setup_nodes_v6.0_ULTIMATE.sh

# Esegui come root
sudo ./setup_nodes_v6.0_ULTIMATE.sh
```

**Durata:** 15-30 minuti
- Download pacchetti: 5-10 min
- Compilazione R packages: 5-10 min
- Ollama model download: 5-10 min

### **Step 3: Post-installazione**

```bash
# 1. Riavvia RStudio Server
sudo systemctl restart rstudio-server

# 2. Verifica log
tail -f /var/log/rstudio/rserver.log

# 3. Test prima sessione
R
```

### **Step 4: Audit**

```bash
# In R
source("00_audit_final_v12.R")

# Verifica:
# - Tutti i test PASS o WARN (no FAIL)
# - Threading dinamico attivo
# - GPU detection (se presente)
```

---

## 🐛 TROUBLESHOOTING

### **Problema: bspm non funziona**

```bash
# Verifica installazione
R -e "library(bspm); bspm::manager()"

# Se manca, reinstalla
sudo R -e "install.packages('bspm'); bspm::enable()"
```

### **Problema: Threading sempre uguale**

```bash
# Verifica se Rprofile caricato
R -e "exists('update_resources')"  # Dovrebbe essere TRUE

# Verifica variabili
R -e "Sys.getenv('OMP_NUM_THREADS')"  # Dovrebbe essere numerico

# Forza refresh
R -e "status()"
```

### **Problema: RAMDisk non montato**

```bash
# Verifica
df -h /tmp

# Se non 100G, rimonta
sudo mount -o remount,size=100G /tmp

# Verifica fstab
grep tmpfs /etc/fstab
```

### **Problema: Ollama non risponde**

```bash
# Verifica servizio
sudo systemctl status ollama

# Restart
sudo systemctl restart ollama

# Test API
curl -X POST http://localhost:11434/api/generate -d '{"model":"codellama:7b","prompt":"test","stream":false}'
```

---

## 📚 MIGRAZIONE DA v5.8

### **Backup prima di migrare**

```bash
# Backup configurazioni
sudo cp /etc/R/Rprofile.site /root/backup/Rprofile.site.v5.8
sudo cp /etc/R/Renviron.site /root/backup/Renviron.site.v5.8

# Backup utenti (sample)
tar -czf /root/backup/users_renviron_$(date +%Y%m%d).tar.gz /nfs/home/*/.Renviron
```

### **Migrazione step-by-step**

```bash
# 1. Ferma RStudio
sudo systemctl stop rstudio-server

# 2. Esegui setup v6.0
sudo ./setup_nodes_v6.0_ULTIMATE.sh

# 3. Verifica configurazioni
diff /root/backup/Renviron.site.v5.8 /etc/R/Renviron.site

# 4. Riavvia RStudio
sudo systemctl start rstudio-server

# 5. Monitora log
tail -f /var/log/rstudio/rserver.log
```

### **Rollback (se necessario)**

```bash
# Restore configurazioni
sudo cp /root/backup/Rprofile.site.v5.8 /etc/R/Rprofile.site
sudo cp /root/backup/Renviron.site.v5.8 /etc/R/Renviron.site

# Riavvia
sudo systemctl restart rstudio-server
```

---

## ✅ CHECKLIST POST-INSTALLAZIONE

- [ ] RStudio Server riavviato
- [ ] Audit v12 eseguito senza FAIL
- [ ] Threading dinamico verificato
- [ ] RAMDisk /tmp verificato (100GB)
- [ ] OpenBLAS/OpenMP funzionanti
- [ ] bspm attivo
- [ ] Ollama risponde
- [ ] Utenti possono loggare
- [ ] Prima sessione R funziona
- [ ] TensorFlow/Keras inizializzabili
- [ ] terra/rgee funzionanti

---

**Versione:** 6.0 ULTIMATE  
**Data:** 14 Febbraio 2026  
**Sistema:** BIOME-CALC Enterprise - Multi-user Production
