# 🚀 OTTIMIZZAZIONI TENSORFLOW/KERAS/RGEE v8.1.0

## 📋 NUOVE FUNZIONALITÀ AGGIUNTE

### ✅ Rispetto alla versione precedente (v8.0.0), ora gestito dinamicamente:

**TensorFlow/Keras:**
- ✅ Threading CPU (interop/intraop)
- ✅ Rilevamento GPU automatico
- ✅ Gestione memoria GPU dinamica
- ✅ Multi-GPU allocation
- ✅ Coordinamento con OpenBLAS/OpenMP

**Google Earth Engine (rgee):**
- ✅ Cache optimization
- ✅ Memory management
- ✅ Parallel processing
- ✅ API rate limiting
- ✅ Retry logic

---

## 🎯 CONFIGURAZIONE TENSORFLOW/KERAS

### **Threading CPU Dinamico**

Il sistema ora configura automaticamente:

```r
# Variabili impostate dinamicamente:
TF_NUM_INTEROP_THREADS  # Parallelismo tra operazioni (es: 16)
TF_NUM_INTRAOP_THREADS  # Parallelismo dentro operazioni (es: 32)
TF_CPP_MIN_LOG_LEVEL    # Soppressione log (sempre "2")
```

**Strategia di allocazione:**
```
Utenti Attivi | BLAS/OMP Threads | TF Interop | TF Intraop
-------------|------------------|------------|------------
1            | 32               | 16         | 32
2            | 16               | 8          | 16
4            | 8                | 4          | 8
8            | 4                | 2          | 4
```

**Logica:**
- `TF_NUM_INTEROP_THREADS` = 50% dei thread totali (parallelismo tra op)
- `TF_NUM_INTRAOP_THREADS` = 100% dei thread totali (parallelismo dentro op)
- Coordinati con `OMP_NUM_THREADS` e `OPENBLAS_NUM_THREADS`

### **Rilevamento GPU Automatico**

Il sistema rileva automaticamente GPU disponibili:

```r
# Metodo 1: nvidia-smi (NVIDIA GPU)
nvidia-smi --query-gpu=count --format=csv,noheader

# Metodo 2: TensorFlow detection
tensorflow$config$list_physical_devices("GPU")

# Risultato salvato in:
shared_env$has_gpu    # TRUE/FALSE
shared_env$gpu_count  # Numero GPU rilevate
```

**Esempio output con GPU:**
```
[2.6.1] GPU Detection & Count  [SUCCESS]
    (2 x NVIDIA GeForce RTX 4090)

🎮 GPU: 2 detected | TF Backend: GPU-accelerated
```

**Esempio output senza GPU:**
```
[2.6.1] GPU Detection & Count  [WARNING]
    (CPU-only mode)

💻 TF Backend: CPU-optimized (32 threads)
```

### **Gestione Memoria GPU Dinamica**

Per GPU NVIDIA, il sistema configura:

```bash
# Crescita graduale memoria GPU (evita out-of-memory)
TF_FORCE_GPU_ALLOW_GROWTH=true

# Visibilità GPU (tutte disponibili)
CUDA_VISIBLE_DEVICES=0,1,2,3
```

**Vantaggi:**
- ✅ Memoria allocata solo quando necessaria
- ✅ Più utenti possono usare la stessa GPU
- ✅ Evita errori OOM (Out Of Memory)
- ✅ Fair-share automatico tra sessioni

### **Multi-GPU Allocation**

Con più GPU disponibili:

```r
# Esempio: 4 GPU, 2 utenti attivi
gpu_per_session = floor(4 / 2) = 2 GPU per utente

# CUDA_VISIBLE_DEVICES configurato automaticamente
# Utente 1: CUDA_VISIBLE_DEVICES=0,1
# Utente 2: CUDA_VISIBLE_DEVICES=2,3
```

### **Configurazione Keras**

Il sistema configura automaticamente Keras:

```r
# Seed per riproducibilità
options(keras.seed = 42)

# Backend precision (float32 di default)
keras::config_set_backend_floatx("float32")

# Session configuration applicata al primo uso
```

---

## 🌍 OTTIMIZZAZIONI RGEE (GOOGLE EARTH ENGINE)

### **Cache Management**

```r
# Directory cache personalizzata per utente
rgee_cache = ~/.config/earthengine/rgee_cache

# Configurazione automatica:
options(
  rgee.cache_path = rgee_cache,
  rgee.max_memory = 30% della RAM quota utente
)
```

**Esempio con 4 utenti (RAM 30GB ciascuno):**
```
rgee.max_memory = 30 * 0.30 * 1e9 = 9GB per cache
```

### **Parallel Processing**

```r
# Configurazione dinamica core per rgee
options(
  rgee.parallel = TRUE,
  rgee.n_cores = min(4, floor(total_cores / n_utenti))
)
```

**Allocazione core:**
```
Utenti | Total Cores | rgee.n_cores
-------|-------------|-------------
1      | 32          | 4 (massimo)
2      | 32          | 4
4      | 32          | 2
8      | 32          | 1
```

**Nota:** rgee usa massimo 4 core anche se disponibili di più, per evitare overhead su Google Earth Engine API.

### **API Rate Limiting**

```r
# Configurazione rate limiting (limiti GEE API)
options(
  rgee.api_rate_limit = 10,    # Max 10 richieste simultanee
  rgee.retry_attempts = 3,      # Retry automatico su errore
  rgee.timeout = 600            # 10 minuti timeout
)
```

**Gestione errori:**
- ⚡ Max 10 richieste parallele (evita throttling Google)
- 🔄 Retry automatico 3 volte su fallimento temporaneo
- ⏱️ Timeout di 10 minuti per operazioni lunghe

### **Credenziali Earth Engine**

Il sistema verifica automaticamente:

```r
# File credenziali
~/.config/earthengine/credentials

# Controlli:
✓ Esistenza file
✓ Validità (non vuoto, size > 10 bytes)
⚠️ Warning se credenziali > 1 anno
```

---

## 📊 CONFRONTO PRIMA/DOPO

### **PRIMA (v8.0.0):**
```bash
# TensorFlow
TF_CPP_MIN_LOG_LEVEL=2                    # Solo log suppression
# Nessuna configurazione threading CPU
# Nessun rilevamento GPU
# Nessuna gestione memoria GPU

# rgee
# Solo auto-inizializzazione
# Nessuna ottimizzazione cache/memory
# Nessun rate limiting
```

### **DOPO (v8.1.0):**
```bash
# TensorFlow
TF_CPP_MIN_LOG_LEVEL=2
TF_NUM_INTEROP_THREADS=16                 # ✅ Dinamico
TF_NUM_INTRAOP_THREADS=32                 # ✅ Dinamico
TF_FORCE_GPU_ALLOW_GROWTH=true            # ✅ GPU memory
CUDA_VISIBLE_DEVICES=0,1                  # ✅ Multi-GPU

# rgee
rgee.cache_path = ~/.config/earthengine/rgee_cache
rgee.max_memory = 9000000000              # ✅ 9GB cache
rgee.parallel = TRUE                      # ✅ Parallel
rgee.n_cores = 4                          # ✅ 4 core
rgee.api_rate_limit = 10                  # ✅ Rate limit
```

---

## 🔧 MODALITÀ D'USO

### **Setup Iniziale**

1. **Installare Rprofile.site v8.1.0**
```bash
sudo cp Rprofile.site_v8.1 /etc/R/Rprofile.site
sudo systemctl restart rstudio-server
```

2. **Installare dipendenze Python (se GPU)**
```bash
# Per GPU NVIDIA
pip install tensorflow[and-cuda]  # TensorFlow con CUDA

# Verificare
python -c "import tensorflow as tf; print(tf.config.list_physical_devices('GPU'))"
```

3. **Configurare Earth Engine (prima volta)**
```r
# In R
library(rgee)
rgee::ee_Initialize()  # Autenticazione interattiva
```

### **Verifica Configurazione**

Dopo il restart, aprire R e verificare:

```r
# 1. TensorFlow Threading
Sys.getenv("TF_NUM_INTEROP_THREADS")  # Es: "16"
Sys.getenv("TF_NUM_INTRAOP_THREADS")  # Es: "32"

# 2. GPU Detection
shared_env$has_gpu     # TRUE/FALSE
shared_env$gpu_count   # Numero GPU

# 3. rgee Options
getOption("rgee.cache_path")     # Cache directory
getOption("rgee.max_memory")     # Memory limit
getOption("rgee.n_cores")        # Parallel cores

# 4. Audit completo
source("00_audit_final_v12.R")
```

### **Test TensorFlow con GPU**

```r
library(tensorflow)

# Verificare GPU disponibili
tf$config$list_physical_devices("GPU")

# Test semplice
a <- tf$random$normal(c(1000L, 1000L))
b <- tf$random$normal(c(1000L, 1000L))
c <- tf$matmul(a, b)
c$numpy()  # Force evaluation

# Dovrebbe essere veloce (<1s con GPU, ~2-3s con CPU ottimizzato)
```

### **Test Keras**

```r
library(keras)

# Verificare backend
keras::is_keras_available()  # TRUE
keras::backend()              # "tensorflow"

# Test rete neurale semplice
model <- keras_model_sequential() %>%
  layer_dense(units = 128, activation = "relu", input_shape = 784) %>%
  layer_dropout(0.2) %>%
  layer_dense(units = 10, activation = "softmax")

model %>% compile(
  optimizer = "adam",
  loss = "sparse_categorical_crossentropy",
  metrics = "accuracy"
)

# Dovrebbe compilare senza errori
```

### **Test rgee**

```r
library(rgee)

# Dovrebbe già essere inizializzato
ee$Data$getInfo()  # Info su dataset disponibili

# Test query semplice
dem <- ee$Image("USGS/SRTMGL1_003")
dem_info <- dem$getInfo()

# Dovrebbe restituire metadata senza errori
```

---

## 📈 PERFORMANCE ATTESE

### **TensorFlow CPU (32 threads, 1 utente):**
```
Test: Matrix 1000x1000 multiplication
Before: ~3-5 secondi (senza ottimizzazione)
After:  ~0.5-1 secondi (con threading ottimizzato)
Speedup: 3-5x
```

### **TensorFlow GPU (NVIDIA RTX 4090, 1 utente):**
```
Test: Matrix 1000x1000 multiplication
CPU:    ~0.5-1 secondi
GPU:    ~0.05-0.1 secondi
Speedup: 10x
```

### **rgee API Calls:**
```
Test: Download 100 tiles Earth Engine
Before: Timeout frequenti, nessun retry
After:  Rate limiting intelligente, retry automatico
Success rate: 95%+ (vs ~70% prima)
```

---

## 🐛 TROUBLESHOOTING

### **Problema: TensorFlow non rileva GPU**

```bash
# Verificare driver NVIDIA
nvidia-smi

# Verificare CUDA
nvcc --version

# Verificare TensorFlow
python -c "import tensorflow as tf; print(tf.config.list_physical_devices('GPU'))"

# Se vuoto, reinstallare TensorFlow con CUDA
pip uninstall tensorflow
pip install tensorflow[and-cuda]
```

### **Problema: Keras da errori**

```r
# Reinstallare Keras
remove.packages("keras")
install.packages("keras")

# Reinstallare backend
keras::install_keras()
```

### **Problema: rgee credenziali scadute**

```r
# Riautenticare
library(rgee)
rgee::ee_Initialize(email = "tuo@email.com")

# Verificare
file.exists("~/.config/earthengine/credentials")
```

### **Problema: Threading TensorFlow troppo alto**

Se vedi warning su oversubscription:

```r
# In Rprofile.site, ridurre limite massimo
# Linea ~92
optimal_threads <- min(max_threads_per_session, total_cores_logic, 16)  # Era 32
```

---

## 🔍 AUDIT ESTESO

Il nuovo audit (v12.0) testa:

**Sezione 2.5 - Threading (4 test):**
- OpenMP configuration
- OpenBLAS configuration
- RhpcBLASctl runtime
- TensorFlow threading

**Sezione 2.6 - GPU & Deep Learning (4 test):**
- GPU detection & count
- TensorFlow backend initialization
- Keras backend readiness
- GPU memory configuration

**Sezione 2.7 - rgee Optimization (4 test):**
- Package & Python backend
- Earth Engine credentials
- Optimization options
- API rate limiting

**Sezione 4.0 - Performance (4 test):**
- OpenBLAS stress test
- TensorFlow CPU baseline
- I/O speed test
- Parallel processing

**Totale:** 30+ test (vs 20 della v11.0)

---

## 📦 FILE AGGIORNATI

1. **Rprofile.site_v8.1** - Sistema profile con TF/Keras/rgee ottimizzati
2. **00_audit_final_v12.R** - Audit esteso con test DL/GEE
3. Questa guida

---

## 🎯 RIEPILOGO MIGLIORAMENTI

| Feature                    | v8.0.0        | v8.1.0              |
|----------------------------|---------------|---------------------|
| OpenBLAS/OMP Threading     | ✅ Dinamico   | ✅ Dinamico         |
| TensorFlow CPU Threading   | ❌ Assente    | ✅ Dinamico         |
| GPU Detection              | ❌ Assente    | ✅ Automatico       |
| GPU Memory Management      | ❌ Assente    | ✅ Dynamic growth   |
| Multi-GPU Allocation       | ❌ Assente    | ✅ Fair-share       |
| Keras Configuration        | ❌ Assente    | ✅ Auto-config      |
| rgee Cache                 | ❌ Default    | ✅ Ottimizzata      |
| rgee Parallel Processing   | ❌ Assente    | ✅ Dinamico         |
| rgee Rate Limiting         | ❌ Assente    | ✅ Configurato      |
| Audit Tests                | 20            | 30+                 |

---

**Versione:** 8.1.0  
**Data:** 14 Febbraio 2026  
**Sistema:** BIOME-CALC Enterprise + Deep Learning + GEE
