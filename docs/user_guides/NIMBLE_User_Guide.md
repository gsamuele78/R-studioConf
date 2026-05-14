# BIOME-CALC: Guide for Heavy Bayesian MCMC Computations (NIMBLE/nimbleHMC)

> **For researchers running long Bayesian simulations (NIMBLE, TMB, Stan) on the shared RStudio server.**
> Last updated: April 2026 | BIOME-CALC v10.0

---

## 1. How Sessions Work on This Server

When you work on BIOME-CALC through your browser:

- **Closing your browser tab does NOT kill your computation.** Your R session keeps running in the background for up to **7 days**.
- **When you reconnect**, you will need to **re-login** (enter username and password again — this is normal for the OSS version of RStudio).
- **After re-login, RStudio reconnects you to your EXISTING session automatically.** All your variables are still in memory. Any running computation (e.g., `runMCMC()`) is still going. You do NOT need to do anything special.

### Step-by-step: What happens when you close the tab

```
1. You close the browser tab
   → Your R session keeps running on the server (up to 7 days)
   → Your MCMC computation continues in the background

2. Hours later, you come back and re-login
   → RStudio finds your existing session
   → You see your same R console, same variables, same history
   → If runMCMC() finished, the results are in your environment
   → If it's still running, you see output continuing

3. You do NOT need biome_load_session() — everything is already there
```

### When do you need `biome_load_session()`?

**Only if you get a brand new empty session** — this means your old session crashed while you were away. In that case:

```r
# Restore your last saved workspace
biome_load_session()
```

> ⚠️ `biome_load_session()` restores **saved variables** from your last `biome_save_session()`. It does NOT restore running computations. If your MCMC was running when the session crashed, you need to re-run it.

### Best practice: Always save before disconnecting

```r
# Before closing the tab for a long MCMC run:
biome_save_session()    # saves your current variables as a safety net

# Then close the tab — your MCMC keeps running
# When you come back, your session is intact (variables + running computation)
# The saved session is your "insurance" in case the session crashes
```

> **Important:** This server has safety guards that optimize memory and CPU for all users. These guards are designed to be invisible for normal work, and are NIMBLE-aware so they won't interfere with Bayesian MCMC computations.

---

## 2. Running NIMBLE MCMC (Step by Step)

### Before Starting

1. **Check server resources:**

   ```r
   status()
   ```

   This shows your RAM quota, CPU allocation, and how many users are active.

2. **Save any existing work (safety net):**

   ```r
   biome_save_session()
   ```

### Running the Model

The server automatically:

- Routes NIMBLE's C++ compilation to **NFS storage** (slower but reboot-safe for 16h+ runs)
- Uses the **local /Rtmp disk** for compiler scratch files (fast, no RAM cost)
- Caps threads to prevent overloading the shared CPU
- Protects your compilation files from being cleaned up

You will see a message like:

```
🧪 BIOME-CALC: NIMBLE compilation routed to NFS (~/.nimble_compile/session_12345).
   Thread cap: 4 per chain. Safe for multi-chain MCMC.
```

### While It's Running

- ✅ **You CAN close your browser tab** — the computation continues
- ✅ **You CAN reconnect later** — re-login and you'll see your same session with all variables
- ✅ **You do NOT need `biome_load_session()`** — your session is automatically reconnected
- ⚠️ **Wait for `compileNimble()` to finish** before closing the tab (compilation is the fragile phase; once `runMCMC()` starts, it's safe)
- ❌ **Do NOT open a second RStudio tab** in a different browser — this may conflict with your running session

---

## 3. Multi-Chain MCMC Best Practices

When running multiple chains (e.g., `nchains = 4`):

### Start Small

```r
# First: 1-chain crash test (5-10 minutes)
post_samples_1ch <- runMCMC(Cmcmc, niter = 200, nburnin = 50, nchains = 1)

# Then: Full production run
post_samples <- runMCMC(Cmcmc, niter = 10000, nburnin = 2000, nchains = 4)
```

### Memory Estimation

Each NIMBLE chain with `buildDerivs = TRUE` can use 8-15 GB of RAM during C++ compilation. For 4 chains:

| Chains | Estimated RAM | Recommended? |
|--------|--------------|--------------|
| 1 | 8-15 GB | ✅ Always safe |
| 2 | 16-30 GB | ✅ Safe |
| 4 | 32-60 GB | ✅ Safe (server has 400 GB) |
| 8+ | 64-120 GB | ⚠️ Check `status()` first |

---

## 4. What Changed From the "Old Server"

The old server had **no resource management**. This meant:

- ✅ Your code ran with no interference
- ❌ One user's `solve()` on a large matrix could crash the server for everyone
- ❌ No warnings before running out of memory
- ❌ No automatic cleanup of orphaned processes eating CPU

The new server adds **safety guards** that:

- Warn you before operations that would crash the server
- Automatically manage threads and memory per user
- Clean up orphaned processes from crashed sessions
- Route heavy computation to safe storage

**These guards are now NIMBLE-aware** and will not interfere with your Bayesian MCMC pipelines.

---

## 5. Troubleshooting

### "I Got a New Session Instead of My Old One"

This means your previous session crashed. Common causes:

1. **OOM kill** — Check for `~/ULTIMO_CRASH_RAM.txt`
2. **Session timeout** — Sessions expire after 7 days of inactivity
3. **Server restart** — Ask the admin if the server was restarted

**What to do:**

```r
# Check if your saved session exists
biome_load_session()

# Check crash log
file.exists("~/ULTIMO_CRASH_RAM.txt")
```

### "compileNimble() Takes Very Long"

NIMBLE's C++ compilation artifacts are routed to NFS storage for reboot safety.
Compiler scratch files (intermediate `.o` files) use the local `/Rtmp` disk, which is fast and doesn't consume RAM.
This combination provides both safety and good performance.

Typical compile times:

- Simple model: 2-5 minutes
- Complex model (10+ variables, `buildDerivs=TRUE`): 10-30 minutes
- First compilation is slowest; subsequent `compileNimble()` calls are faster

### "R Session Aborted" During MCMC

If you see this error, contact the admin with:

1. The model code that caused the crash
2. The output of `status()` before the crash (if available)
3. The approximate time of the crash

---

## 6. Commands Reference

| Command | What it does |
|---------|-------------|
| `status()` | Show RAM quota, CPU, active users, tmpfs health |
| `biome_save_session()` | Save all variables to `~/biome_session_backup.RData` |
| `biome_load_session()` | Restore saved variables |
| `biome_plot_budget()` | Check if tmpfs has space for plots |
| `biome_help()` | Show all available commands |
| `biome_tutorial()` | Code examples for common tasks |

---

## 7. Contact

For technical issues or server problems:

- **Email:** <Lifewatch_Biome_internal@live.unibo.it>
- **Subject line:** Include "BIOME-CALC" and a brief description
