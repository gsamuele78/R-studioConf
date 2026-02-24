# 📘 Manuale Utente: BIOME-CALC System (v5.5)
*Ottimizzazione Scientifica e Gestione Risorse Trasparente*
Benvenuto nel sistema di calcolo BIOME-CALC. Questa piattaforma è stata progettata per gestire dataset massivi e analisi avanzate in modo intelligente e automatico.
## 🚀 1. Caricamento Dati Ottimizzato (Parquet)
Il sistema monitora costantemente i file dello storage. Non devi cambiare il tuo modo di lavorare:
- **Trasparenza:** Usa i classici comandi read.csv() o fread().
- **Velocità:** Se vedi l'icona 🚀 nella console, il sistema ha trovato una versione Parquet del tuo file.
- **Vantaggio:** Il caricamento è fino a 10 volte più veloce e i dati (coordinate, date, numeri) sono già nel formato corretto per l'analisi.
## 📊 2. Gestione Intelligente della RAM
La memoria del server (350GB) è condivisa. Il sistema assegna a ogni utente una Quota Fair dinamica.
- **Messaggio Iniziale:** All'avvio di RStudio vedrai quanta RAM ti è stata assegnata (es. Quota RAM: 120GB).
- **Notifiche Live:** Se un collega entra nel sistema, riceverai una notifica: 🔔 BIOME-INFO. La tua quota si ridurrà leggermente per far spazio al nuovo arrivato.
- **Autopulizia:** Il sistema esegue gc() (Garbage Collection) dopo ogni comando per liberare la memoria non utilizzata.
## ⚙️ 3. Parallelizzazione e Core CPU
Non è necessario configurare i core per i calcoli paralleli:
- **Auto-Configurazione:** I pacchetti terra, sf e future sanno già quanti core usare senza rallentare i colleghi.
- **Sicurezza:** 2 Core sono sempre riservati al sistema per garantire che il login sia sempre veloce.

## 🤖 Caso d'uso per l'AI Locale

**Come usare l'Assistente AI locale:**
Il sistema integra un'intelligenza artificiale privata. Per usarla:
1. Carica la libreria: *library(chattr)*
2. Apri il pannello laterale: **Addins -> chattr -> Chat with LLM.**
3. Puoi chiedere: *"Come posso convertire questo dataframe in un oggetto terra?" o "Ottimizza questo ciclo for".*
**Nota:** I tuoi dati non escono mai dal server **biome-calc0X**.



## 📂 Casi d'Uso Pratici
### Caso A: Caricamento Dataset Massivo (Lazy Loading)
Se devi analizzare un file enorme (es. 100GB) ma ti servono solo poche righe:

```
R
# Apre il file senza caricarlo in RAM
ds <- open_data("grande_dataset.csv") 

# Filtra solo i dati che ti servono
mio_subset <- ds %>% 
  filter(Specie == "Fagus sylvatica") %>% 
  collect() # Solo ora i dati vengono scaricati in RAM
```


### Caso B: Analisi Raster con terra
Il sistema usa un **RAMDisk da 100GB** per i file temporanei. I tuoi calcoli spaziali non useranno la rete 1Gbps, rendendo tutto estremamente fluido.
```
R
library(terra)
r <- rast("mappa_climatica.tif")
# Il calcolo avverrà nel RAMDisk ultra-veloce /tmp
risultato <- app(r, fun = "mean")
``` 

### Caso C: Analisi Spaziale con terra
Il sistema configura automaticamente terra per usare il **RAMDisk (100GB)** per i file temporanei, evitando di intasare la rete.
```
R
library(terra)
# Il sistema ha già impostato: terraOptions(tempdir = "/tmp", cores = X)
r <- rast("grande_raster.tif")
risultato <- buffer(r, 1000) # Sarà velocissimo grazie al RAMDisk
```


### Caso D: Deep Learning con keras
Ideale per classificazione di immagini o serie temporali.
```
R
library(keras)
# Il sistema ha già configurato l'ambiente Python in /opt/r-geospatial
model <- keras_model_sequential() %>% ...
# Il caricamento dati da Parquet (trasparente) satura la GPU/CPU senza colli di bottiglia
```


### Caso E: Filtrare milioni di righe (Lazy Loading)
Se un file è troppo grande per la **RAM (es. 200GB di CSV)**, usa il nuovo comando globale:
```
R
# Apre il file senza caricarlo
ds <- open_data("dataset_globale.csv") 

# Filtra solo i dati per l'Italia e scarica in RAM solo quelli
df_italia <- ds %>% 
  filter(country == "Italy") %>% 
  collect()
```
