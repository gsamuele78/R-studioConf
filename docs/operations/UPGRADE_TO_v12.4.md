# Upgrade Runbook — Rprofile v12.4 (Lussu Hang + NFS Library Storm)

**Audience**: sysadmin BIOME-CALC.
**Tier**: T1 (host) — autoritativo.
**Generato**: 2026-05-09.
**Tempo stimato**: 5 minuti per nodo (senza disco dedicato), +5 minuti per nodo (con nuovo disco Proxmox).
**Reboot richiesto**: NO (basta `systemctl restart rstudio-server`).

---

## 1. Cosa cambia

| Componente | Prima (v12.2) | Dopo (v12.4) |
|---|---|---|
| `mclapply` + `terra/sf` | deadlock (Lussu) | reroutato automaticamente su PSOCK |
| `terra` rasters | in RAM (rischio OOM) | `todisk = TRUE` di default su `/Rtmp` |
| `R_LIBS_USER` | NFS `$HOME/R/...` (lookup-storm) | locale `/var/lib/biome-Rlibs/<user>/<ver>/` con fallback NFS |
| Audit mount NFS | nessuno | step 7d read-only (vers ≥ 4.1, nconnect ≥ 4) |
| Disco R-libs dedicato | n/a | opzionale: `R_LIBS_LOCAL_DEVICE=/dev/sdX` |

Nessun file utente (`*.R`, `.Renviron`) viene toccato (HC-13).

---

## 2. Prerequisiti

- [ ] Backup di `/etc/R/` su almeno un nodo: `tar czf ~/backup-etc-R-$(hostname)-$(date +%F).tgz /etc/R/`.
- [ ] Maintenance window di ~5 min/nodo (RStudio Server viene riavviato — sessioni R attive vengono interrotte).
- [ ] (Opzionale) Disco virtio aggiunto su Proxmox a ogni VM, dimensione ≥ 80 GB. Verificare con `lsblk` che appaia come `/dev/sdb` o `/dev/sdc`.

---

## 3. Procedura — nodi nuovi e già deployati

La procedura è **identica** per nodi nuovi e nodi già in produzione: tutti gli step di `50_setup_nodes.sh` sono idempotenti.

### 3.1 — Su uno (qualunque) nodo: pull del codice

```bash
cd /opt/R-studioConf
git fetch --all
git checkout main
git pull
```

### 3.2 — (Opzionale) configurare disco R-libs dedicato

Se hai aggiunto il disco virtio in Proxmox e vuoi che `R_LIBS_USER` finisca lì:

```bash
sudo $EDITOR /opt/R-studioConf/config/setup_nodes.vars.conf
```

Modifica:

```bash
R_LIBS_LOCAL_DEVICE="/dev/sdb"     # o /dev/sdc — verifica con lsblk
R_LIBS_LOCAL_FSTYPE="ext4"
R_LIBS_LOCAL_SIZE_GB=80
```

**Saltarlo è sicuro**: lasciando `R_LIBS_LOCAL_DEVICE=""` il sistema crea solo
`/var/lib/biome-Rlibs/` sulla rootfs (Mode A). La differenza è solo dove finisce
lo spazio occupato dai pacchetti compilati.

### 3.3 — Su **ogni** nodo (uno alla volta)

```bash
cd /opt/R-studioConf
sudo bash scripts/50_setup_nodes.sh
# Selezione: 1   (full deployment)
# oppure (più chirurgico):
# Selezione: L   → solo Step 7c + 7d (local R-libs + NFS audit)
# Selezione: 3   → solo Step 8     (Rprofile + Renviron)
```

Lo script:

1. Crea (o monta) `/var/lib/biome-Rlibs/` con sticky 1777.
2. Esegue audit read-only dei mount NFS (vers, nconnect, lookupcache).
3. Rideploya `/etc/R/Rprofile.site` (kernel v12.4) e `/etc/R/Rprofile_site.d/` (incluso `52_mclapply_guard.R`).
4. Rideploya `/etc/R/Renviron.site` con il nuovo `R_LIBS_USER` di doppia path.
5. **Rebuild del bundle bytecode v12.3** (`/etc/R/Rprofile_site.d/.compiled/{bundle.Rc,manifest.txt}`):
   l'aggiunta di `52_mclapply_guard.R` invalida l'md5 manifest e Step 8 di
   `50_setup_nodes.sh` rigenera il bundle in modo atomico (`mktemp` →
   `mv -T`) + page-cache warm-up. Forzare un rebuild manuale (in caso di
   sospetto stale): `sudo rm -rf /etc/R/Rprofile_site.d/.compiled && sudo
   bash scripts/50_setup_nodes.sh --step compile_bundle`. Vedi
   `docs/reference/Rprofile_site.CHANGELOG.md` §v12.3 per l'architettura
   del fast-path e il fallback al loop legacy.

Tempo: ~3 min senza Ollama/pacchetti, ~5 min con tutti gli step.

### 3.4 — Riavviare RStudio Server

```bash
sudo systemctl restart rstudio-server
```

### 3.5 — Validazione (ogni nodo)

```bash
# 1) Versione Rprofile
sudo bash scripts/50_setup_nodes.sh --verify

# 2) R_LIBS_USER è quello locale?
sudo -u <un_utente_AD_qualunque> R --vanilla -e '.libPaths()'
# Atteso: la prima entry deve essere /var/lib/biome-Rlibs/<user>/<R-version>

# 3) ForkGuard attivo?
sudo -u <utente> R --vanilla -e 'biome_diag()' 2>&1 | grep -i fork
# Atteso: "ForkGuard: ENABLED" oppure "fork->PSOCK reroute armed"

# 4) Lussu probe (su un piccolo .R che usa terra+mclapply)
sudo /usr/local/bin/99_diagnose_lussu_hang.sh /path/al/script_minimo.R
# Atteso: probe E (PSOCK) e probe F (terra todisk) → PASS
```

---

## 4. Rollback

Se qualcosa va storto su un nodo, **rollback per-fase**:

| Sintomo | Comando di rollback |
|---|---|
| Rprofile.site non parsabile | `sudo cp /etc/R/Rprofile.site.bak /etc/R/Rprofile.site && sudo systemctl restart rstudio-server` |
| Fragment 52 rompe sessioni | `sudo rm /etc/R/Rprofile_site.d/52_mclapply_guard.R && sudo systemctl restart rstudio-server` |
| `R_LIBS_USER` punta a path inutilizzabile | `sudo cp /etc/R/Renviron.site.bak /etc/R/Renviron.site && sudo systemctl restart rstudio-server` (i pacchetti su NFS restano raggiungibili) |
| Disco dedicato non si monta | `sudo umount /var/lib/biome-Rlibs; sudo sed -i '/managed-by: 50_setup_nodes.sh local-Rlibs/d' /etc/fstab` poi rilancia step 7c (Mode A) |

I backup sono creati automaticamente: `*.bak` per i file singoli, `/etc/R/Rprofile_site.d.bak.<timestamp>/` per i frammenti.

---

## 5. Bypass per debug (utente)

L'utente può disattivare la nuova logica per una sola sessione:

```bash
# Forzare R_LIBS_USER al vecchio path NFS
export R_LIBS_USER="${HOME}/R/x86_64-pc-linux-gnu-library/$(R --version | head -1 | awk '{print $3}' | cut -d. -f1-2)"

# Disabilitare il fork-guard (tornare al comportamento mclapply nativo)
export BIOME_DISABLE_FORK_GUARD=1

# Disabilitare terra todisk (rasters in RAM)
export BIOME_TERRA_NORAM=0   # oppure unset BIOME_TERRA_NORAM e modificare ENABLE_TERRA_TODISK_DEFAULT

R
```

Nessuna di queste variabili va messa permanentemente nel `.Renviron` utente — sono pensate solo per troubleshooting.

---

## 6. Sincronizzazione delle librerie tra nodi (opzionale)

Con `R_LIBS_USER` locale, ogni nodo ha la propria copia compilata dei pacchetti utente. È un comportamento corretto (i `.so` non sono portabili cross-CPU). Però se due nodi hanno la stessa CPU e si vogliono evitare ricompilazioni doppie:

```bash
# Da nodo-master a nodo-replica (eseguire come root):
rsync -aHAX --delete \
  /var/lib/biome-Rlibs/<utente>/ \
  nodo-replica:/var/lib/biome-Rlibs/<utente>/
```

Eseguibile via cron settimanale se ha senso. Non è obbligatorio.

---

## 7. Domande frequenti

**Q. I pacchetti utente già installati su NFS continuano a funzionare?**
Sì. Il fallback `${HOME}/R/x86_64-pc-linux-gnu-library/%v` resta nel path. R li trova lì se non sono ancora stati installati nel path locale.

**Q. Cosa succede al primo `install.packages()` dopo l'upgrade?**
Va a finire nel path locale (`/var/lib/biome-Rlibs/<user>/<ver>/`). Quello vecchio su NFS resta intatto. Nessuna duplicazione automatica.

**Q. Lo storage NFS si svuota?**
No. I pacchetti vecchi restano dove sono. Per liberare spazio: l'utente può fare `unlink("~/R/x86_64-pc-linux-gnu-library", recursive=TRUE)` solo dopo aver verificato che tutti i pacchetti gli funzionino dal path locale.

**Q. Come verifico l'audit NFS?**

```bash
sudo bash scripts/50_setup_nodes.sh   # opzione L
```

Output con `[audit]`: ogni mount viene controllato per `vers`, `nconnect`, `lookupcache`. Se manca qualcosa lo script lo segnala come WARN — il fix è da fare lato TrueNAS o `/etc/fstab`, **mai** da questo script (PSE: detect, never silently coerce).

---

## 8. Tier deltas

- **T1 (host)**: implementato (questo runbook).
- **T2 (docker)**: pending — da portare quando T2 sarà rifornito al pari di T1.
- **T3 (k8s)**: pending — `R_LIBS_USER` su `emptyDir` per-pod, fork-guard via ConfigMap stesso fragment.
