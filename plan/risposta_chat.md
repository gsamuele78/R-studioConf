Sì: questo cambia parecchio la diagnosi.

Il tuo codice **non crasha** nel nuovo ambiente numerico quando lo esegui fuori da RStudio con `Rscript`. Quindi il problema **non è `geo_distmat`**, **non è `solve()` in sé**, e nemmeno un segfault riproducibile di OpenBLAS/LAPACK a livello generale. Il problema è molto più probabilmente nella **sessione RStudio/Posit Workbench (`rsession`)** o nel modo in cui quella sessione interagisce con il tuo ambiente. I log che hai mostrato dicono solo che “la sessione precedente è terminata in modo anomalo”, senza riportare un errore R specifico, che è compatibile con un crash della sessione piuttosto che del codice. ([CRAN][1])

La conclusione pratica è:

* **in terminale (`Rscript`) il chunk va**
* **in RStudio la sessione muore**
* quindi **il problema è RStudio/rsession o qualcosa caricato in quella sessione**, non il chunk isolato

E c’è un secondo punto importante: il manuale di R segnala che BLAS/LAPACK esterni possono dare risultati numerici non identici e, in codice threaded o con librerie esterne, possono anche contribuire a errori difficili da tracciare. Però nel tuo caso, visto che `Rscript` completa tutto, la parte “numerica pura” non è il colpevole principale. ([CRAN][1])

## Cosa significa davvero

Il vecchio ragionamento “forse il nuovo OpenBLAS fa crashare `solve()`” non regge più bene, perché il test fuori da RStudio è passato fino in fondo.

Quindi i sospetti più forti diventano questi:

1. **stato della sessione RStudio corrotto o pesante**
2. **workspace restore / history / environment restore**
3. **qualche package caricato in RStudio che in `Rscript` non c’è**
4. **bug di `rsession`/Workbench con il nuovo stack**

## Cosa fare adesso, in ordine

### 1. Prova il chunk in una sessione RStudio completamente pulita

Apri RStudio e prima di fare qualunque cosa:

* non caricare workspace salvati
* non fare restore di `.RData`
* non caricare il tuo progetto se quel progetto apre roba automaticamente

Se puoi, crea una sessione “clean” o apri una cartella vuota e poi fai solo:

```r
geo_distmat <- readRDS("geo_distmat.rds")

sapply(1:50, function(i) {
  rho_scaling <- max(geo_distmat)/i
  r_spatial <- exp(-geo_distmat/rho_scaling)
  isSymmetric((1/0.001) * solve(r_spatial))
})
```

Se così non crasha, il problema è nell’ambiente del progetto/sessione, non nel chunk.

### 2. Disattiva restore automatico

In RStudio/Workbench, controlla che non stia tentando di ripristinare la sessione precedente. Il fatto che nel log compaia ripetutamente:

```text
The previous R session terminated abnormally
```

suggerisce che `rsession` si riavvia dopo una morte anomala. Non ti sta dicendo la causa, solo l’effetto.

### 3. Pulisci lo stato locale di RStudio

Hai già trovato i log in:

```bash
~/.local/share/rstudio/log/
```

Nella stessa area di solito c’è anche stato/session metadata. Senza toccare roba di sistema, la prova più utile è far ripartire RStudio con stato utente pulito. Prima chiudi RStudio, poi fai una copia di backup della cartella locale di stato e rinominala:

```bash
mv ~/.local/share/rstudio ~/.local/share/rstudio_backup
```

Poi riapri RStudio.
Se il problema sparisce, il colpevole era nello stato locale della sessione.

### 4. Confronta “Rscript” e “RStudio” sullo stesso file minimale

Fai un file `test_solve.R` come hai già fatto, e in RStudio esegui solo:

```r
source("test_solve.R")
```

Se:

* `Rscript test_solve.R` funziona
* `source("test_solve.R")` in RStudio crasha

allora hai una riproduzione molto forte di bug/session issue da mostrare all’admin.

## La lettura critica dei tuoi appunti iniziali

A questo punto c’è anche un’altra cosa da dire in modo netto: il fatto che il test dia `FALSE` fino a 16 e `TRUE` da 17 in poi **non sta identificando il crash**. Quello funziona sia in `Rscript` sia, presumibilmente, in ambiente pulito. Quindi il tuo criterio empirico sul cutoff può anche restare, ma **non spiega il crash di RStudio**.

Il crash è un problema separato.

## Cosa direi all’admin, in modo preciso

Puoi scrivere una cosa del genere:

> A minimal script running `solve()` on a 247x247 matrix completes successfully with `Rscript`, but the same code can terminate the RStudio/Workbench `rsession` abnormally. User-level `rsession` logs only report “The previous R session terminated abnormally” without an R error. This suggests an `rsession`/Workbench issue rather than a failure of the R code itself.

Questo è molto più forte di “mi crasha RStudio”.

## Diagnosi finale, con quello che hai ora

La diagnosi migliore è:

**il nuovo server non ha un problema generale con il chunk; il problema è specifico della sessione RStudio/rsession, non del codice eseguito da R in modalità batch.** Il fatto che R usi BLAS/LAPACK esterni resta rilevante per il contesto, ma non è più la spiegazione principale del crash, perché il test batch passa. ([CRAN][1])

Il prossimo passo migliore è provare una sessione RStudio davvero pulita e, se serve, azzerare lo stato locale di RStudio.

[1]: https://cran.r-project.org/doc/manuals/r-release/R-admin.html?utm_source=chatgpt.com "R Installation and Administration - CRAN - R Project"

