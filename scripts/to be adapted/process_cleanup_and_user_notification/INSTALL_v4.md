# BIOME-CALC — Orphan Process Cleanup System v4.0

## Cosa monitora

### Worker R nativi
| Tool R | Processo spawnato | Pattern |
|---|---|---|
| `parallel::makeCluster()` | `R --no-echo ...workRSOCK` | `parallel:::.workRSOCK` |
| `future::multisession` | `R --no-echo ...parallelly` | `parallelly:::.workRSOCK` |
| `callr::r_bg()` | `R --no-echo ...callr` | `callr::r_bg` |
| `foreach + doParallel` | usa parallel PSOCK | `parallel:::.workRSOCK` |
| `furrr` | usa future | `parallelly:::` |
| `targets` | usa callr | `callr::` |
| `BiocParallel (SnowParam)` | R PSOCK | `BiocParallel` |
| `clustermq` | R via ZeroMQ | `clustermq` |
| `batchtools` | R via Rscript | `batchtools` |
| `snow` (legacy) | R via Rscript | `snowSOCK` |

### Python via reticulate
| Tool R | Processo spawnato | Pattern |
|---|---|---|
| `tensorflow` / `keras` | `python3 ...tensorflow` | `python.*tensorflow` |
| `keras` (standalone) | `python3 ...keras` | `python.*keras` |
| `rgee` | `python3 ...earthengine` | `python.*earthengine` |
| `torch` (R) via reticulate | `python3 ...torch` | `python.*torch` |
| `reticulate` (generico) | `python3` | `python.*reticulate` |

### Subprocess
| Tool | Processo | Pattern |
|---|---|---|
| `sf`, `terra`, `rgdal` | GDAL/OGR | `gdal`, `ogr2ogr` |
| Rscript workers generici | `Rscript` | `Rscript.*worker` |

### Cosa NON viene toccato
- `torch` (R nativo, non reticulate): usa thread C++ interni, non processi separati
- `data.table`: parallelismo via OpenMP thread, non processi
- `multicore` (fork): disabilitato su RStudio Server OSS, fallback a sequential
- Processi esclusi: `jupyter`, `code-server`, `rstudio-server`, `rserver`, `rsession`

## Aggiungere un nuovo pattern

Modifica `r_orphan_cleanup.conf`, array `ORPHAN_PATTERNS`:

```bash
ORPHAN_PATTERNS=(
    # ... pattern esistenti ...

    # Aggiungi il tuo:
    "python.*my_new_tool|MyNewTool (Python)"
    "Rscript.*my_package|my_package (R)"
)
```

Il formato e': `"GREP_REGEX|LABEL_LEGGIBILE"`

Dopo la modifica, testa con:
```bash
sudo /usr/local/custom/rstudio/script/r_orphan_report.sh
```

---

## Struttura file

```
/usr/local/custom/rstudio/
├── conf/
│   └── r_orphan_cleanup.conf         # Configurazione + pattern
├── script/
│   ├── send_email.sh                 # GIA' PRESENTE
│   ├── cleanup_r_orphans.sh          # Cron: kill orfani
│   ├── notify_r_orphans.sh           # Cron: email utenti
│   └── r_orphan_report.sh            # Report sysadmin
```

## Installazione

```bash
# Directory
sudo mkdir -p /usr/local/custom/rstudio/conf
sudo mkdir -p /var/log/r_orphan_cleanup/notifications

# Copia file
sudo cp r_orphan_cleanup.conf /usr/local/custom/rstudio/conf/
sudo cp cleanup_r_orphans.sh  /usr/local/custom/rstudio/script/
sudo cp notify_r_orphans.sh   /usr/local/custom/rstudio/script/
sudo cp r_orphan_report.sh    /usr/local/custom/rstudio/script/

# Permessi
sudo chmod +x /usr/local/custom/rstudio/script/cleanup_r_orphans.sh
sudo chmod +x /usr/local/custom/rstudio/script/notify_r_orphans.sh
sudo chmod +x /usr/local/custom/rstudio/script/r_orphan_report.sh

# Cron
echo '*/5 * * * * root /usr/local/custom/rstudio/script/cleanup_r_orphans.sh' \
  | sudo tee /etc/cron.d/cleanup_r_orphans
echo '0 8 * * * root /usr/local/custom/rstudio/script/notify_r_orphans.sh' \
  | sudo tee /etc/cron.d/notify_r_orphans
echo '0 7 * * 1 root /usr/local/custom/rstudio/script/r_orphan_report.sh --mail' \
  | sudo tee /etc/cron.d/r_orphan_report
```

## Configurazione

Tutto in `/usr/local/custom/rstudio/conf/r_orphan_cleanup.conf`:

```bash
# SMTP (usa lo stesso relay di send_email.sh)
SMTP_HOST="smtprelay.unibo.it"
SMTP_PORT="25"
SENDER_EMAIL="biome-calc@personale.dir.unibo.it"
DNS_SERVERS="137.204.25.71,137.204.25.77,8.8.8.8"

# Destinatari
MAIL_DOMAIN="studio.unibo.it"     # <-- verificare
ADMIN_EMAIL="Lifewatch_Biome_internal@live.unibo.it"

# Soglie
MIN_AGE_SECONDS=120               # ignora processi < 2 min
```

## Test

```bash
# Report a schermo
sudo /usr/local/custom/rstudio/script/r_orphan_report.sh

# Report via email
sudo /usr/local/custom/rstudio/script/r_orphan_report.sh --mail

# Cleanup manuale
sudo /usr/local/custom/rstudio/script/cleanup_r_orphans.sh

# Verifica log
tail -30 /var/log/r_orphan_cleanup/cleanup.log
```

## Come funziona il rilevamento Python

Quando un utente usa tensorflow/keras/rgee in R, la catena dei processi e':

```
rsession (utente)
  └── R (sessione interattiva)
        └── python3 -c "import tensorflow..."   ← spawned da reticulate
```

Se rsession muore:
```
init (PID 1)                      ← kernel reparenta qui
  └── python3 -c "import tensorflow..."   ← ORFANO
```

Lo script risale la catena fino a 4 livelli per gestire
catene tipo rsession → R → python → python subprocess.

Se a qualsiasi livello trova rsession/R ancora vivo, il processo
e' legittimo e viene ignorato.
