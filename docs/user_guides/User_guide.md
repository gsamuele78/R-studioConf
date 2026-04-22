🌿 Guida Ufficiale: Calcolo ad Alte Prestazioni (HPC) sul Server BIOME-CALC
Benvenuti sul nuovo server BIOME-CALC! Questa macchina è stata ingegnerizzata per offrirvi 450 GB di RAM e 128 processori per spingere al massimo i vostri modelli botanici, ecologici e spaziali.

Essendo un server di livello enterprise (HPC), si comporta in modo diverso dal vostro computer portatile o dai server di vecchia generazione. Questa guida vi spiegherà come strutturare il vostro codice R per farlo letteralmente "volare", evitando disconnessioni, crash e blocchi.

1. Gestione Sessioni e Prevenzione Crash (L'errore "Aw, Snap!")
Sui vecchi sistemi, chiudendo RStudio, veniva salvato in automatico un file nascosto chiamato .RData contenente tutto l'ambiente di lavoro. Lavorando con Big Data, questo file può raggiungere svariati Gigabyte. Al vostro login successivo, RStudio cercherà di caricare tutti quei Giga nel vostro browser, facendolo collassare (il classico errore "Aw, Snap!" o "Error Code 4" su Chrome).

Come funziona sul nuovo server:

Nessun salvataggio automatico: Abbiamo disabilitato la creazione automatica del .RData.

Persistenza per 48 ore: Se chiudete il browser, la vostra sessione rimarrà attiva e intatta nella RAM del server per 2 giorni (48 ore). Dopo questo tempo di inattività, il server farà pulizia per liberare risorse per i colleghi.

La Best Practice: Usate SEMPRE il comando saveRDS(miei_risultati, "file.rds") alla fine dei vostri script per salvare solo ciò che vi serve realmente.

2. La Regola d'Oro del Calcolo Parallelo ("Il Cuoco e il Forno")
Molti di voi usano funzioni come parLapply o foreach per parallelizzare i calcoli. A volte questo causa un crash immediato del processo (es. l'errore unserialize(node$con) o Segmentation Fault).

Questo accade con pacchetti come nimble, terra, rstan, TMB, o keras, perché sotto il cofano creano oggetti in linguaggio C++ (che sono puntatori alla memoria fisica, non semplici dati).

Per capire l'errore, usiamo un'analogia:

La sessione R principale è il Cuoco.

I dati e il codice testuale sono la Ricetta.

I worker paralleli (il cluster) sono i Forni.

Compilare un modello o caricare un Raster equivale a Cuocere la Torta.

Una rete parallela non può trasportare "torte già cotte" (puntatori C++ attivi). Se provate a passare un modello compilato dal Cuoco ai Forni, il sistema va in protezione e "uccide" il processo per sicurezza.

🚨 LA REGOLA D'ORO: Dovete passare ai Forni solo la Ricetta e gli Ingredienti grezzi. Ogni Forno deve compilare il codice o caricare il file da solo al suo interno.

Per aiutarvi, il server ha una funzione speciale pre-caricata chiamata biome_make_cluster(). Sostituisce la classica makeCluster() e ottimizza in automatico l'uso del disco ultra-veloce (NVMe) e della CPU, prevenendo blocchi di sistema.

3. Template Pratici per Pacchetto
Ecco come applicare la "Regola d'Oro" ai pacchetti più usati nel nostro dipartimento. Copiate questi template!

A. Modelli MCMC (pacchetto nimble)
Sbagliato: Compilare nimbleModel() fuori e passarlo a parLapply.
Giusto: Compilare tutto DENTRO la funzione del worker.

```
library(parallel)

# 1. Definiamo la funzione per il worker (Il "Forno")
run_mcmc_worker <- function(chain_id, dati_grezzi, codice_testo, inits) {
  library(nimble) 
  
  # CRITICO: Il modello viene costruito e compilato localmente dal worker!
  modello_locale <- nimbleModel(code = codice_testo, data = dati_grezzi, inits = inits[[chain_id]])
  modello_compilato <- compileNimble(modello_locale) 
  
  mcmc <- buildMCMC(modello_compilato)
  Cmcmc <- compileNimble(mcmc, project = modello_locale)
  
  campioni <- runMCMC(Cmcmc, niter = 5000)
  return(campioni) # Restituiamo solo numeri!
}

# 2. Lancio parallelo con il cluster ottimizzato del server
N_cluster <- biome_make_cluster(4) 
risultati <- parLapply(cl = N_cluster, X = 1:4, fun = run_mcmc_worker, 
                       dati_grezzi = miei_dati, codice_testo = mio_codice, inits = lista_inits)
stopCluster(N_cluster)
```
B. Dati Spaziali (pacchetto terra)
I raster sono puntatori C++. Non passate l'oggetto SpatRaster via rete!

Soluzione 1 (Migliore): Passare il percorso del file.

```
worker_spaziale <- function(percorso_file) {
  library(terra)
  mio_raster <- rast(percorso_file) # Il worker lo carica dal disco!
  return(global(mio_raster, "mean", na.rm=TRUE))
}
```
Soluzione 2: Usare wrap() se il raster è in RAM.

```
# Nella sessione principale: "Imballiamo" il raster
raster_imballato <- wrap(mio_raster_gigante)

worker_spaziale <- function(raster_pacchetto) {
  library(terra)
  # Nel worker: "Sballiamo" il raster per riconnetterlo al C++ locale
  raster_vero <- unwrap(raster_pacchetto)
  return(mean(values(raster_vero)))
}
```

C. Cicli Paralleli (pacchetto doSNOW / foreach)
Valgono le stesse identiche regole: la compilazione va dentro il blocco %dopar%.

```
library(foreach)
library(doSNOW)

N_cluster <- biome_make_cluster(4)
registerDoSNOW(N_cluster)

# Impostiamo la progress bar
pb <- txtProgressBar(max = 4, style = 3)
opzioni_snow <- list(progress = function(n) setTxtProgressBar(pb, n))

risultati <- foreach(i = 1:4, .options.snow = opzioni_snow, .packages = c("nimble")) %dopar% {
  # La compilazione C++ DEVE avvenire qui dentro!
  modello <- compileNimble(nimbleModel(mio_codice, miei_dati, inits = inits[[i]]))
  return(runMCMC(modello, niter = 1000))
}
close(pb)
stopCluster(N_cluster)
```

D. Machine Learning (pacchetto keras / tensorflow)
I modelli Keras non possono viaggiare in rete. Inoltre, TensorFlow tende a "mangiare" tutta la CPU bloccando il server.

```
train_keras_worker <- function(learning_rate, dati_x, dati_y) {
  library(keras)
  library(tensorflow)
  
  # FRENO CPU: Limitiamo TensorFlow a 2 thread per worker
  tf$config$threading$set_intra_op_parallelism_threads(2L)
  tf$config$threading$set_inter_op_parallelism_threads(2L)
  
  # Costruiamo e addestriamo la rete qui dentro...
  modello <- keras_model_sequential() %>% layer_dense(units = 64, input_shape = ncol(dati_x))
  modello %>% compile(optimizer = optimizer_adam(learning_rate), loss = "mse")
  modello %>% fit(x = dati_x, y = dati_y, epochs = 10, verbose = 0)
  
  # SALVATAGGIO: Non restituite il 'modello'. Salvatelo e restituite il nome file!
  nome_file <- paste0(Sys.getenv("TMPDIR"), "/modello_lr_", learning_rate, ".h5")
  save_model_hdf5(modello, nome_file)
  
  return(nome_file)
}
```
4. Grafici in Background (La sindrome del "Pittore Bendato")
Quando lanciate un calcolo parallelo o un lavoro in background, quei processi non hanno uno schermo (sono "headless"). Se il vostro script finisce con plot(dati) o print(mio_ggplot), il server ignorerà il comando o andrà in errore, e il grafico andrà perduto.

Soluzione: Costringete R a stampare l'immagine su un file fisico.
Se usate ggplot2:

```
mio_grafico <- ggplot(dati, aes(x, y)) + geom_point()
ggsave(filename = "risultato.png", plot = mio_grafico, width = 8, height = 6)
```
Se usate Base R:
```
png("risultato.png", width = 800, height = 600)
plot(dati)
dev.off() # IMPORTANTE: chiude e salva il file!
```

5. Come lanciare analisi lunghe senza bloccare il PC
Se il vostro script impiega 10 ore a girare, NON eseguitelo premendo "Run" nella console. Se il vostro PC va in standby o scende il Wi-Fi, il processo potrebbe morire.

Metodo A: RStudio Background Jobs (Consigliato per tutti)
In basso a sinistra in RStudio, di fianco alla scheda "Console", cliccate sulla scheda "Jobs".

Cliccate su "Start Local Job".

Selezionate il vostro script e premete Start.

Fatto! Il calcolo ora gira in sicurezza sul server. Potete chiudere RStudio, spegnere il PC e andare a casa. I risultati verranno salvati nell'ambiente al termine.

Metodo B: Livello Pro con tmux (Per utenti avanzati)
Il server supporta tmux, un "terminale indistruttibile".

Aprite la scheda "Terminal" in RStudio.

Digitate tmux e premete Invio (comparirà una banda verde in basso).

Lanciate lo script scrivendo: Rscript il_mio_script.R

Per lasciare il processo in background e uscire: premete Ctrl + B, poi rilasciate e premete D (Detach).

Per ritrovare il processo il giorno dopo, aprite il terminale e scrivete tmux attach.

(Nota: I processi lasciati in tmux o nei "Jobs" sono riconosciuti come legittimi dal server e non verranno mai interrotti dalla pulizia automatica).

📚 Appendice Tecnica: Fonti Ufficiali e Documentazione di Sistema
Per i ricercatori interessati a comprendere le fondamenta tecniche di queste linee guida, riportiamo di seguito i riferimenti alla documentazione ufficiale di R, dei pacchetti spaziali e del nuovo sistema operativo. Le pratiche descritte in questo documento non sono "workaround" locali, ma aderiscono agli standard di sviluppo ufficiali.

1. Perché i modelli MCMC e Raster crashano nei calcoli paralleli?
Il crash dei worker (es. Error in unserialize(node$con)) non è legato alla memoria del server, ma a un limite fisico di R documentato fin dalle prime versioni.

Documentazione Core di R (Funzione serialize): Il manuale ufficiale di R afferma esplicitamente: "External pointers and weak references cannot be serialized" (I puntatori esterni non possono essere serializzati). I modelli creati in C++ (nimble, rstan) sono puntatori esterni. È quindi vietato da R stesso inviarli via rete a un cluster parallelo.

Manuale Ufficiale di terra: La documentazione di terra (il pacchetto spaziale standard) dedica una sezione specifica al calcolo parallelo. Digitando ?wrap in R, si legge testualmente: "SpatRaster and SpatVector objects are pointers to C++ objects. You cannot pass them directly to nodes on a cluster... you must use wrap before sending them".

Manuale Ufficiale di nimble: Nel capitolo sulla parallelizzazione, il manuale indica che per usare parLapply, la funzione nimbleModel() e compileNimble() devono essere eseguite in ogni singolo nodo del cluster, non nell'ambiente principale.

2. Perché il Server uccide i processi invece di usare lo Swap?
Sui vecchi sistemi, un calcolo che superava la RAM disponibile causava il congelamento del server per giorni (a causa dello Swap Thrashing). BIOME-CALC utilizza il nuovo standard enterprise per l'High-Performance Computing.

Ubuntu 24.04 LTS e systemd-oomd: A partire dalle recenti versioni LTS, Canonical (l'azienda sviluppatrice di Ubuntu) ha attivato di default il demone systemd-oomd. Questo sistema monitora il PSI (Pressure Stall Information) del Kernel Linux (versione 6+).

La Policy Ufficiale: Se un processo genera una pressione tale da rischiare il congelamento del disco e della CPU (saturando lo Swap), l'OOM-killer interviene e termina il processo prima che il server si blocchi. Questo garantisce che un singolo script errato non distrugga il lavoro di tutti gli altri utenti connessi.

3. Perché l'aggiornamento a Ubuntu 24.04 era obbligatorio?
Il passaggio a un sistema operativo che usa OOM-killer aggressivi era inevitabile per poter utilizzare le ultime tecnologie statistiche.

R 4.4 / 4.5 e C++ Moderno: Le nuove versioni di R e dei pacchetti spaziali/machine learning richiedono compilatori C++17/C++20 e versioni aggiornate della libreria di sistema glibc (versione 2.35+). Queste librerie non sono supportate sui vecchi sistemi (come Ubuntu 18.04 o 20.04).

Posit (RStudio) Release 2026: Le versioni moderne di RStudio Server seguono matrici di supporto molto rigide per ragioni di sicurezza. Posit ha terminato il supporto per i vecchi sistemi operativi. Mantenere l'hardware aggiornato era l'unico modo per fornirvi un ambiente sicuro, patchato e compatibile con i pacchetti CRAN più recenti.

📚 Appendice Tecnica: Verificare le limitazioni di R
Le regole sul calcolo parallelo (la "Regola del Cuoco e del Forno") non sono una restrizione del nuovo server, ma un limite nativo del linguaggio R e dei pacchetti spaziali. Potete verificare voi stessi queste regole interrogando la documentazione ufficiale direttamente dalla vostra console RStudio.

1. Il limite nativo di R: I Puntatori Esterni (?serialize)
Il crash dei worker in parallelo (es. Error in unserialize(node$con)) avviene quando R cerca di impacchettare i dati per spedirli ai vari core. I modelli statistici complessi sono "puntatori esterni" (indirizzi fisici della memoria RAM).

Verifica in RStudio: Digitate nella console il comando ?serialize

Cosa dice il manuale: Nella sezione Details, la documentazione ufficiale del motore R specifica che gli oggetti di riferimento non di sistema, tra cui esplicitamente "all external pointers and weak references" (tutti i puntatori esterni e le reference deboli), non vengono preservati durante il trasferimento di memoria. Se provate a spedirli a un cluster, il worker riceverà un puntatore vuoto e andrà in Segmentation Fault.

2. Pacchetto terra (Raster): Regola per il Parallelo (?wrap)
Il creatore del pacchetto terra ha implementato funzioni specifiche proprio perché i file spaziali soffrono di questo limite.

Verifica in RStudio: Digitate nella console ?wrap

Citazione Testuale del manuale: "SpatRaster and SpatVector objects are pointers to C++ objects. You cannot pass them directly to nodes on a cluster... you must use wrap before sending them."

Traduzione: Gli oggetti SpatRaster e SpatVector sono puntatori a oggetti C++. Non potete passarli direttamente ai nodi di un cluster... dovete usare la funzione wrap prima di inviarli.

3. Pacchetto nimble: Modelli MCMC in Cluster
Il team di sviluppo di nimble (UC Berkeley) ha una pagina web ufficiale dedicata esclusivamente agli errori nel calcolo parallelo.

Fonte Web: r-nimble.org/examples/parallelizing_NIMBLE.html

Citazione Testuale: "The key consideration is to ensure that all NIMBLE execution, including model building, is conducted inside the parallelized code." * Traduzione: La considerazione chiave è assicurarsi che tutta l'esecuzione di NIMBLE, inclusa la costruzione del modello, avvenga all'interno del codice parallelizzato (i nostri worker).

4. Il Sistema Operativo e l'OOM-Killer
Se sul vecchio server i calcoli errati non venivano bloccati istantaneamente, è perché il vecchio sistema operativo andava in Swap Thrashing (congelando le risorse per giorni senza risolvere il calcolo).
BIOME-CALC usa Ubuntu 24.04 LTS che integra il demone di sicurezza systemd-oomd. Se un processo cerca di leggere RAM non sua (C++ pointer fallito) o satura la memoria rischiando di bloccare il server per gli altri utenti, il Kernel Linux ora applica gli standard di sicurezza cloud e lo termina preventivamente per autodifesa.