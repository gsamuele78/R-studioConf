# BIOME-CALC v10: Infrastructure Architecture Guide for Researchers

> A technical overview of the new BIOME-CALC server architecture, focusing on quantitative improvements in stability, concurrent processing, and data integrity compared to the legacy environment.

---

## 1. Concurrent Execution and the "Memory Guard" System

If an R execution is interrupted with a `BIOME-CALC` warning, it is due to a deterministic safety mechanism designed to maintain system-wide stability.

### 1.1 Resource Contention in the Legacy Architecture
The previous environment operated on a static resource allocation model. For example, environment variables (`OPENBLAS_NUM_THREADS`) were hardcoded to 32 cores for all users. 

**The Statistical Reality:**
While this maximized single-user performance when the server was empty, it failed mathematically under concurrent load. If 5 researchers executed functions like `solve()` or `crossprod()` simultaneously, the system generated 160 active processing threads competing for 32 physical cores.
* **Result:** Extreme CPU context-switching (thrashing), exponential thermal degradation, and ultimately a kernel-level `OOM Kill` (Out of Memory) or `SIGSEGV` fault, resulting in total data loss for all active sessions.

### 1.2 The BIOME-CALC Solution: Dynamic Fair-Share Algorithm
The new architecture replaces static assignment with a dynamic allocation mechanism.
* **CPU Balancing:** The server actively monitors the number of concurrent `rsession` processes and mathematically divides the available vCores. Under heavy multi-tenant load, a user is deterministically assigned a dedicated slice (e.g., 6 isolated threads) ensuring 100% computational efficiency without context-switching overhead.
* **Pre-computation Memory Modeling (Guards):** Before executing known high-load Base R functions (`solve()`, `dist()`, `expand.grid()`), the server calculates the theoretical RAM footprint. For instance, inverting a matrix requires `~2.06 × matrix_size` in RAM. If the calculation exceeds available system memory, the environment safely pauses the script and alerts the user, preventing a system-wide kernel panic.

---

## 2. Measurable Infrastructure Advantages

The architectural upgrade introduces structurally different paradigms that provide measurable improvements to daily research workflows:

### 🛡️ 2.1 Enterprise Data Integrity (Zero-Loss Architecture)
* **Legacy:** Local single-point-of-failure storage.
* **Current:** Storage is decoupled onto a TrueNAS Enterprise Array utilizing the ZFS filesystem. It features RAID-Z2 redundancy and automated cryptographic snapshots. Node hardware failures no longer result in data loss. 

### 🏃 2.2 Compilation Efficiency (5-Second Installs)
* **Legacy:** Packages like `sf` or `terra` required source compilation against standard libraries, averaging 20–30 minutes per installation.
* **Current:** Integration with the `bspm` (binary system package manager) and `r2u` repositories bypasses compilation entirely. Geospatial libraries download and mount pre-compiled binaries in under 5 seconds.

### 💻 2.3 Secure Web Terminal Integration
* **Legacy:** Required third-party clients (PuTTY), complex SSH key management, and VPN configurations.
* **Current:** Built-in `ttyd` integration securely connects to the underlying Linux container via an authenticated WebSockets iframe. Standard university Identity Providers (AD/Kerberos) handle authentication seamlessly.

### 📁 2.4 Cloud-Native WebDAV Uploads (Nextcloud)
* **Legacy:** Relied on SFTP protocols causing workflow friction.
* **Current:** A fully integrated Nextcloud instance provides a standard drag-and-drop web interface for importing `.csv` and `.tiff` datasets directly into the RStudio `Home` directory.

### 🔄 2.5 Multi-Day MCMC Safety (NIMBLE / Bayesian)
* **Legacy:** Standard `/tmp` directories were mounted on RAM (`tmpfs`). A large `compileNimble()` execution could consume 15 GB of RAM for `cc1plus` `.o` scratch files, starving the actual R process.
* **Current:** The architecture provisions a dedicated 400 GB virtio disk specifically mounted at `/Rtmp`. 16-hour long Bayesian MCMC chains are isolated from the OS memory pool, eliminating memory-induced termination.

---

## 3. Resolving Resource Threshold Interventions

When a script triggers a BIOME-CALC Memory Guard, it indicates that the requested data transformation exceeds the mathematical limits of a single-node memory pool. This is common in modern high-resolution spatial ecology.

**Statistically Validated Optimizations:**
1. **Analyze the Warning Data:** The console output calculates exactly how much data was attempted (e.g., "Attempted O(n²) calculation on 50,000 spatial points").
2. **Implement Sparse Matrices:** Functions like `dist()` attempt to materialize billions of zeroes in standard RAM. Transitioning to `sf` or `terra` spatial distances utilizes C++ routines optimized for sparse geographic representations.
3. **Transition to Data Tables:** `expand.grid()` scales exponentially. Using `data.table::CJ()` performs Cartesian joins using pointer references, reducing RAM overhead by up to 80%.
4. **Utilize the Offline AI Assistant:** The environment hosts a local LLM via Ollama (`ask_ai("How do I convert this to a sparse matrix?")`), allowing researchers to query R optimization strategies without transmitting proprietary data externally.
