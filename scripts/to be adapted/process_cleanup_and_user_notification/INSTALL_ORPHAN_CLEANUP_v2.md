# BIOME-CALC — R Orphan Worker Cleanup System v2.0

## Problema

Quando una sessione RStudio Server (OSS) crasha, viene killata, o l'utente chiude il browser
durante un job parallelo, i worker R restano attivi come processi orfani.
R non ha nessun meccanismo integrato per gestirli.

## Worker supportati (v2.0)

| Backend R | Signature processo | Rilevato |
|---|---|---|
| `parallel::makeCluster()` PSOCK | `parallel:::.workRSOCK` | ✓ |
| `future::multisession` / `parallelly` | `parallelly:::.workRSOCK` | ✓ |
| `callr::r_bg()` | `callr::` | ✓ |
| PSOCK generico (altri package) | `workRSOCK` | ✓ |

## Componenti

| File | Funzione |
|---|---|
| `cleanup_r_orphans.sh` | Cron job: trova e termina worker orfani, logga per utente e tipo |
| `notify_r_orphans.sh` | Invia email agli utenti con breakdown per tipo di worker |
| `r_orphan_report.sh` | Report sysadmin: orfani attivi, classifica utenti, storico per tipo |

## Installazione

```bash
sudo cp cleanup_r_orphans.sh /usr/local/bin/
sudo cp notify_r_orphans.sh  /usr/local/bin/
sudo cp r_orphan_report.sh   /usr/local/bin/
sudo chmod +x /usr/local/bin/cleanup_r_orphans.sh
sudo chmod +x /usr/local/bin/notify_r_orphans.sh
sudo chmod +x /usr/local/bin/r_orphan_report.sh

sudo mkdir -p /var/log/r_orphan_cleanup/notifications

# Cron: cleanup ogni 5 minuti
echo '*/5 * * * * root /usr/local/bin/cleanup_r_orphans.sh' | sudo tee /etc/cron.d/cleanup_r_orphans

# Cron: notifica email giornaliera alle 8:00 (opzionale)
echo '0 8 * * * root /usr/local/bin/notify_r_orphans.sh' | sudo tee /etc/cron.d/notify_r_orphans
```

## Configurazione

In `cleanup_r_orphans.sh`:
```bash
MIN_AGE_SECONDS=120   # Worker < 2 min ignorati (evita false positive)
```

In `notify_r_orphans.sh`:
```bash
MAIL_DOMAIN="live.unibo.it"
ADMIN_EMAIL="Lifewatch_Biome_internal@live.unibo.it"
```

## Come rileva gli orfani

### Caso 1: PPID = 1 (classico)
Quando `rsession` muore, il kernel reparenta i figli a PID 1.

### Caso 2: Parent chain morta (v2.0)
`future::multisession` via `parallelly` può creare worker con parent intermedio.
Lo script risale la catena fino a `rsession` — se non esiste più, il worker è orfano.

### Protezione anti-false-positive
- Worker attivi da meno di `MIN_AGE_SECONDS` vengono ignorati
- Worker il cui parent `rsession` è ancora vivo vengono ignorati

## Formato log

```
2026-02-17 10:30:05 | KILLED | type=parallel::PSOCK | user=martina.livornese2 | pid=1581093 | ...
2026-02-17 10:35:02 | KILLED | type=future::multisession | user=riccardo.testolin | pid=1590412 | ...
2026-02-17 10:35:02 | SUMMARY | Orphans killed this run: 2
```

## Uso

```bash
sudo r_orphan_report.sh                    # Report completo
sudo cleanup_r_orphans.sh                  # Cleanup manuale
tail -50 /var/log/r_orphan_cleanup/cleanup.log  # Log recente
```
