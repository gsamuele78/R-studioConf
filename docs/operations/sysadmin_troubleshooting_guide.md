# BIOME-CALC Sysadmin Troubleshooting Guide

**Emergency DevOps Fix-Chain Reference for BIOME-CALC v10.0**

This guide is organized by **symptom → diagnostic → root cause → fix → verify**. Each section is self-contained. Go directly to the symptom you're seeing.

---

## Quick Reference: Key File Locations

```
/etc/R/Rprofile.site                        # The brain (1,458 lines)
/etc/R/Renviron.site                        # Environment variables (BLAS, threads, paths)
/etc/rstudio/rserver.conf                   # RStudio Server config
/etc/rstudio/rsession.conf                  # Per-session config
/etc/rstudio/rsession-profile               # CORETYPE injection per rsession
/etc/profile.d/biome-coretype.sh            # Boot-level CORETYPE detection
/etc/biome-calc/                            # Config root
/etc/biome-calc/coretype                    # Current OPENBLAS_CORETYPE value
/etc/biome-calc/audit.conf                  # Audit parameters
/etc/biome-calc/audit/00_audit_v28.R        # Deployed audit script (from templates/)
/var/log/biome-log/r_biome_system.log       # All R session events (world-writable)
/nfs/home/<user>                            # User homes (NFS from TrueNAS)
/Rtmp                                       # Local 400GB temp disk
/swap.img                                   # 32GB swapfile
```

## Quick Reference: Key Commands

```bash
# Health check (all services)
sudo bash scripts/99_health_check.sh

# Deep troubleshooting (all subsystems + debug bundle)
sudo bash scripts/99_troubleshoot_env.sh --all --test-user john.doe --collect

# Post-mortem crash forensics (when user reports "it crashed")
sudo bash scripts/99_postmortem_forensics.sh --user john.doe --incident
sudo bash scripts/99_postmortem_forensics.sh --user john.doe --hours 8 --output /tmp/report.txt
sudo bash scripts/99_postmortem_forensics.sh --all-recent --quick

# Subsystem-specific troubleshooting
sudo bash scripts/99_troubleshoot_env.sh --rstudio
sudo bash scripts/99_troubleshoot_env.sh --nginx
sudo bash scripts/99_troubleshoot_env.sh --auth --test-user john.doe
sudo bash scripts/99_troubleshoot_env.sh --storage --test-user john.doe

# Audit from R console
source('/etc/biome-calc/audit/00_audit_v28.R')

# Resource status from R console
status()
biome_plot_budget()
```

---

## SYMPTOM 1: RStudio Sessions Crashing with SIGSEGV

### Diagnostic

```bash
# Check which BLAS is active
update-alternatives --display libblas.so.3-x86_64-linux-gnu

# Check for crash logs
journalctl -u rstudio-server --since "1 hour ago" | grep -E 'SEGV|signal|crash'

# Verify the deployed library
ls -la /usr/lib/x86_64-linux-gnu/openblas-serial/libblas.so.3
dpkg -l | grep openblas
```

### Root Cause

`openblas-pthread` is installed/active. Its internal thread pool races with RStudio's `rsession` pthreads during `solve()`/`crossprod()` → `SIGSEGV` in `blas_thread_server`.

### Fix Chain

> [!CAUTION]
> This is the most dangerous production issue. It causes random, unreproducible crashes.

```bash
# Step 1: Remove pthread variant
sudo apt-get remove --purge libopenblas0-pthread 2>/dev/null || true

# Step 2: Install serial variant
sudo apt-get install -y libopenblas-serial-dev

# Step 3: Pin BLAS alternatives
sudo update-alternatives --set libblas.so.3-x86_64-linux-gnu \
  /usr/lib/x86_64-linux-gnu/openblas-serial/libblas.so.3
sudo update-alternatives --set liblapack.so.3-x86_64-linux-gnu \
  /usr/lib/x86_64-linux-gnu/openblas-serial/liblapack.so.3

# Step 4: Restart RStudio
sudo systemctl restart rstudio-server

# Step 5: Verify in R
Rscript --vanilla -e "sessionInfo()" | grep BLAS
# Should show: openblas-serial
```

### Verify

```bash
# BLAS smoke test
Rscript --vanilla -e "
  A <- matrix(runif(500*500), 500, 500)
  B <- A %*% A  # Should not crash
  cat('BLAS OK\n')
"
```

---

## SYMPTOM 2: Server-Wide OOM Kill (All Users Affected)

### Diagnostic

```bash
# Check kernel OOM events
dmesg | grep -i oom | tail -20

# Check swap usage
free -h
swapon --show

# Check which R sessions used the most memory
ps aux --sort=-%mem | head -20

# Check /Rtmp disk (NOT tmpfs — should not affect RAM)
df -h /Rtmp

# Check if tmpfs is accidentally mounted (CRITICAL — this WOULD eat RAM)
mount | grep tmpfs | grep -v /sys | grep -v /run
```

### Root Cause Checklist

1. **Wrong diagnosis**: `/Rtmp` full ≠ RAM issue (it's disk-backed). Confirm `/Rtmp` is NOT tmpfs
2. **User ran unguarded operation**: Despite guards, edge cases exist (e.g., `Rcpp::sourceCpp()` with 50GB intermediate objects)
3. **Swap exhausted**: Check if `SWAP_SIZE_GB=32` is enough for workload
4. **Ollama hogging memory**: Ollama has `MemoryMax=24G` cgroup, but verify

### Fix Chain

```bash
# Step 1: Kill heaviest R sessions (triage)
# List by memory (columns: PID, USER, %MEM, RSS_MB, COMMAND)
ps -eo pid,user,%mem,rss,args --sort=-%mem | grep rsession | head -5

# Kill specific session (tell user to save first if possible)
kill -TERM <PID>
sleep 15
kill -KILL <PID>  # Only if -TERM didn't work

# Step 2: Check swap health
sudo swapon --show
sudo free -h
# If swap is full:
sudo swapoff /swap.img && sudo swapon /swap.img  # Reset swap (CAREFUL: may OOM during swapoff)

# Step 3: Verify kernel swappiness
cat /proc/sys/vm/swappiness
# Should be 10 (set by 50_setup_nodes.sh). If 60 (default), fix:
echo 10 | sudo tee /proc/sys/vm/swappiness
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-biome-swap.conf

# Step 4: Check if Ollama is within its cgroup
systemctl show ollama.service | grep MemoryMax
systemctl show ollama.service | grep MemoryCurrent

# Step 5: Restart RStudio Server to clean all sessions
sudo systemctl restart rstudio-server
```

---

## SYMPTOM 3: NFS Stale File Handle / Home Directory Unavailable

### Diagnostic

```bash
# Check NFS mount status
mount | grep nfs
df -h /nfs/home  # Will hang if NFS is unreachable

# Check TrueNAS connectivity
ping -c 3 <truenas_ip>

# Stale file handle test
ls -la /nfs/home/<user>/  # Will show "Stale file handle" if broken

# NFS client status
systemctl status nfs-client.target
rpcinfo -p  # RPC services
showmount -e <truenas_ip>
```

### Fix Chain

```bash
# Step 1: Force unmount stale NFS
sudo umount -f /nfs/home  # Force unmount
# If "device is busy":
sudo umount -l /nfs/home  # Lazy unmount (unsafe — allows unlink after pending I/O)

# Step 2: Remount
sudo mount -t nfs4 <truenas_ip>:/mnt/pool/home /nfs/home -o \
  rw,hard,intr,rsize=131072,wsize=131072,timeo=60,retrans=3

# Step 3: Verify
ls /nfs/home/<user>/
# Should list files normally

# Step 4: Restart RStudio to reconnect sessions
sudo systemctl restart rstudio-server

# CRITICAL: If users lost in-progress work, check TrueNAS snapshots:
# TrueNAS GUI → Storage → Snapshots → Rollback to last known good
```

> [!WARNING]
> **NFS outage = data unavailable to ALL users.** If TrueNAS is unreachable, nobody can log in. This is the most important SPOF in the architecture. Monitor TrueNAS health independently.

---

## SYMPTOM 4: User Cannot Log In (PAM/AD Authentication Failure)

### Diagnostic

```bash
# Test user resolution
getent passwd john.doe
id john.doe

# Test PAM authentication
sudo pamtester rstudio john.doe authenticate
sudo pamtester nginx john.doe authenticate

# Check which auth backend is active
sudo realm list
systemctl status sssd
systemctl status winbind

# Check Kerberos
klist -k /etc/krb5.keytab

# Check auth logs
tail -50 /var/log/auth.log | grep -iE 'fail|denied|error|pam'
```

### Fix Chain by Error Type

**Error: "User not found via getent"**

```bash
# Clear SSSD cache
sudo sss_cache -E
sudo systemctl restart sssd
# Verify
getent passwd john.doe
```

**Error: "PAM authentication failed"**

```bash
# Check PAM config
cat /etc/pam.d/rstudio
# Should contain: auth required pam_unix.so OR pam_sss.so

# If SSSD backend:
sudo systemctl restart sssd
# If Samba/Winbind backend:
sudo systemctl restart winbind
```

**Error: "Home directory not created"**

```bash
# Check pam_mkhomedir
grep pam_mkhomedir /etc/pam.d/common-session
# Should contain: session optional pam_mkhomedir.so skel=/etc/skel umask=0077

# Manual fix:
sudo mkdir -p /nfs/home/john.doe
sudo cp /etc/skel/.Renviron /nfs/home/john.doe/
sudo chown -R john.doe:domain\ users /nfs/home/john.doe
```

---

## SYMPTOM 5: /Rtmp Disk Full (R Temp Operations Failing)

### Diagnostic

```bash
# Check /Rtmp usage
df -h /Rtmp

# Find largest consumers
du -sh /Rtmp/biome_* | sort -rh | head -10

# Check who owns the biggest files
find /Rtmp -type f -size +1G -exec ls -lh {} \;

# Check if cleanup cron is running
systemctl list-timers | grep tmpfiles
cat /etc/tmpfiles.d/biome-rtmp-cleanup.conf 2>/dev/null
```

### Fix Chain

```bash
# Step 1: Identify stale sessions
ls -la /Rtmp/biome_*/
# Each directory = one user. Check if user has an active R session:
ps aux | grep rsession

# Step 2: Clean abandoned user temp dirs (SAFE — only for users with no active session)
for d in /Rtmp/biome_*/; do
  user=$(basename "$d" | sed 's/biome_//')
  if ! ps aux | grep -v grep | grep "rsession.*$user" > /dev/null; then
    echo "Cleaning stale temp for: $user"
    rm -rf "$d"
  fi
done

# Step 3: If disk is >90% full and users ARE active, clean old files
find /Rtmp -name "*.o" -mtime +1 -delete        # Stale .o files from compilation
find /Rtmp -name "*.tif" -mtime +3 -delete       # Old terra raster temp files
find /Rtmp -name "raster_tmp_*" -mtime +1 -delete

# Step 4: Verify
df -h /Rtmp
```

> [!TIP]
> `/Rtmp` is a 400GB local disk. Even at 80%, there's 80GB free. The warning at 80% (`TMP_WARN_THRESHOLD_PCT`) is advisory only — no redirect occurs. This is safe by design.

---

## SYMPTOM 6: NGINX 502 Bad Gateway / Portal Not Loading

### Diagnostic

```bash
# Config syntax
sudo nginx -t

# Service status
systemctl status nginx

# Upstream connectivity
curl -sIk http://127.0.0.1:8787  # RStudio
curl -sf http://127.0.0.1:7681   # TTYD (if terminal wrapper used)
curl -sf http://127.0.0.1:11434/api/tags  # Ollama

# Error logs
tail -50 /var/log/nginx/error.log
```

### Fix Chain

```bash
# Most common: RStudio is down behind NGINX
sudo systemctl restart rstudio-server
sleep 5
curl -sIk http://127.0.0.1:8787  # Verify upstream is back

# If NGINX config is broken
sudo nginx -t 2>&1  # Shows exact line number of error
# Fix the config, then:
sudo systemctl reload nginx  # Reload without downtime

# If SSL cert expired
sudo bash scripts/32_setup_letsencrypt.sh  # Renew Let's Encrypt
# OR self-signed renewal:
# Check cert expiry:
openssl x509 -enddate -noout -in /etc/nginx/ssl/cert.crt
```

---

## SYMPTOM 7: Rprofile Failed to Load (Welcome Banner Missing)

### Diagnostic

```bash
# Test Rprofile syntax
Rscript --vanilla -e "
tryCatch({parse(file='/etc/R/Rprofile.site');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s', e\$message)))"

# Check system log for Rprofile errors
grep -i "profile\|FAIL\|ERROR" /var/log/biome-log/r_biome_system.log | tail -20

# Check template substitution was correct
grep '%%' /etc/R/Rprofile.site  # Should return NOTHING — all %%VARS%% should be replaced

# Check Renviron.site
cat /etc/R/Renviron.site
```

### Fix Chain

```bash
# If %%PLACEHOLDERS%% are still present:
# The template wasn't processed. Redeploy:
cd /path/to/R-studioConf
sudo bash scripts/50_setup_nodes.sh
# Select option 3: "Config files only"

# If parse error in Rprofile.site:
# Check the backup:
ls -la /etc/R/Rprofile.site.bak
# Restore backup to get users working immediately:
sudo cp /etc/R/Rprofile.site.bak /etc/R/Rprofile.site
sudo systemctl restart rstudio-server
# Then fix the template and redeploy

# Verify
Rscript --vanilla -e "tryCatch({parse(file='/etc/R/Rprofile.site');cat('PARSE_OK')}, error=function(e) cat(e\$message))"
```

---

## SYMPTOM 8: Orphan R Processes Accumulating (Memory Leak)

### Diagnostic

```bash
# Count orphan R-related processes (PPID=1 means parent died → adopted by init)
ps -eo pid,ppid,user,rss,args | awk '$2 == 1' | grep -E 'Rscript|R --slave|R --no-save' | wc -l

# Show top orphans by memory
ps -eo pid,ppid,user,rss,etime,args | awk '$2 == 1' | grep -E 'Rscript|R --slave|R --no-save' | sort -k4 -rn | head -10

# Check if cleanup cron is running
systemctl list-timers | grep -i orphan
cat /etc/cron.d/biome_orphan_cleanup

# Check cleanup log
tail -30 /var/log/biome-log/r_orphan_cleanup.log
```

### Fix Chain

```bash
# Step 1: Run cleanup manually
sudo bash /etc/biome-calc/conf/cleanup_r_orphans.sh

# Step 2: If cron is missing, redeploy
cd /path/to/R-studioConf
sudo bash scripts/50_setup_nodes.sh
# Select option 8: "Setup Orphan Process Cleanup"

# Step 3: Emergency kill all orphaned R processes (NUCLEAR OPTION — warns all active users)
# List first:
ps -eo pid,ppid,user,rss,etime,args | awk '$2 == 1' | grep -E 'Rscript|R --slave'
# Kill all orphans:
ps -eo pid,ppid,args | awk '$2 == 1 && /Rscript|R --slave|R --no-save/' | awk '{print $1}' | xargs -r kill -TERM
sleep 15
# SIGKILL stragglers
ps -eo pid,ppid,args | awk '$2 == 1 && /Rscript|R --slave|R --no-save/' | awk '{print $1}' | xargs -r kill -KILL
```

> [!IMPORTANT]
> **Do NOT kill processes where PPID ≠ 1.** Those are live workers inside active sessions. The 8-level ancestry check in `cleanup_r_orphans.sh` exists precisely to avoid killing NIMBLE compilation chains (`rsession → R → system2 → make → g++`).

---

## SYMPTOM 9: OPENBLAS_CORETYPE Wrong After VM Migration

### Diagnostic

```bash
# Current detected CORETYPE
cat /etc/biome-calc/coretype

# Actual CPU
lscpu | grep "Model name"
grep -m1 "model name" /proc/cpuinfo

# Check boot-level detection
cat /etc/profile.d/biome-coretype.sh
# Check rsession-level detection
cat /etc/rstudio/rsession-profile | grep CORETYPE

# Test BLAS with current CORETYPE
Rscript --vanilla -e "
  Sys.setenv(OPENBLAS_CORETYPE=Sys.getenv('OPENBLAS_CORETYPE','auto'))
  A <- matrix(runif(100*100),100,100)
  B <- A %*% A
  cat('OK\n')
"
```

### Fix Chain

```bash
# Redeploy CORETYPE detection (updates all 3 levels)
cd /path/to/R-studioConf
sudo bash scripts/50_setup_nodes.sh
# Select option 2: "BLAS/CORETYPE detection only"

# If SIGILL on specific CORETYPE, fallback to safe value:
echo "SANDYBRIDGE" | sudo tee /etc/biome-calc/coretype
# Edit boot-level script:
sudo sed -i 's/OPENBLAS_CORETYPE=.*/OPENBLAS_CORETYPE=SANDYBRIDGE/' /etc/profile.d/biome-coretype.sh
sudo systemctl restart rstudio-server
```

---

## SYMPTOM 10: Ollama AI Not Responding

### Diagnostic

```bash
systemctl status ollama.service
curl -sf http://127.0.0.1:11434/api/tags
journalctl -u ollama.service --since "30 min ago" | tail -30

# Check memory cgroup
systemctl show ollama.service | grep -E 'MemoryMax|MemoryCurrent'

# Check if model is loaded
ollama list
```

### Fix Chain

```bash
# Step 1: Restart if crashed
sudo systemctl restart ollama.service
sleep 10
curl -sf http://127.0.0.1:11434/api/tags && echo "OK" || echo "STILL DOWN"

# Step 2: If OOM killed (MemoryMax exceeded)
# Reduce model size or increase limit:
sudo systemctl edit ollama.service
# Add: MemoryMax=32G   (was 24G)
sudo systemctl daemon-reload
sudo systemctl restart ollama.service

# Step 3: If model missing
ollama pull qwen2.5-coder:14b-instruct-q4_K_M
# Or use smaller fallback:
ollama pull codellama:7b
```

---

## SYMPTOM 11: User Reports "Script Slower Than Before"

### Root Cause Analysis

This is **expected behavior**, not a bug. Explanation:

| Scenario | Legacy | BIOME-CALC | Why |
|:---|:---|:---|:---|
| 1 user, `crossprod()` | 32 threads | ≤16 threads (MAX_BLAS_THREADS cap) | Cap prevents QEMU livelock; serial BLAS delegates to RhpcBLASctl |
| 1 user, `solve(10000, 10000)` | 32 threads, OOM risk | May drop to 2 threads + warning | Guard prevents server crash |
| 5 users, all computing | 32×5=160 threads (thrashing) | 6 threads each (fair share) | Total throughput HIGHER |

### What to Tell the User
>
> "Your script has fewer threads because others are also using the server. Run `status()` to see your current allocation. If the server is idle, you'll get up to 16 threads. The old server gave you 32 threads, but with 5 users it actually ran slower due to CPU thrashing."

### If Genuinely Slow

```bash
# Check if user is I/O bound (NFS latency)
iotop -oa -d 5 -P | grep rsession

# Check if swap is being used (memory pressure)
vmstat 1 5  # Look at 'si' and 'so' columns — should be 0

# Check if /Rtmp disk is slow
dd if=/dev/zero of=/Rtmp/test_file bs=1M count=100 oflag=dsync
# Should be >200 MB/s for virtio disk
rm /Rtmp/test_file
```

---

## SYMPTOM 12: Swap Constantly Full / Excessive Swapping

### Diagnostic

```bash
free -h
swapon --show
vmstat 1 5  # columns: si (swap in), so (swap out)
cat /proc/sys/vm/swappiness  # Should be 10
```

### Fix Chain

```bash
# Step 1: Find who's using all the RAM
ps aux --sort=-%mem | head -10

# Step 2: If swappiness is wrong
echo 10 | sudo tee /proc/sys/vm/swappiness
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.d/99-biome-swap.conf

# Step 3: If swap file is too small (32GB default)
sudo swapoff /swap.img
sudo dd if=/dev/zero of=/swap.img bs=1M count=65536  # 64GB
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon /swap.img

# Step 4: Verify
free -h
```

---

## SYMPTOM 13: User Reports "My R Script Crashed" (Post-Mortem Forensics)

> [!IMPORTANT]
> **This is the most common support request.** A botanical or lichenology researcher emails you:
> *"My script doesn't work"*, *"RStudio crashed"*, *"On the old server it was fine"*.
> They cannot give you technical details. You must find the evidence yourself.

### Step 1: Identify WHAT Happened (Automated Triage)

The fastest way to perform post-mortem forensics is to use the dedicated automated tool, which collects 14 categories of evidence and generates an actionable diagnosis (including SSL expiry, timeouts, auth issues, OOMs, and signals):

```bash
# Automated post-mortem crash forensics
sudo bash scripts/99_postmortem_forensics.sh --user <username> --incident

# Scan all recent crashes (no specific user)
sudo bash scripts/99_postmortem_forensics.sh --all-recent --hours 2
```

If the tool is unavailable or you prefer manual inspection, run these manual commands:

```bash
# === WHO crashed? ===
# Ask the user their username, or check recent sessions:
rstudio-server active-sessions 2>/dev/null
# If user's session is missing, it was killed.

# === WHEN did it crash? ===
# Check kernel OOM kills (most common cause)
dmesg -T | grep -i "oom\|killed process" | tail -10

# Check RStudio rsession crashes (SIGSEGV, SIGABRT, etc.)
journalctl -u rstudio-server --since "2 hours ago" | grep -iE 'segv|signal|crash|abort|killed|exit'

# Check BIOME-CALC system log (guards, warnings, errors)
tail -100 /var/log/biome-log/r_biome_system.log | grep -i "FAIL\|WARN\|ERROR"

# Check for OOM crash marker file (left by Rprofile on next login)
ls -la /nfs/home/<username>/ULTIMO_CRASH_RAM.txt 2>/dev/null
```

**Quick classification:**

| Evidence Found | Crash Type | Go To |
|:---|:---|:---|
| `dmesg` shows `oom-kill:` + `rsession` | **Kernel OOM Kill** | Step 2A |
| `journalctl` shows `SIGSEGV` or `signal 11` | **BLAS/SIGSEGV Crash** | SYMPTOM 1 |
| `journalctl` shows `SIGILL` | **CORETYPE Mismatch** | SYMPTOM 9 |
| BIOME log shows `FAIL` entries near crash time | **Rprofile/Guard Error** | Step 2B |
| No server-side evidence at all | **Client-Side Disconnect** | Step 2C |
| User sees `BIOME-CALC:` yellow warning then quit | **Guard Fired Correctly** | Step 2D |

### Step 2A: Kernel OOM Kill — Find What Consumed the RAM

```bash
# Get the exact OOM event details
dmesg -T | grep -A 5 "oom-kill:" | tail -20
# Example output:
#   oom-kill: constraint=CONSTRAINT_NONE [...] task=rsession pid=12345 uid=50001
#   Out of memory: Killed process 12345 (rsession) total-vm:412345678kB [...]

# Check who the user was (from the UID)
getent passwd 50001

# Check what they were running — look at memory usage BEFORE the crash
# (if the session is gone, check the biome syslog)
grep "<username>" /var/log/biome-log/r_biome_system.log | tail -30

# Check if a guard warned them before the crash:
grep "<username>" /var/log/biome-log/r_biome_system.log | grep -i "solve\|dist\|outer\|expand"

# Check current system memory state
free -h
cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree'
```

> [!TIP]
> **The OOM killer logs the RSS (Resident Set Size) of the killed process.** If you see `rss:104857600kB` (100GB), the user tried to allocate a 100GB object. This is the smoking gun — they need to use sparse methods or chunking. The guard should have caught it, but see Step 3 for gaps.

### Step 2B: Guard/Rprofile Error — The Safety Net Failed

```bash
# Check if Rprofile loaded at all for this user
grep "<username>.*Profile" /var/log/biome-log/r_biome_system.log | tail -5
# Should show: [STAT: OK ] Loaded successfully
# If missing: Rprofile failed to load → user had NO guards

# Check if guards are actually installed (from R console as root)
sudo -u <username> Rscript --vanilla -e "
  source('/etc/R/Rprofile.site')
  cat('solve guard:', isTRUE(attr(base::solve, 'biome_guard')), '\n')
  cat('dist guard:',  isTRUE(attr(stats::dist, 'biome_guard')), '\n')
  cat('outer guard:', isTRUE(attr(base::outer, 'biome_guard')), '\n')
  cat('expand.grid guard:', isTRUE(attr(base::expand.grid, 'biome_guard')), '\n')
"
# If any show FALSE → guard installation failed; check Rprofile for errors

# Check if user has a .Rprofile that interferes
cat /nfs/home/<username>/.Rprofile 2>/dev/null
# Common problem: user has `options(error = recover)` or `source("old_script.R")`
# that errors before system Rprofile completes
```

### Step 2C: No Server-Side Evidence — Client Disconnect

If `dmesg`, `journalctl`, and the BIOME log show nothing:

```bash
# Check if the user's session is still alive (it wasn't killed, just disconnected)
ps aux | grep "rsession.*<username>"

# Check NGINX logs for WebSocket timeout
grep "<username>\|websocket\|408\|504" /var/log/nginx/error.log | tail -20

# Check if the user's browser was idle too long
grep "session-timeout" /etc/rstudio/rsession.conf
```

**Common causes:**

- Browser tab was closed → session continues in background (normal behavior)
- VPN disconnected → WebSocket drops → user thinks "it crashed" but session is fine
- NGINX `proxy_read_timeout` exceeded during a long computation (no console output)

**What to tell the user:**
> "Your session is still running. Close the RStudio tab, wait 30 seconds, then open the portal again. Your work should still be there."

### Step 2D: Guard Fired Correctly — User Was Warned

If the user saw a yellow `BIOME-CALC:` warning and then their session died:

```bash
# Check what the guard said
grep "<username>" /var/log/biome-log/r_biome_system.log | tail -20

# The guard WARNED but did not PREVENT the operation (guards are advisory, not blocking)
# The user's operation still ran, consumed all RAM, and was killed by OOM
```

**This means**: The guard's **threshold is too lenient**, or the operation bypassed the guard entirely. See Step 3.

---

### Step 3: Check Guard Coverage — Is This an Unguarded Edge Case?

The BIOME-CALC Rprofile guards intercept **6 specific functions**. Many common ecology/botany R patterns are NOT covered:

#### Currently Guarded Functions

| Function | Guard Behavior | Package |
|:---|:---|:---|
| `solve(a)` | Warns + drops threads if matrix > 5000×5000 and workspace > 80% RAM | base |
| `dist(x)` | Warns if O(n²) output > 5GB and > 50% RAM | stats |
| `outer(X, Y)` | Warns if result > 5GB and > 50% RAM | base |
| `expand.grid(...)` | Warns if rows × cols > 2GB and > 50% RAM | base |
| `geosphere::distm()` | Warns if result > 5GB, hard warn if > 50% RAM | geosphere |
| `doParallel::registerDoParallel()` | Wraps with safe cluster, 1 BLAS thread/worker | doParallel |

#### Known UNGUARDED Patterns (Common in Botanical Research)

> [!WARNING]
> These operations can crash the server and are NOT intercepted by any guard.

| Pattern | Example R Code | Why It's Dangerous | Risk Level |
|:---|:---|:---|:---|
| `as.matrix()` on dist object | `m <- as.matrix(dist(data))` | `dist` stores lower triangle (~N²/2). `as.matrix()` doubles it to full N² | 🔴 Critical |
| `readRDS()` of huge object | `big <- readRDS("model_50gb.rds")` | Loads entire object into RAM at once; no streaming | 🔴 Critical |
| `do.call(rbind, list_of_dfs)` | `result <- do.call(rbind, lapply(files, read.csv))` | Copies entire result on each rbind; O(n²) memory | 🟡 High |
| `Rcpp::sourceCpp()` | Compiling custom C++ code with massive templates | `g++` can spike 8-15GB temp memory | 🟡 High |
| `raster::stack()` on many files | `s <- stack(list.files(".", "*.tif"))` | Loads all rasters into RAM instead of file-backed | 🟡 High |
| `dplyr::collect()` on large DB | `df <- tbl(con, "big_table") %>% collect()` | Pulls entire database table into RAM | 🟡 High |
| `ggplot()` on millions of points | `ggplot(df_10M, aes(x,y)) + geom_point()` | R tries to render all points; ~40 bytes/point | 🟡 High |
| `vegan::vegdist()` then `hclust()` | `hclust(vegdist(community_matrix))` | `vegdist` → large dist → `hclust` copies it again | 🟡 High |
| `nimble::compileNimble()` | Long MCMC compile with too many variables | Spawns `g++` with 8-15GB RAM + temp files | 🟡 High |
| `merge()` with many-to-many | `merge(df1, df2, by="species")` | Cartesian product if key is not unique | 🟡 High |
| `combn(n, k)` | `combn(500, 3)` → 20M combinations | Exponential output size | 🟡 High |

### Step 4: Reproduce the Crash Safely (Forensic Test)

> [!CAUTION]
> **NEVER run the user's full script directly.** Ask for the script, then run it in a controlled way.

```bash
# Step 4a: Get the user's script
# Ask: "Can you send me the .R file or copy-paste the commands you ran?"

# Step 4b: Estimate memory BEFORE running
# Open a root R session and simulate the sizes:
sudo Rscript --vanilla -e "
  # Simulate their data size (ask them: how many rows? how many species?)
  n <- 25000  # Example: 25,000 observation points
  p <- 50     # Example: 50 species columns

  # dist() on this:
  dist_gb <- (n * (n-1) / 2 * 8) / 1024^3
  cat(sprintf('dist(%d obs) → %.1f GB (lower triangle)\n', n, dist_gb))

  # as.matrix(dist()) on this:
  full_gb <- (n * n * 8) / 1024^3
  cat(sprintf('as.matrix(dist(%d obs)) → %.1f GB (FULL matrix)\n', n, full_gb))

  # solve() on this:
  solve_gb <- full_gb * 2.06  # workspace ≈ 2× matrix
  cat(sprintf('solve(matrix(%d×%d)) → %.1f GB workspace needed\n', n, n, solve_gb))

  # Available RAM:
  mi <- readLines('/proc/meminfo', warn=FALSE)
  avail <- as.numeric(sub('.*:\\\\s+(\\\\d+).*', '\\\\1', grep('MemAvailable', mi, value=TRUE)[1])) / 1024^2
  cat(sprintf('Available RAM: %.1f GB\n', avail))
  cat(sprintf('Verdict: %s\n', if(full_gb > avail * 0.8) 'WILL OOM — needs sparse methods' else 'Should fit'))
"

# Step 4c: Run their script with memory monitoring (background)
# In one terminal:
vmstat 1 > /tmp/vmstat_during_test.log &

# In another terminal, run as the user with a timeout:
timeout 300 sudo -u <username> Rscript --vanilla /nfs/home/<username>/their_script.R 2>&1 | tee /tmp/crash_test.log

# After it finishes or crashes:
kill %1  # Stop vmstat
cat /tmp/vmstat_during_test.log | awk 'NR>2{print NR": si="$7" so="$8" free="$4}' | tail -30
# If 'si' and 'so' are high → server was swapping heavily before crash
# If 'free' drops to near 0 → OOM
```

### Step 5: Decision Tree — Fix Script, Add Guard, or Increase Resources?

```
User script crashed
  │
  ├─ Was there a BIOME-CALC warning in R console before crash?
  │   ├─ YES → Guard fired but user ignored it
  │   │        → ACTION: Educate user on the warning meaning
  │   │        → Consider: make guard BLOCKING (stop() instead of warning())
  │   │
  │   └─ NO → Guard did NOT fire
  │       │
  │       ├─ Is the crashing function in the guarded list? (solve/dist/outer/expand.grid/distm)
  │       │   ├─ YES → Guard threshold too high, or matrix size < 5000
  │       │   │        → ACTION: Lower guard threshold in Rprofile_site.R.template
  │       │   │
  │       │   └─ NO → UNGUARDED EDGE CASE
  │       │       │
  │       │       ├─ Is the pattern common in botany/ecology?
  │       │       │   ├─ YES → ACTION: Write a new guard (see Step 6)
  │       │       │   └─ NO  → ACTION: Fix the user's script (one-off help)
  │       │       │
  │       │       └─ Can the user's goal be achieved with less RAM?
  │       │           ├─ YES → ACTION: Rewrite using sparse/chunked methods
  │       │           └─ NO  → ACTION: Increase VM RAM or add swap
  │
  └─ Was it a SIGSEGV (not OOM)?
      → BLAS issue — go to SYMPTOM 1
```

### Step 6: How to Add a New Guard (Template for Sysadmins)

If you identify a common unguarded pattern, here's how to add a new guard to `Rprofile_site.R.template`:

```r
# Template for a new guard — add inside deferred_pkg_init() function
# Replace "dangerous_func" with the actual function name
# Replace "pkg" with the package name (use "base" for base R functions)

if (ENABLE_SMART_ROUTING && !isTRUE(attr(pkg::dangerous_func, "biome_guard"))) tryCatch({
  .biome_env$original_dangerous_func <- pkg::dangerous_func
  safe_dangerous_func <- function(...) {
    # === ESTIMATE MEMORY COST ===
    # Calculate expected output size in GB based on input dimensions
    # Example for as.matrix() on a dist object:
    #   if (inherits(x, "dist")) {
    #     n <- attr(x, "Size")
    #     result_gb <- (n * n * 8) / 1024^3
    #   }
    result_gb <- 0  # Replace with actual estimate

    if (result_gb > 5 && interactive()) {
      ram_gb <- .biome_get_ram_gb()
      if (is.finite(ram_gb) && result_gb > ram_gb * 0.5) {
        warning(sprintf(paste0(
          "BIOME-CALC: dangerous_func() will need ~%.1f GB. Available RAM: ~%.0f GB.\n",
          "  Consider: [suggest alternative approach here]"),
          result_gb, ram_gb), call. = FALSE, immediate. = TRUE)
      }
    }
    .biome_env$original_dangerous_func(...)
  }
  attr(safe_dangerous_func, "biome_guard") <- TRUE
  pkg_env <- asNamespace("pkg")  # or baseenv() for base R
  if (bindingIsLocked("dangerous_func", pkg_env)) unlockBinding("dangerous_func", pkg_env)
  assign("dangerous_func", safe_dangerous_func, envir = pkg_env)
  lockBinding("dangerous_func", pkg_env)
}, error = function(e) NULL)
```

**After adding a guard:**

1. Edit `templates/Rprofile_site.R.template`
2. Run `sudo bash scripts/50_setup_nodes.sh` → option 3 (Config files only)
3. The script validates R syntax before deploying; will rollback on parse error
4. Test: `Rscript --vanilla -e "source('/etc/R/Rprofile.site'); cat('OK\n')"`
5. Restart RStudio: `sudo systemctl restart rstudio-server`

### Step 7: Common Botanical Script Fixes (Copy-Paste to Send Users)

These are the most frequent rewrites you'll need to suggest:

**Problem: `as.matrix(dist(big_data))` → OOM**

```r
# BEFORE (crashes on >15,000 observations):
d <- dist(community_matrix)
m <- as.matrix(d)  # ← This doubles the RAM usage

# AFTER (use dist object directly, never convert to full matrix):
d <- dist(community_matrix)
# Most functions accept dist objects directly:
hc <- hclust(d)                    # Works with dist, no as.matrix needed
nmds <- vegan::metaMDS(d)          # Works with dist directly
# If you MUST have a matrix, use sparse:
# install.packages("Matrix")
# m_sparse <- Matrix::Matrix(as.matrix(d), sparse = TRUE)
```

**Problem: `do.call(rbind, lapply(files, read.csv))` → O(n²) copies**

```r
# BEFORE (copies entire data frame on each rbind):
all_data <- do.call(rbind, lapply(csv_files, read.csv))

# AFTER (use data.table::rbindlist — zero-copy):
library(data.table)
all_data <- rbindlist(lapply(csv_files, fread))
```

**Problem: `ggplot()` on millions of points → RStudio render freeze**

```r
# BEFORE (renders all 5 million points):
ggplot(occurrence_data, aes(lon, lat)) + geom_point()

# AFTER (hex-bin aggregation — instant render):
ggplot(occurrence_data, aes(lon, lat)) +
  geom_hex(bins = 100) +
  scale_fill_viridis_c()
```

**Problem: `raster::stack("*.tif")` → loads all in RAM**

```r
# BEFORE (legacy raster — loads everything into RAM):
s <- raster::stack(list.files(".", "*.tif", full.names=TRUE))

# AFTER (terra — file-backed, uses /Rtmp automatically):
r <- terra::rast(list.files(".", "*.tif", full.names=TRUE))
# terra keeps data on disk, only loads tiles into RAM on demand
```

**Problem: Large NIMBLE model compiles → temp disk spike + RAM**

```r
# BEFORE (no control over compilation resources):
cModel <- compileNimble(model)

# AFTER (BIOME-CALC already routes compilation, but add explicit control):
# Check available resources first:
status()
# If RAM quota < 50GB, reduce model complexity or run overnight
# NIMBLE compilation is automatically routed to NFS ($HOME/.nimble_compile/)
# Compiler scratch uses /Rtmp (safe, 400GB local disk)
```

### Step 8: Post-Incident Report Template

After resolving a crash, leave a note for future reference:

```bash
# Append to the incident log
cat >> /var/log/biome-log/incident_log.txt << EOF
=== INCIDENT: $(date -Iseconds) ===
User:     <username>
Symptom:  <what user reported>
Cause:    <OOM / SIGSEGV / NFS / etc>
Function: <solve() / dist() / as.matrix() / etc>
Data size: <N rows × M cols, ~X GB>
Guard:    <fired / did not fire / no guard exists>
Fix:      <script rewrite / new guard / resource increase>
Action:   <what you did>
Status:   <resolved / workaround / needs guard development>
EOF
```

---

## Emergency Runbook: Full System Recovery

When everything is broken and users are calling:

```bash
# 1. Stop the bleeding
sudo systemctl stop rstudio-server    # Prevent new sessions
sudo systemctl stop ollama.service    # Free 24GB RAM

# 2. Kill all orphan R processes
ps -eo pid,ppid,args | awk '$2 == 1 && /R|Rscript/' | awk '{print $1}' | xargs -r kill -KILL

# 3. Check/fix critical services
sudo systemctl start nginx
mount | grep nfs || sudo mount -a     # Remount NFS if missing
df -h /Rtmp                           # Verify temp disk

# 4. Verify BLAS is serial
update-alternatives --display libblas.so.3-x86_64-linux-gnu | head -3

# 5. Restart services
sudo systemctl start rstudio-server
sudo systemctl start ollama.service   # Optional, can delay

# 6. Validate
curl -sIk http://127.0.0.1:8787 | head -1  # Should show HTTP 200 or 302
Rscript --vanilla -e "A<-matrix(1:4,2,2); solve(A); cat('R OK\n')"

# 7. Run health check
sudo bash scripts/99_health_check.sh

# 8. Collect debug bundle for post-mortem
sudo bash scripts/99_troubleshoot_env.sh --all --collect
# Bundle saved to /tmp/rstudio_debug_bundle_<timestamp>.tar.gz
```

---

## Architecture Decision Record: Why We Made These Choices

| Decision | Alternative | Why We Chose This |
|:---|:---|:---|
| Serial OpenBLAS over Pthread | Keep pthread + `OPENBLAS_NUM_THREADS=1` | Pthread still spawns its thread pool even with NUM_THREADS=1; serial has no pool at all |
| 400GB local disk over tmpfs for `/Rtmp` | 100GB tmpfs (the original design) | tmpfs eats RAM; a 15GB NIMBLE compile would consume 15GB of "RAM" that R also needs |
| NFS user homes over local disk | Local disk with backup scripts | Local disk = data loss on hardware failure; NFS + ZFS = enterprise-grade resilience |
| Dynamic threads over static | Hardcode `OMP_NUM_THREADS=8` | Static is unfair: 1 user wastes unused threads; 10 users contend. Dynamic adapts |
| Function interception (guards) over `ulimit` | System-level `ulimit -v` | `ulimit` kills the process hard; guards warn the user and REDUCE work, keeping the session alive |
| Orphan cleanup via cron over systemd scope | `systemd-run --scope` per session | RStudio OSS doesn't support custom session wrappers; cron is reliable and auditable |

---

## PAM `passwd` SIGSEGV on AD-joined nodes (local users)

### Symptom

A local system administrator account (e.g. `ladmin`, uid in the 1000–9999 range) runs
`passwd` on an AD-joined node and the process dies:

```
$ passwd
Changing password for ladmin.
Current password:
Segmentation fault (core dumped)
```

`dmesg` / `journalctl -k` shows a segfault in `pam_krb5.so`:

```
passwd[12345]: segfault at 0 ip 00007f... in pam_krb5.so[...]
```

### Root cause

Ubuntu's `libpam-krb5` package installs a `pam-auth-update` profile named **krb5**
that inserts `pam_krb5.so` into `/etc/pam.d/common-password`. With our multi-realm
`/etc/krb5.conf` (`DIR.UNIBO.IT` default + `AD.EXAMPLE.COM` +
`STUDENTI.DIR.UNIBO.IT` sub-realms and the capaths matrix), `pam_krb5.so` dereferences
a NULL realm pointer when the target principal does not exist in the default realm —
which is **always** the case for local accounts (uid < 10000 per
`config/join_domain_samba.vars.conf` idmap ranges).

The segfault is triggered by `passwd`, by `su`, and by any PAM consumer that runs
the `password` stack for a local user.

### Fix (repo-level, permanent)

The fix is intentionally minimal: **remove `libpam-krb5` entirely**. The
default Debian/Ubuntu `pam-auth-update` stack (`pam_unix` + `pam_sss` OR
`pam_winbind`, with success-branching) already routes local users
(uid < 10000) to `pam_unix` and AD users (uid ≥ 10000) to the AD module.
**No custom pam-config profile is needed.**

> ⚠️ Older releases shipped a custom `pam-auth-update` profile named
> `biome-localguard` (Priority 900, injecting `pam_succeed_if uid >= 10000`
> into `common-password`). That guard was incompatible with the Ubuntu 24.04
> "`pam_unix` first" layout and produced **"Authentication token manipulation
> error"** when local users ran `passwd`. It has been **removed**. Both the
> primary and retrofit scripts now actively **purge** it.

1. **`libpam-krb5` is no longer installed.** Removed from:
   - `scripts/12_lib_kerberos_setup.sh`
   - `scripts/30_install_nginx.sh`
   - `next_gen/ansible/roles/kerberos/tasks/main.yml`

2. **`scripts/13_harden_pam_password.sh`** now does strip-and-regenerate only:
   - Backs up `/etc/pam.d/common-*` to `/root/pam-backup-<ts>/`
   - Removes `/usr/share/pam-configs/biome-localguard` (obsolete) and
     `/usr/share/pam-configs/krb5` (leftover from libpam-krb5)
   - Strips any dangling `pam_krb5.so` lines from every `common-*`
     (critical: a dangling line in `common-account` breaks `sudo` with
     *"Module is unknown"*)
   - Strips any legacy `pam_succeed_if.so ... uid >= 10000` guard lines
   - Truncates hand-edits **after** the `# end of pam-auth-update config`
     marker (rogue `pam_deny requisite` lines that reject local users tend
     to live there)
   - Runs `pam-auth-update --force --package` to regenerate the managed
     block

3. **`scripts/fix_pam_segfault_inplace.sh`** is the retrofit for already-
   deployed nodes. Same logic as above, plus `apt-get purge libpam-krb5`
   if still installed. Supports `--check` (dry-run) and `--rollback` modes.

4. `scripts/10_join_domain_sssd.sh` and `scripts/11_join_domain_samba.sh`
   call `pam-auth-update` with `--disable krb5` and invoke
   `scripts/13_harden_pam_password.sh` at the end of `configure_pam()`.

### What is lost (and why it's acceptable)

Only one feature is sacrificed: **`pam_ccreds action=validate` offline
Kerberos TGT validation** during login. This is compensated by
`pam_winbind`'s `cached_login = yes` / `pam_sss`'s
`cache_credentials = True`, which already provide offline auth for AD
users via the SSSD/winbind cache. Local users (uid < 10000) never used
Kerberos in the first place.

Nothing else changes: AD login, kinit-on-login (via `pam_sss` /
`pam_winbind` internals), NSS resolution, Samba home shares, GSSAPI to
NFS — all unaffected.

### Verification

On any AD-joined node, after running `scripts/10_join_domain_sssd.sh`,
`scripts/11_join_domain_samba.sh`, or the retrofit script:

```bash
# 1. pam_krb5.so must be absent from EVERY common-* (incl. common-account)
sudo grep -n pam_krb5 /etc/pam.d/common-*          # must print nothing

# 2. No legacy biome-localguard guard lines
sudo grep -n 'uid >= 10000' /etc/pam.d/common-*    # must print nothing

# 3. Neither obsolete pam-config profile must remain
ls /usr/share/pam-configs/krb5            2>/dev/null   # must be missing
ls /usr/share/pam-configs/biome-localguard 2>/dev/null  # must be missing

# 4. Nothing past the end-marker in common-* (hand-edits purged)
for f in /etc/pam.d/common-{account,auth,password,session,session-noninteractive}; do
    awk '/^# end of pam-auth-update config/{f=1;next} f && NF && !/^[[:space:]]*#/ {print FILENAME": leftover: "$0}' "$f"
done   # must print nothing

# 5. AD provider still present in common-auth
grep -E 'pam_(sss|winbind)\.so' /etc/pam.d/common-auth   # must match

# 6. Functional test — local user (this is what we originally broke)
sudo -u ladmin passwd       # normal prompt, completes with "password updated successfully"

# 7. Functional test — sudo still works (common-account integrity)
sudo -u ladmin sudo -n true 2>&1 | head       # no "Module is unknown"

# 8. Functional test — AD user
su - some.ad.user -c id                       # must resolve via winbind/sss
```

### Emergency recovery (already-broken node)

If `passwd ladmin` fails with "Authentication token manipulation error" or
segfaults, run **one** of the following from inside the repo checkout:

```bash
# Full retrofit (preferred):
sudo ./scripts/fix_pam_segfault_inplace.sh

# Diagnose first (no changes):
sudo ./scripts/fix_pam_segfault_inplace.sh --check

# Or, if the repo is not available, the equivalent hand-fix:
sudo rm -f /usr/share/pam-configs/biome-localguard /usr/share/pam-configs/krb5
for f in /etc/pam.d/common-{account,auth,password,session,session-noninteractive}; do
    [ -f "$f" ] || continue
    sudo sed -i -E '/^[^#]*pam_krb5\.so/d' "$f"
    sudo sed -i -E '/pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000/d' "$f"
    sudo awk '/^# end of pam-auth-update config/{print; seen=1; next} seen{next} {print}' "$f" \
        | sudo tee "$f.new" >/dev/null && sudo mv "$f.new" "$f" && sudo chmod 0644 "$f"
done
sudo DEBIAN_FRONTEND=noninteractive pam-auth-update --force --package
sudo passwd ladmin   # smoke test
```

### Rollback

Both scripts leave timestamped backups in `/root/pam-backup-<ts>/` and the
retrofit also publishes the symlink `/root/pam-backup-latest`. Restore:

```bash
sudo ./scripts/fix_pam_segfault_inplace.sh --rollback
# …or manually:
sudo cp -a /root/pam-backup-latest/common-* /etc/pam.d/
```

**Do NOT reinstall `libpam-krb5` without also removing
`/usr/share/pam-configs/krb5`** — the segfault will return immediately.
