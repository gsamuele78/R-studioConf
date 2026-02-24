# BIOME Archive Infrastructure — Admin Guide

> **Versione:** 1.0 · **Server:** biome-calc01 · **OS:** Ubuntu 24.04 LTS  
> **Realm AD:** `PERSONALE.DIR.UNIBO.IT` · **Storage:** `/mnt/ProjectStorage` · **Home NFS:** `/nfs/home`

---

## Indice

1. [Architettura generale](#1-architettura-generale)
2. [Prerequisiti e dipendenze](#2-prerequisiti-e-dipendenze)
3. [Deploy iniziale](#3-deploy-iniziale)
4. [Struttura file di configurazione](#4-struttura-file-di-configurazione)
5. [Workflow operativo completo](#5-workflow-operativo-completo)
6. [Gestione eventi](#6-gestione-eventi)
7. [Testing e validazione](#7-testing-e-validazione)
8. [Troubleshooting](#8-troubleshooting)
9. [Manutenzione periodica](#9-manutenzione-periodica)
10. [Reference rapido — comandi](#10-reference-rapido--comandi)

---

## 1. Architettura generale

### Componenti

```
biome-calc01
├── AD Join (Samba/Winbind)          ─ autenticazione utenti UniBo
├── NFS mount                         ─ /nfs/home (home utenti)
├── ProjectStorage mount              ─ /mnt/ProjectStorage (archivio dati)
│
├── /usr/local/custom/
│   ├── script/
│   │   ├── scopri_progetti_v5.sh     ─ ispettore AD → genera CSV
│   │   └── unibo_archive_manager_v23.sh  ─ archiver (legge CSV, gestisce storage)
│   ├── biome_supervisor_map.csv      ─ fonte di verità (produzione)
│   ├── biome_supervisor_map_YYYYMMDD.csv  ─ draft datati
│   ├── biome_email_pi.txt            ─ email pre-compilata per PI
│   └── logs/
│       ├── biome_audit.log           ─ log permanente eventi (append-only)
│       └── archive_run_YYYYMMDD_HHMMSS.log  ─ log singola esecuzione
```

### Flusso dati

```
AD UniBo (LDAP)
      │
      ▼ net ads search (keytab macchina)
scopri_progetti_v5.sh
      │ genera
      ▼
biome_supervisor_map_YYYYMMDD.csv  ──▶  revisione manuale admin/PI
      │ cp
      ▼
biome_supervisor_map.csv (produzione)
      │ legge
      ▼
unibo_archive_manager_v23.sh
      │ crea
      ▼
/mnt/ProjectStorage/<supervisor>/<project>/<user>/
/nfs/home/<user>/ARCHIVE_STORAGE/<project>  ──▶ symlink
```

### Formato CSV (8 colonne)

```
username,type,supervisor,project,date_start,date_end,source,note
```

| Colonna | Valori | Note |
|---|---|---|
| `username` | sAMAccountName UniBo | chiave primaria, non modificare |
| `type` | `ACTIVE` `TRANSFER` `PI` `ADMIN` `SKIP` | ACTIVE = default |
| `supervisor` | username PI oppure `_PI_` `_ADMIN_` `_SKIP_` | account locale/AD valido |
| `project` | stringa alfanumerica con trattini | max 40 car., niente spazi |
| `date_start` | `YYYY-MM-DD` | opzionale |
| `date_end` | `YYYY-MM-DD` oppure vuoto | vuoto = progetto attivo |
| `source` | `manual` `inferred_theme` `pi` `admin` `expired` `unknown` | tracciabilità |
| `note` | testo libero | ignorato dagli script |

**Compatibilità:** il formato a 7 colonne (V22, senza `type`) è ancora supportato — `type` viene inferito dal valore di `supervisor` (`_PI_`, `_ADMIN_`, ecc.).

---

## 2. Prerequisiti e dipendenze

### Sistema

```bash
# Verifica join AD
sudo net ads testjoin
# Expected: Join is OK

# Verifica winbind
sudo systemctl status winbind
wbinfo -u | grep -i biome | head -5

# Verifica mount NFS
mount | grep nfs
ls /nfs/home/ | head -5

# Verifica mount ProjectStorage
mount | grep ProjectStorage
ls /mnt/ProjectStorage/
```

### Strumenti richiesti

| Tool | Pacchetto | Uso |
|---|---|---|
| `net` | `samba-common-bin` | query LDAP AD |
| `wbinfo` | `winbind` | verifica utenti AD |
| `rsync` | `rsync` | sync dati al TRANSFER (opzionale) |
| `tree` | `tree` | `--list-tree` (opzionale) |
| `id` | coreutils | verifica utenti locali |

```bash
# Installa dipendenze mancanti
sudo apt-get install -y samba-common-bin winbind rsync tree
```

### Permessi richiesti

Gli script **devono girare come root** (`sudo`). Motivo: `net ads search -P` usa il keytab macchina (`/etc/krb5.keytab`, `0600 root:root`).

```bash
# Verifica keytab
sudo ls -la /etc/krb5.keytab
# -rw------- 1 root root ... /etc/krb5.keytab

sudo ls -la /var/lib/samba/private/secrets.tdb
# -rw------- 1 root root ... secrets.tdb
```

---

## 3. Deploy iniziale

### 3.1 Copia script

```bash
# Crea directory se non esiste
sudo mkdir -p /usr/local/custom/script
sudo mkdir -p /usr/local/custom/logs

# Copia script
sudo cp scopri_progetti_v5.sh       /usr/local/custom/script/
sudo cp unibo_archive_manager_v23.sh /usr/local/custom/script/

# Permessi
sudo chmod 700 /usr/local/custom/script/*.sh
sudo chown root:root /usr/local/custom/script/*.sh
```

### 3.2 Primo run — generazione CSV

```bash
# Genera il CSV draft con classificazione automatica
sudo /usr/local/custom/script/scopri_progetti_v5.sh

# Output atteso:
# === BIOME AD GROUP INSPECTOR V5 (multi-project) - ...
# [MATCH]   manuele.bazzichetto         → supervisor:francesco.sabatini4  ...
# [PI]      duccio.rocchini             | ...
# [?????]   diletta.santovito2          | ...
# ...
# CSV draft: /usr/local/custom/biome_supervisor_map_20250219.csv
```

### 3.3 Revisione CSV draft

```bash
# Apri il draft
sudo nano /usr/local/custom/biome_supervisor_map_YYYYMMDD.csv

# Operazioni tipiche:
# 1. Rinomina colonna project con nomi reali (es. BIOME_General → PRIN2022-Sabatini)
# 2. Risolvi righe _UNKNOWN_ dopo conferma dai PI
# 3. Aggiungi colonna type se necessario (default ACTIVE se omessa)
# 4. Aggiungi righe extra per utenti multi-progetto
```

**Checklist revisione CSV:**

- [ ] Nessuna riga con `supervisor=_UNKNOWN_`
- [ ] Tutti i project name seguono le regole di nomenclatura (no spazi)
- [ ] `date_start` compilato almeno per i progetti ACTIVE
- [ ] PI e admin correttamente classificati
- [ ] Nessun account CeSIA o esterno rimasto come ACTIVE

### 3.4 Promozione a produzione

```bash
# Verifica differenze rispetto al CSV corrente (se esiste già)
diff /usr/local/custom/biome_supervisor_map.csv \
     /usr/local/custom/biome_supervisor_map_YYYYMMDD.csv

# Backup del CSV di produzione corrente
sudo cp /usr/local/custom/biome_supervisor_map.csv \
        /usr/local/custom/biome_supervisor_map.csv.bak_$(date +%Y%m%d)

# Promuovi il draft
sudo cp /usr/local/custom/biome_supervisor_map_YYYYMMDD.csv \
        /usr/local/custom/biome_supervisor_map.csv
```

### 3.5 Dry-run archiver

```bash
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh

# Output atteso (dry-run):
# [DRY-RUN] Nessuna modifica...
#
# [USER]    manuele.bazzichetto
#           [active]  PRIN2022-Sabatini    supervisor:francesco.sabatini4  [attivo]
#                     target: /mnt/ProjectStorage/francesco.sabatini4/PRIN2022-Sabatini/manuele.bazzichetto
#             [link-new] PRIN2022-Sabatini → /mnt/.../manuele.bazzichetto
# ...
# RIEPILOGO
#   Utenti ACTIVE    :  8
#   Record TRANSFER  :  0
#   PI/Admin/Skip    :  5
```

**Verifica output dry-run:**

- [ ] Numero utenti ACTIVE coerente con aspettative
- [ ] Tutti i path di destinazione sotto `/mnt/ProjectStorage`
- [ ] Nessun supervisor non trovato (`[WARN] supervisor '...' non trovato`)
- [ ] Nessun utente NOCSV inatteso

### 3.6 Applicazione

```bash
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Verifica stato post-apply
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --list-tree
```

---

## 4. Struttura file di configurazione

### 4.1 CSV produzione

```
/usr/local/custom/biome_supervisor_map.csv
```

Questo file è la **fonte di verità assoluta**. Qualsiasi modifica all'infrastruttura di archiviazione parte da una modifica a questo file. Non modificare mai direttamente le directory in ProjectStorage senza aggiornare anche il CSV.

### 4.2 KNOWN_ENTRIES nello script scopri_progetti

La sezione `KNOWN_ENTRIES` in `scopri_progetti_v5.sh` è il backup del CSV nel codice. Mantenere allineati i due:

```bash
# Sintassi KNOWN_ENTRIES:
# KNOWN_ENTRIES["username"]="supervisor1:progetto1:inizio:fine|supervisor2:progetto2:inizio:fine"
# Separatore record: |
# Separatore campi: :
# date_end vuota = progetto attivo

KNOWN_ENTRIES["mario.rossi"]="prof.bianchi:PRIN2022-A:2022-01-01:2023-12-31|prof.verdi:RemoteSensing:2024-01-01:"
```

### 4.3 Audit log

```
/usr/local/custom/logs/biome_audit.log
```

File append-only. **Non cancellare mai.** Contiene la storia completa di tutti i TRANSFER, migrate e modifiche. Formato:

```
[2025-02-19 14:32:01] [TRANSFER] mario.rossi: vecchio→prof.verdi/RemoteSensing | note:cambio tema
[2025-02-19 14:32:01] [INFO] MIGRATE mario.rossi: /mnt/ProjectStorage/old/... → directory
```

### 4.4 TRANSFER_LOG.txt per utente

Ogni utente che ha subito un TRANSFER ha un file:

```
/nfs/home/<username>/ARCHIVE_STORAGE/TRANSFER_LOG.txt
```

Visibile all'utente stesso. Utile in caso di domande ("perché ho due cartelle?").

---

## 5. Workflow operativo completo

### 5.1 Nuovo collaboratore

```bash
# 1. Ricevi email dal PI con: username, supervisor, project, date_start
# 2. Aggiorna KNOWN_ENTRIES in scopri_progetti_v5.sh
# 3. Aggiungi riga al CSV di produzione direttamente (più veloce che rigenerare)

echo "mario.rossi,ACTIVE,prof.bianchi,PRIN2022-Sabatini,2025-03-01,,manual,\"nuovo dottorando\"" \
    | sudo tee -a /usr/local/custom/biome_supervisor_map.csv

# 4. Dry-run puntuale (filtra solo l'utente)
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh 2>&1 | grep -A5 "mario.rossi"

# 5. Apply
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# 6. Verifica
ls -la /mnt/ProjectStorage/prof.bianchi/PRIN2022-Sabatini/mario.rossi/
ls -la /nfs/home/mario.rossi/ARCHIVE_STORAGE/
```

### 5.2 Cambio supervisor

```bash
# 1. Aggiungi record TRANSFER nel CSV
# La riga ACTIVE precedente rimane (storico)

cat >> /usr/local/custom/biome_supervisor_map.csv << 'EOF'
mario.rossi,TRANSFER,prof.verdi,RemoteSensing-2025,2025-06-01,,manual,"cambio supervisor per fine PRIN2022"
EOF

# 2. Dry-run
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh 2>&1 | grep -A15 "TRANSFER"

# 3. Apply con o senza copia dati
# Senza copia dati (solo nuovo symlink):
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Con copia dati (rsync vecchia dir → nuova):
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply --sync-data

# 4. Verifica struttura post-transfer
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status | grep -A5 "mario.rossi"
# Expected:
# [OK]     mario.rossi
#   ✓ PRIN2022-A-TRASFERITO-20250601   → /mnt/.../prof.bianchi/PRIN2022-A/mario.rossi/
#   ✓ RemoteSensing-2025               → /mnt/.../prof.verdi/RemoteSensing-2025/mario.rossi/

# 5. Verifica audit log
grep "mario.rossi" /usr/local/custom/logs/biome_audit.log | tail -5
```

### 5.3 Progetto concluso

```bash
# Aggiorna date_end nel CSV (il system applicherà suffisso -CONCLUSO al symlink)
sudo sed -i 's/mario.rossi,ACTIVE,prof.bianchi,PRIN2022-Sabatini,2025-03-01,,/mario.rossi,ACTIVE,prof.bianchi,PRIN2022-Sabatini,2025-03-01,2025-12-31,/' \
    /usr/local/custom/biome_supervisor_map.csv

# Apply
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Verifica: il symlink deve ora chiamarsi PRIN2022-Sabatini-CONCLUSO
ls /nfs/home/mario.rossi/ARCHIVE_STORAGE/
```

### 5.4 Utente che lascia il gruppo

```bash
# 1. Cambia type a SKIP nel CSV
sudo sed -i 's/^mario.rossi,ACTIVE/mario.rossi,SKIP/' \
    /usr/local/custom/biome_supervisor_map.csv

# 2. L'account viene disabilitato da UniBo centralmente
# I dati rimangono in ProjectStorage intatti

# 3. Verifica che i dati siano accessibili al supervisor
ls -la /mnt/ProjectStorage/prof.bianchi/PRIN2022-Sabatini/mario.rossi/

# 4. Annotare sul CSV la data di fine
# mario.rossi,SKIP,prof.bianchi,PRIN2022-Sabatini,2025-03-01,2026-02-19,manual,"fine dottorato"
```

### 5.5 Rinnovo annuale CSV (consigliato ogni anno accademico)

```bash
# 1. Rigenerazione completa CSV da AD
sudo /usr/local/custom/script/scopri_progetti_v5.sh

# 2. Confronta con produzione per identificare nuovi utenti e cessati
diff /usr/local/custom/biome_supervisor_map.csv \
     /usr/local/custom/biome_supervisor_map_$(date +%Y%m%d).csv

# 3. Mergia le righe nuove nel CSV di produzione
# (NON sostituire: il CSV produzione ha colonne type e date_end più accurate)

# 4. Invia report ai PI con la lista degli utenti _UNKNOWN_ residui
cat /usr/local/custom/biome_email_pi.txt
```

---

## 6. Gestione eventi

### 6.1 Cambio nome progetto (rinomina)

```bash
# Scenario: PRIN2022-Sabatini → PRIN2022-Sabatini-WP2

# 1. Aggiorna CSV
sudo sed -i 's/PRIN2022-Sabatini,/PRIN2022-Sabatini-WP2,/g' \
    /usr/local/custom/biome_supervisor_map.csv

# 2. Rinomina directory fisica (opzionale, solo se dati già presenti)
sudo mv /mnt/ProjectStorage/prof.bianchi/PRIN2022-Sabatini \
        /mnt/ProjectStorage/prof.bianchi/PRIN2022-Sabatini-WP2

# 3. Apply: i symlink vengono aggiornati automaticamente
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# 4. Verifica
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status | grep "Sabatini"
```

### 6.2 Collaborazione multi-supervisore (progetto parallelo)

```bash
# Utente lavora su due progetti con due supervisor diversi
# Aggiungere semplicemente una seconda riga ACTIVE nel CSV

cat >> /usr/local/custom/biome_supervisor_map.csv << 'EOF'
mario.rossi,ACTIVE,duccio.rocchini,RemoteSensing-Collab,2025-01-01,,manual,"collaborazione con Rocchini"
EOF

sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Risultato in home utente:
# ~/ARCHIVE_STORAGE/
#   PRIN2022-Sabatini       → .../prof.bianchi/...
#   RemoteSensing-Collab    → .../duccio.rocchini/...
```

### 6.3 Report trasferimenti storici

```bash
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --transfer-report

# Filtra per utente specifico
grep "mario.rossi" /usr/local/custom/logs/biome_audit.log

# Filtra per supervisor
grep "prof.bianchi" /usr/local/custom/logs/biome_audit.log

# Tutti i transfer dell'anno corrente
grep "^\[$(date +%Y)" /usr/local/custom/logs/biome_audit.log | grep TRANSFER
```

---

## 7. Testing e validazione

### 7.1 Test AD connectivity

```bash
# Join AD
sudo net ads testjoin
# Expected: Join is OK

# Query utente campione
sudo net ads search "(sAMAccountName=manuele.bazzichetto)" \
    displayName title memberOf -P 2>/dev/null | head -20

# Verifica che keytab funzioni (non chiede password)
sudo net ads search "(sAMAccountName=test)" displayName -P
# Non deve restituire "kinit failed" o "NT_STATUS_ACCESS_DENIED"

# Winbind: risoluzione username
wbinfo -i manuele.bazzichetto
# Expected: manuele.bazzichetto:*:UIDNUMBER:GIDNUMBER:displayName:/nfs/home/...:/bin/bash
```

### 7.2 Test generazione CSV

```bash
# Run su singolo utente (modifica temporanea SOURCE_HOME per test)
sudo SOURCE_HOME=/tmp/test_home /usr/local/custom/script/scopri_progetti_v5.sh

# Verifica formato CSV output
# Deve avere esattamente le intestazioni corrette
head -15 /usr/local/custom/biome_supervisor_map_$(date +%Y%m%d).csv

# Conta colonne per ogni riga dati (deve essere 7 o 8)
grep -v "^#" /usr/local/custom/biome_supervisor_map_$(date +%Y%m%d).csv \
    | awk -F',' '{print NF, $0}' | sort -n | uniq -c | sort -rn | head
```

### 7.3 Test struttura directory

```bash
# Verifica che tutte le directory esistano e abbiano permessi corretti
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --list-tree

# Verifica permessi (deve essere 750, owner = supervisor)
find /mnt/ProjectStorage -maxdepth 3 -type d \
    | while read d; do
        perm=$(stat -c "%a %U %G" "$d")
        echo "$perm $d"
    done | grep -v "^750"   # mostra solo anomalie

# Verifica symlink nelle home (nessun BROKEN)
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status | grep BROKEN

# Test symlink manuale
for home in /nfs/home/*/ARCHIVE_STORAGE; do
    [ -d "$home" ] || continue
    for link in "$home"/*; do
        [ -L "$link" ] || continue
        target=$(readlink "$link")
        [ -d "$target" ] || echo "BROKEN: $link → $target"
    done
done
```

### 7.4 Test utente finale (dal punto di vista dell'utente)

```bash
# Simula accesso come utente
sudo -u mario.rossi ls -la ~/ARCHIVE_STORAGE/

# Verifica che l'utente possa scrivere nella propria directory
sudo -u mario.rossi touch ~/ARCHIVE_STORAGE/PRIN2022-Sabatini/test_write_$(date +%s)
# Expected: file creato senza errori

# Cleanup
sudo -u mario.rossi rm ~/ARCHIVE_STORAGE/PRIN2022-Sabatini/test_write_*

# Verifica che l'utente NON possa scrivere nella directory di un altro utente
sudo -u mario.rossi ls /mnt/ProjectStorage/prof.bianchi/PRIN2022-Sabatini/altro.utente/
# Expected: Permission denied (grazie ai permessi 750)
```

### 7.5 Test TRANSFER completo (ambiente staging)

```bash
# Setup test
TEST_USER="test.biome99"
TEST_SUP1="prof.bianchi"
TEST_SUP2="prof.verdi"

# Aggiungi utente ACTIVE al CSV di test
cat > /tmp/test_map.csv << EOF
# test
${TEST_USER},ACTIVE,${TEST_SUP1},Test-ProgettoA,2024-01-01,,manual,"test"
EOF

# Esegui archiver su CSV di test
SUPERVISOR_MAP=/tmp/test_map.csv \
sudo -E /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Verifica struttura iniziale
ls -la /mnt/ProjectStorage/${TEST_SUP1}/Test-ProgettoA/${TEST_USER}/
ls -la /nfs/home/${TEST_USER}/ARCHIVE_STORAGE/

# Aggiungi TRANSFER
cat >> /tmp/test_map.csv << EOF
${TEST_USER},TRANSFER,${TEST_SUP2},Test-ProgettoB,2025-01-01,,manual,"test transfer"
EOF

# Applica transfer
SUPERVISOR_MAP=/tmp/test_map.csv \
sudo -E /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Verifica: vecchio symlink rinominato, nuovo creato
ls -la /nfs/home/${TEST_USER}/ARCHIVE_STORAGE/
# Expected:
#   Test-ProgettoA-TRASFERITO-YYYYMMDD → /mnt/.../prof.bianchi/Test-ProgettoA/test.biome99/
#   Test-ProgettoB                     → /mnt/.../prof.verdi/Test-ProgettoB/test.biome99/

# Verifica audit log
grep "${TEST_USER}" /usr/local/custom/logs/biome_audit.log

# Cleanup test
sudo rm -rf /mnt/ProjectStorage/${TEST_SUP1}/Test-ProgettoA/${TEST_USER}
sudo rm -rf /mnt/ProjectStorage/${TEST_SUP2}/Test-ProgettoB/${TEST_USER}
sudo rm -f /nfs/home/${TEST_USER}/ARCHIVE_STORAGE/Test-Progetto*
sudo rm -f /nfs/home/${TEST_USER}/ARCHIVE_STORAGE/TRANSFER_LOG.txt
rm /tmp/test_map.csv
```

### 7.6 Checklist pre-produzione

```
Deploy iniziale:
  [ ] sudo net ads testjoin → "Join is OK"
  [ ] sudo wbinfo -u restituisce utenti
  [ ] /nfs/home montato e accessibile
  [ ] /mnt/ProjectStorage montato e scrivibile da root
  [ ] scopri_progetti_v5.sh genera CSV senza errori
  [ ] CSV non contiene righe _UNKNOWN_ (o sono state accettate)
  [ ] dry-run archiver non mostra WARN supervisor non trovato
  [ ] dry-run mostra path corretti sotto /mnt/ProjectStorage
  [ ] --apply eseguito con successo
  [ ] --status non mostra BROKEN
  [ ] test scrittura da utente campione OK
  [ ] audit log creato in /usr/local/custom/logs/biome_audit.log
```

---

## 8. Troubleshooting

### 8.1 AD / LDAP

**Problema:** `net ads search` restituisce errore o nessun risultato

```bash
# Verifica join
sudo net ads testjoin

# Rinnova ticket kerberos macchina
sudo net ads kerberos renew -P

# Verifica raggiungibilità DC
ping 137.204.25.214
ldapsearch -H ldap://137.204.25.214 -x -s base "(objectClass=*)" 2>&1 | head -5

# Se il join è rotto
sudo net ads join -U admin_unibo@PERSONALE.DIR.UNIBO.IT
sudo systemctl restart winbind
```

**Problema:** `kinit failed` o `NT_STATUS_LOGON_FAILURE`

```bash
# Verifica keytab
sudo klist -k /etc/krb5.keytab

# Test autenticazione con keytab
sudo kinit -k -t /etc/krb5.keytab "BIOME-CALC01$@PERSONALE.DIR.UNIBO.IT"
sudo klist  # verifica ticket ottenuto

# Se scaduto o corrotto: rifare il join AD
sudo net ads join -U admin_unibo
sudo systemctl restart winbind smbd
```

**Problema:** attributi AD vuoti (nessun `manager`, nessun `managedBy`)

```
CAUSA NOTA: AD UniBo è puramente amministrativo. Gli attributi manager
e managedBy NON sono popolati per nessun utente o gruppo.
SOLUZIONE: usare il CSV manuale (biome_supervisor_map.csv) come
unica fonte di verità per le relazioni supervisor-utente.
```

**Problema:** gruppi AD non mostrano pattern tema

```bash
# Debug gruppi di un utente specifico
sudo net ads search "(sAMAccountName=USERNAME)" memberOf -P 2>/dev/null \
    | grep "^memberOf:" \
    | grep -oP '(?<=CN=)[^,]+'

# Se i gruppi sono troppo generici (solo Str00968-biome)
# → aggiungere manualmente l'utente a KNOWN_ENTRIES in scopri_progetti_v5.sh
```

### 8.2 Symlink

**Problema:** symlink BROKEN (target non esiste)

```bash
# Identifica tutti i symlink rotti
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status | grep BROKEN

# Per ogni symlink rotto, trova il target atteso nel CSV
grep "USERNAME" /usr/local/custom/biome_supervisor_map.csv

# Ricrea la directory mancante
sudo mkdir -p /mnt/ProjectStorage/SUPERVISOR/PROJECT/USERNAME
sudo chmod 750 /mnt/ProjectStorage/SUPERVISOR/PROJECT/USERNAME
sudo chown SUPERVISOR:SUPERVISOR /mnt/ProjectStorage/SUPERVISOR/PROJECT/USERNAME

# Riesegui archiver per aggiornare i symlink
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply
```

**Problema:** ARCHIVE_STORAGE è ancora un symlink singolo (legacy V21)

```bash
# Identifica utenti legacy
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status | grep LEGACY

# La migrazione automatica avviene alla prima esecuzione di --apply
# Il vecchio target viene preservato come LEGACY_YYYYMMDD dentro la nuova directory
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Verifica post-migrazione
ls -la /nfs/home/USERNAME/ARCHIVE_STORAGE/
# Expected: directory con symlink dentro (non più symlink singolo)
```

**Problema:** symlink punta al path sbagliato (vecchio supervisor)

```bash
# Rimuovi symlink errato manualmente
sudo rm /nfs/home/USERNAME/ARCHIVE_STORAGE/NOME_PROGETTO

# Aggiorna CSV con il supervisor corretto
sudo nano /usr/local/custom/biome_supervisor_map.csv

# Riesegui --apply
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply
```

### 8.3 Permessi

**Problema:** utente non riesce a scrivere in ARCHIVE_STORAGE/PROJECT

```bash
# Verifica ownership della directory in ProjectStorage
ls -la /mnt/ProjectStorage/SUPERVISOR/PROJECT/USERNAME/
# Expected: drwxr-x--- SUPERVISOR SUPERVISOR

# Verifica che l'utente sia nel gruppo corretto o che il supervisor
# abbia dato i permessi
# (la dir appartiene al supervisor, ma l'utente deve poter scrivere)

# Fix: cambia ownership alla directory utente (lo spazio è suo)
sudo chown -R USERNAME:USERNAME /mnt/ProjectStorage/SUPERVISOR/PROJECT/USERNAME/
sudo chmod 750 /mnt/ProjectStorage/SUPERVISOR/PROJECT/USERNAME/
```

**Problema:** lo script dice `[WARN] supervisor 'prof.bianchi' non trovato come account`

```bash
# Verifica che il supervisor esista come account locale o winbind
id prof.bianchi
# Se non trovato:
wbinfo -i prof.bianchi

# Se il supervisor non ha ancora fatto login (no home locale)
# Forzare la creazione tramite PAM o creare manualmente:
sudo mkhomedir_helper prof.bianchi

# Oppure verificare che il nome nel CSV sia corretto (typo?)
grep "prof.bianchi" /usr/local/custom/biome_supervisor_map.csv
```

### 8.4 CSV

**Problema:** CSV contiene caratteri Windows (CRLF)

```bash
# Identifica
file /usr/local/custom/biome_supervisor_map.csv
# Se restituisce "CRLF line terminators"

# Fix
sudo sed -i 's/\r//' /usr/local/custom/biome_supervisor_map.csv

# Verifica
file /usr/local/custom/biome_supervisor_map.csv
# Expected: "ASCII text"
```

**Problema:** riga CSV con numero di colonne sbagliato

```bash
# Mostra righe con numero di colonne anomalo
grep -v "^#" /usr/local/custom/biome_supervisor_map.csv \
    | awk -F',' 'NF < 6 || NF > 9 {print NR": "NF" colonne: "$0}'

# Le virgole nelle note devono essere in una cella tra doppi apici
# Errato:  mario.rossi,ACTIVE,prof.bianchi,PRIN2022,,,manual,nota con, virgola
# Corretto: mario.rossi,ACTIVE,prof.bianchi,PRIN2022,,,manual,"nota con, virgola"
```

**Problema:** utente appare come NOCSV ma è in AD

```bash
# Verifica che l'account sia accessibile via winbind
id USERNAME
wbinfo -i USERNAME

# Verifica che abbia una home in /nfs/home
ls -d /nfs/home/USERNAME/

# Se tutto ok ma manca dal CSV: aggiungere manualmente
echo "USERNAME,ACTIVE,supervisor,NomeProgetto,$(date +%Y-%m-%d),,manual,\"aggiunto manualmente\"" \
    | sudo tee -a /usr/local/custom/biome_supervisor_map.csv

sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply
```

### 8.5 rsync (--sync-data)

**Problema:** rsync fallisce durante TRANSFER

```bash
# Esegui rsync manualmente con output verbose
sudo rsync -av --dry-run \
    /mnt/ProjectStorage/VECCHIO_SUPERVISOR/VECCHIO_PROGETTO/USERNAME/ \
    /mnt/ProjectStorage/NUOVO_SUPERVISOR/NUOVO_PROGETTO/USERNAME/

# Errori comuni:
# "Permission denied" → verifica permessi sulla source
# "No space left"     → verifica spazio su /mnt/ProjectStorage
# "Connection refused" → se ProjectStorage è NFS remoto, verifica mount

# Verifica spazio disponibile
df -h /mnt/ProjectStorage

# Stima dimensione prima di copiare
du -sh /mnt/ProjectStorage/VECCHIO_SUPERVISOR/VECCHIO_PROGETTO/USERNAME/
```

### 8.6 NFS / Storage

**Problema:** `/mnt/ProjectStorage` non accessibile

```bash
# Verifica mount
mount | grep ProjectStorage
df -h /mnt/ProjectStorage

# Remonta
sudo umount /mnt/ProjectStorage
sudo mount /mnt/ProjectStorage
# oppure
sudo mount -a

# Verifica /etc/fstab
grep ProjectStorage /etc/fstab

# Se NFS: verifica il server NFS
showmount -e NFS_SERVER_IP
```

**Problema:** `/nfs/home` non accessibile o utenti senza home

```bash
# Verifica mount NFS
mount | grep /nfs/home
df -h /nfs/home

# Verifica che PAM crei le home al login (pam_mkhomedir)
grep mkhomedir /etc/pam.d/common-session
# Expected: session required pam_mkhomedir.so skel=/etc/skel/ umask=0022

# Creazione manuale home
sudo mkhomedir_helper USERNAME
```

---

## 9. Manutenzione periodica

### Giornaliera

```bash
# Verifica symlink rotti (da cron)
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status \
    | grep -E "BROKEN|LEGACY" | mail -s "[BIOME] Symlink anomalie" admin@biome.unibo.it
```

### Mensile

```bash
# 1. Verifica utenti cessati ancora come ACTIVE nel CSV
# Cerca account AD scaduti
while IFS=',' read -r uname type sup proj ds de src note; do
    [[ "$uname" =~ ^# ]] && continue
    [[ "$type" != "ACTIVE" ]] && continue
    expiry=$(net ads search "(sAMAccountName=${uname})" extensionAttribute4 -P 2>/dev/null \
        | grep "^extensionAttribute4:" | awk '{print $2}')
    if [[ -n "$expiry" && "$expiry" < "$(date +%Y-%m-%d)" ]]; then
        echo "SCADUTO: $uname (scadenza: $expiry) — aggiornare CSV"
    fi
done < /usr/local/custom/biome_supervisor_map.csv

# 2. Report spazio per supervisor
du -sh /mnt/ProjectStorage/*/ | sort -rh

# 3. Conta dati per progetto
du -sh /mnt/ProjectStorage/*/*/ | sort -rh | head -20
```

### Annuale (inizio anno accademico)

```bash
# 1. Rigenerazione completa CSV
sudo /usr/local/custom/script/scopri_progetti_v5.sh

# 2. Confronto con produzione
diff /usr/local/custom/biome_supervisor_map.csv \
     /usr/local/custom/biome_supervisor_map_$(date +%Y%m%d).csv | grep "^[<>]"

# 3. Invio email ai PI per nuovi dottorandi
# (il file biome_email_pi.txt viene generato automaticamente da scopri_progetti_v5.sh)
cat /usr/local/custom/biome_email_pi.txt

# 4. Rotazione log (mantieni ultimi 2 anni)
find /usr/local/custom/logs/ -name "archive_run_*.log" \
    -mtime +730 -delete

# 5. Backup CSV storici (comprimi vecchi draft)
find /usr/local/custom/ -name "biome_supervisor_map_*.csv" \
    -not -name "biome_supervisor_map.csv" \
    -mtime +90 \
    | xargs gzip -9
```

### Cron suggerito

```cron
# /etc/cron.d/biome-archive

# Verifica giornaliera symlink rotti — ore 07:00
0 7 * * * root /usr/local/custom/script/unibo_archive_manager_v23.sh --status 2>&1 | grep -E "BROKEN|LEGACY" | mail -s "[BIOME] Symlink check" admin@biome.unibo.it

# Report mensile spazio — primo del mese ore 08:00
0 8 1 * * root du -sh /mnt/ProjectStorage/*/ | sort -rh | mail -s "[BIOME] Report spazio" admin@biome.unibo.it
```

---

## 10. Reference rapido — comandi

### scopri_progetti_v5.sh

```bash
# Genera CSV draft completo
sudo /usr/local/custom/script/scopri_progetti_v5.sh

# Output:
#   /usr/local/custom/biome_supervisor_map_YYYYMMDD.csv   ← draft da revisionare
#   /usr/local/custom/biome_ad_report_YYYYMMDD.txt        ← report gruppi AD
#   /usr/local/custom/biome_email_pi.txt                  ← email per PI (se ci sono _UNKNOWN_)
```

### unibo_archive_manager_v23.sh

```bash
# Dry-run (default, sicuro)
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh

# Applica tutte le modifiche
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply

# Applica + copia dati al TRANSFER
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --apply --sync-data

# Stato symlink per ogni utente
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status

# Albero directory ProjectStorage (max 3 livelli)
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --list-tree

# Storico trasferimenti supervisor
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --transfer-report

# Aiuto
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --help
```

### Diagnostica rapida

```bash
# Test AD
sudo net ads testjoin

# Query utente AD
sudo net ads search "(sAMAccountName=USERNAME)" displayName title memberOf -P 2>/dev/null

# Verifica utente
id USERNAME && wbinfo -i USERNAME

# Simlink rotti
sudo /usr/local/custom/script/unibo_archive_manager_v23.sh --status | grep BROKEN

# Spazio storage
df -h /mnt/ProjectStorage && du -sh /mnt/ProjectStorage/*/

# Ultimi eventi audit
tail -20 /usr/local/custom/logs/biome_audit.log

# Log ultima esecuzione
ls -t /usr/local/custom/logs/archive_run_*.log | head -1 | xargs tail -30
```

### Modifica rapida CSV

```bash
# Aggiungi nuovo utente (ACTIVE)
echo "username,ACTIVE,supervisor,NomeProgetto,$(date +%Y-%m-%d),,manual,\"note\"" \
    | sudo tee -a /usr/local/custom/biome_supervisor_map.csv

# Aggiungi TRANSFER
echo "username,TRANSFER,nuovo.supervisor,NuovoProgetto,$(date +%Y-%m-%d),,manual,\"motivazione\"" \
    | sudo tee -a /usr/local/custom/biome_supervisor_map.csv

# Segna progetto come concluso (modifica date_end)
sudo sed -i '/^USERNAME,ACTIVE,SUPERVISOR,PROGETTO/{s/,,manual/,'"$(date +%Y-%m-%d)"',manual/}' \
    /usr/local/custom/biome_supervisor_map.csv

# Verifica modifica
grep USERNAME /usr/local/custom/biome_supervisor_map.csv
```

---

*BIOME sysadmin — biome-calc01 — Università di Bologna BiGeA*  
*Aggiornare questo documento ad ogni modifica strutturale agli script.*
