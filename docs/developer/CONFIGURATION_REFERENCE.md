# Configuration Reference: The `.vars.conf` Dictionary

The `config/` directory acts as the central state dictionary. Scripts are mostly agnostic logic units; they pull their environment from these `*.vars.conf` files.

This model separates code (the `scripts/`) from data (the `config/`), making the repository highly reusable across development, staging, and production clusters.

To override a variable safely, edit the corresponding `.vars.conf` file before running the installation script.

---

## 1. `setup_nodes.vars.conf`

This is the primary manifest for hardware, storage, and application variables. Governs `50_setup_nodes.sh` and related cronjobs.

### Infrastructure & Networking

* `BIOME_HOST`: The system hostname. Injected into RStudio welcome banners. Autodetected if empty.
* `BIOME_IP`: Public/WAN IP address. Autodetected via `hostname -I` if left blank.

### Storage & Mounts

* `NFS_HOME` (Default: `/nfs/home`): The root directory where AD users' home folders reside. Critical for the Archive script which iterates over `/nfs/home/*`.
* `CIFS_ARCHIVE` (Default: `/mnt/ProjectStorage`): The destination tree where deactivated project files are archived by the daily cronjob.
* `RAMDISK_SIZE` (Default: `100G`): The capacity of the `tmpfs` partition mounted on `/tmp`. Massive RAMDisks are required to compile C++ libraries (e.g., `arrow`, `terra`) quickly via R.
* `SWAP_FILE` (Default: `/swap.img`) & `SWAP_SIZE_GB` (Default: `32`): The instantaneous swap layer generated via `fallocate` during master node setup.

### Compute Tuning (OpenBLAS & Cgroups)

* `VM_VCORES` & `VM_RAM_GB`: Hardware visibility metrics injected into R for diagnostic reference, compensating for imperfect container awareness in baseline R binaries.
* `MAX_BLAS_THREADS` (Default: `16`): The hard cap for OpenMP and OpenBLAS multithreading. Implemented to prevent hypervisor thread-thrashing when large parallel workloads intersect.

### External Dependencies

* `PYTHON_ENV` (Default: `/opt/r-geospatial`): The strict path where the geospatial Python `venv` is built. R's `reticulate` is permanently bound to this path `/bin/python`.
* `PYTHON_PACKAGES=(...)`: Array of Python binaries `pip` installed globally.
* `R_PACKAGES=(...)`: Array of CRAN binaries compiled via `bspm` and `apt`.

### Service Settings

* `SKIP_OLLAMA` (Default: `false`): Feature toggle to bypass the heavy Llama.cpp/Ollama AI subsystem compilation.
* `SMTP_HOST` & `SENDER_EMAIL`: SMTP configurations utilized by the Orphan Cleanup script to email AD users when CPU time is violated.

---

## 2. `r_env_manager.conf`

Governs the operational upgrades managed via the root `r_env_manager.sh` script.

* `R_REPO`: The CRAN mirror endpoint (e.g., `https://cloud.r-project.org`).
* `CRAN_KEY_URL`: The GPG keyserver endpoint to strictly authenticate downloading signed `.deb` payload blocks.
* `JAVA_HOME_PATH`: Set explicitly or leave empty for dynamic `readlink` discovery based on `update-alternatives`.

---

## 3. `telemetry_api.vars.conf` (Internalized)

Telemetry variables are mostly derived from Nginx configurations, but specific constants include:

* `TELEMETRY_PORT` (Default: `8000`): The local interface binding. Must be blocked by `ufw`/`iptables` externally as the endpoint lacks auth; it relies entirely on Nginx routing.

---

## 4. Operational Maps (`admin_recipients.txt`, `user_email_map.txt`)

* `admin_recipients.txt`: Plaintext list of system admin emails. Problem Reports initiated from the web portal's Javascript Modal dispatch via the Python backend to these addresses.
* `user_email_map.txt`: An override dictionary formatted as `username:email@domain.com`. The `get_user_email()` library function checks this first before falling back to AD GECOS parsing. Used for headless service accounts.
