# Understanding the New BIOME-CALC Server

> A guide for Botanical and Lichenological Researchers to understanding the new infrastructure, why your scripts might behave differently, and how the new server protects your research.

---

## 1. "My script worked perfectly on the old server. Why did it stop or give a warning here?"

If your R script just stopped and displayed a yellow `BIOME-CALC` warning, your first instinct might be that something is broken on the new server. In reality, **the server just did exactly what it was designed to do: it stopped your script from freezing the entire machine.**

### The Flaw in the Old Server
On the old desktop workstation, there were no safety limits. If you ran a script that requested 30 gigabytes of RAM or tried to use 32 CPU cores, the old server would blindly give it to you. 

This felt "fast" if you were the *only* person using the server at 2:00 AM. 

But what happened when three researchers returned from the field and clicked "Run" on similar scripts at 10:00 AM? The scripts violently collided. They fought for the exact same CPUs, the memory filled up instantly, and the entire server crashed (often silently logging an "OOM Kill" or "SIGSEGV" before disconnecting everyone). **When the server crashed, everyone lost their current work.**

### The New Architecture: Fair-Share & Memory Guards
The new BIOME-CALC server uses enterprise-grade **Pessimistic Engineering**. It assumes that multiple people are using the system simultaneously. 

When you run a heavy command (like `solve()`, `dist()`, or `expand.grid()`), the server mathematically calculates how much memory it will take *before* it tries to run it. 

- If it's safe to run, you won't notice a thing.
- If it threatens to consume all the server's memory, the **Memory Guard** will intervene. It will print a yellow warning message to your console and actively slow your script down (by limiting its CPU threads) or safely stop it, rather than letting it crash the server for you and your colleagues.

**When your script gets a warning, it means the server just saved you and your colleagues from a total crash.**

---

## 2. "Why does my script seem slower?"

During heavy calculations, you might notice that processes take a bit longer than they did on the old server when it was empty.

**Why this is happening:**
On the old server, your scripts were automatically set to use **all 32 CPU cores**, regardless of who else was logged in. If 5 people were logged in, 160 processing threads were fighting for 32 physical cores. This is called "CPU Thrashing" and it causes massive invisible slowdowns and random disconnects.

**The Solution:**
The new BIOME-CALC server dynamically calculates a **"Fair-Share"** of the CPUs. If you are alone, you get maximum power. If 5 researchers are running scripts simultaneously, you will automatically be assigned ~6 dedicated, uninterrupted CPUs. 

While it might look slower on paper, the math is actually completing more reliably because the CPUs are no longer destroying each other fighting for priority.

---

## 3. The Massive Benefits of the New Architecture

While the new safety limits might require minor tweaks to your R code, the new architecture provides massive, enterprise-level benefits to your daily research:

### 🛡️ 1. Absolute Data Safety (Zero Data Loss)
The old server kept your data on a single local hard drive. If that drive died, your research was gone forever. 
The new BIOME-CALC architecture runs on a dedicated Enterprise Storage Array (TrueNAS). Your data is spread across multiple redundant disks with **Automatic Daily Snapshots**. If you accidentally delete a file, or if a hard drive physically explodes, your data is completely safe. The computational RStudio server is kept entirely separate from your data.

### 🏃 2. 5-Second Package Installations
Have you ever tried to install geospatial packages like `sf` or `terra` on the old server, and waited 30 minutes while lines of C++ code scrolled down your screen? 
The new server uses a binary package manager (`bspm`). Simply type `install.packages("sf")` and it will securely download the pre-compiled version in **under 5 seconds** without requiring sysadmin intervention.

### 📁 3. Drag-and-Drop Cloud Uploads (Nextcloud)
You no longer have to use complex VPNs and SFTP clients to move files. You can just open the BIOME-CALC Web Portal, click on "Files" (Nextcloud), and drag CSV or TIFF files straight from your laptop. They instantly appear in your RStudio session.

### 🧠 4. Built-in AI Assistant
Stuck on a line of code? Don’t know how to run a PERMANOVA in the `vegan` package? BIOME-CALC now hosts an offline AI Assistant. You can run the `ask_ai("How do I...")` command directly in your R console to get immediate help tailored to R, without ever leaving your workflow or uploading your data to the internet.

### 🔄 5. Multi-Day Computations (NIMBLE / Bayesian)
If you run heavy MCMC chains using NIMBLE, the new architecture completely isolates your temporary compilation files onto a dedicated 400 GB ultra-fast disk (`/Rtmp`). This means your 16-hour long Bayesian models will no longer suffer from unexpected OS memory resets.

---

## 4. What to do if your script is stopped?

If a Memory Guard stops your script, **the problem is usually an inefficient approach to large data**, not the server itself. 

1. **Read the Yellow Warning**: The server usually tells you exactly what went wrong (e.g., *"Trying to create a distance matrix on 50,000 observations"*).
2. **Use Sparse Matrices**: If you are using `dist()` on thousands of points, look into spatial packages (`sf`, `terra`) instead of forcing R to calculate a billion pairwise distances in standard RAM.
3. **Avoid `expand.grid`**: If you are combining massive columns, consider using `data.table::CJ()`, which is vastly more memory efficient.
4. **Clean your Environment**: Memory adds up. Periodically click the "Broom" icon in the Environment tab to clear dataframes you are no longer using.
5. **Ask your SysAdmin**: If you are certain your script is optimized and you still need more power, send a quick email to the Sysadmin with a copy of the yellow warning message. They can whitelist your specific session for higher limits.
