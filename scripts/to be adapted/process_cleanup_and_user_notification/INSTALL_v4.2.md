# BIOME-CALC — Orphan Process Cleanup v4.2

## Novita' v4.2: Supporto gruppi Teams

Il gruppo `Lifewatch_Biome_internal@live.unibo.it` e' un gruppo
Microsoft Teams/M365. Per default i gruppi Teams **rifiutano email
da mittenti esterni al gruppo**. Il server BIOME-CALC manda via
`smtprelay.unibo.it` con sender `biome-calc@personale.dir.unibo.it`
che non e' un membro del gruppo.

### Soluzione adottata

Le notifiche admin vengono inviate ai **singoli membri** tramite un
file di destinatari: `admin_recipients.txt`. Decommentare gli
indirizzi dei ricercatori BIOME che devono ricevere le notifiche.

### Alternativa: abilitare mittenti esterni sul gruppo Teams

Se preferisci continuare a usare il gruppo Teams, un admin M365
(CESIA/IT di UniBo) deve eseguire:

```powershell
Set-UnifiedGroup -Identity "Lifewatch_Biome_internal@live.unibo.it" `
  -RequireSenderAuthenticationEnabled $false
```

In quel caso cambia nel conf:
```bash
ADMIN_EMAIL="Lifewatch_Biome_internal@live.unibo.it"
```

---

## Struttura file

```
/usr/local/custom/rstudio/
├── conf/
│   ├── r_orphan_cleanup.conf          # Configurazione centralizzata
│   └── admin_recipients.txt           # Lista destinatari admin
├── script/
│   ├── send_email.sh                  # GIA' PRESENTE
│   ├── orphan_cleanup_helpers.sh      # NUOVO: funzioni condivise
│   ├── cleanup_r_orphans.sh           # Cron: kill orfani
│   ├── notify_r_orphans.sh            # Cron: email utenti
│   └── r_orphan_report.sh            # Report sysadmin
```

## Installazione

```bash
# Directory
sudo mkdir -p /usr/local/custom/rstudio/conf
sudo mkdir -p /var/log/r_orphan_cleanup/notifications

# Configurazione
sudo cp r_orphan_cleanup.conf   /usr/local/custom/rstudio/conf/
sudo cp admin_recipients.txt    /usr/local/custom/rstudio/conf/

# Script
sudo cp orphan_cleanup_helpers.sh /usr/local/custom/rstudio/script/
sudo cp cleanup_r_orphans.sh     /usr/local/custom/rstudio/script/
sudo cp notify_r_orphans.sh      /usr/local/custom/rstudio/script/
sudo cp r_orphan_report.sh       /usr/local/custom/rstudio/script/

# Permessi
sudo chmod +x /usr/local/custom/rstudio/script/orphan_cleanup_helpers.sh
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

## Configurazione destinatari admin

### Opzione A: File con lista (default, consigliata)

```bash
# In r_orphan_cleanup.conf:
ADMIN_EMAIL="file:///usr/local/custom/rstudio/conf/admin_recipients.txt"
```

Edita `admin_recipients.txt` — decommenta gli indirizzi:
```
gianfranco.samuele2@unibo.it
# alessandro.chiarucci@unibo.it    ← decommenta per attivare
# duccio.rocchini@unibo.it
```

### Opzione B: Lista diretta nel conf

```bash
ADMIN_EMAIL="gianfranco.samuele2@unibo.it,duccio.rocchini@unibo.it"
```

### Opzione C: Gruppo Teams (richiede intervento CESIA)

```bash
ADMIN_EMAIL="Lifewatch_Biome_internal@live.unibo.it"
```

## Test

```bash
# Report (verifica che i destinatari siano risolti)
sudo /usr/local/custom/rstudio/script/r_orphan_report.sh

# Cerca la sezione "DESTINATARI ADMIN CONFIGURATI" nell'output

# Test invio email
sudo /usr/local/custom/rstudio/script/r_orphan_report.sh --mail
```

## MAIL_DOMAIN per utenti

Gli utenti ricevono notifiche a `<username>@MAIL_DOMAIN`.
Se ci sono utenti con domini diversi, crea un file di mapping:

```bash
# /usr/local/custom/rstudio/conf/user_email_map.txt
# formato: username  email
martina.livornese2   martina.livornese2@studio.unibo.it
duccio.rocchini      duccio.rocchini@unibo.it
```

Lo script helpers lo legge automaticamente se presente.
