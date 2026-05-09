<!-- docs/operations/CLEAN_VM_BASELINE.md -->
# Clean-VM Baseline — HC-13 L4 Reference SOP

**Audience:** sysadmin / IT officer.
**Status:** normative SOP for the L4 layer of the HC-13 escalation ladder.
**Prerequisite:** L0..L3 already exhausted via
`scripts/99_diagnose_user_script.sh` with no clear verdict.

---

## Responsibility Boundaries (HC-13 — read first)

> *We adapt system → profile → fragments → env so that portable user R code
> keeps working. **We do not patch user scripts.** When the system has been
> exhausted and the failure persists, the clean-VM baseline (L4) proves
> whether the residual issue is in the user's code or upstream.*

The clean VM is the **adjudicator**. It strips away every BIOME-specific
layer (NFS, AD/SSSD, profile dispatcher, fragments, container limits,
`/Rtmp`, custom BLAS) and runs the user's `.R` against a stock Debian +
stock CRAN R + local ext4 disk.

- If the script **passes** on the clean VM → the failure is
  production-VM-specific (NFS, fragment, cgroup) → fix lands in
  `templates/` or `scripts/50_setup_nodes.sh`.
- If the script **fails identically** on the clean VM → the failure is in
  the user's code or in an upstream package → escalate to **L5** with
  evidence.

The user's `.R` file is **read but never written** in this SOP.

---

## Reference VM specification

The clean VM must be **boring**. Resist the temptation to mirror
production "more closely" — that defeats the purpose of L4.

| Resource | Value | Rationale |
|----------|-------|-----------|
| vCPU | **1 socket × 16 cores** (no SMT) | matches a typical biome-calc node footprint without cgroup overcommit |
| RAM | **64 GB** | enough for terra + NIMBLE on a single chunk; not so much that it hides OOM bugs |
| Disk | **500 GB single ext4 LVM**, mounted at `/`, 4K block size, `noatime` | NO NFS, NO ZFS, NO tmpfs over `/Rtmp` |
| Network | NAT only | no domain join, no Kerberos, no LDAP |
| OS | **Debian 12 stable**, fresh netinst, **no unattended-upgrades during the test** | matches production base, but stock |
| R | install from CRAN apt repo: `r-base r-base-dev` at the **same major.minor** as production | `R --version` must match |
| BLAS | **`libopenblas0-serial`** via `update-alternatives` | matches production BLAS choice (HC §6.1) |
| Packages | install only what `library()` calls in the user script require, from CRAN binary | no biome packages, no profile fragments |
| Profile | **NONE** — explicitly: `R_PROFILE=/dev/null R_PROFILE_USER=/dev/null R_ENVIRON=/dev/null R_ENVIRON_USER=/dev/null` | no Rprofile.site, no Renviron.site, no fragments |
| User | local Linux user `clean`, UID 1000, no AD | NFS perms / SSSD / Kerberos cannot influence |

**Hostname convention:** `clean-vm-<YYYYMMDD>` (so the report attributes
results to the right snapshot).

---

## Provisioning (one-shot, scripted)

```bash
# On a libvirt/KVM host (or any hypervisor — sandbox/Vagrantfile is BROKEN, see §8 of agents.md)
virt-install \
  --name clean-vm-$(date +%Y%m%d) \
  --vcpus sockets=1,cores=16,threads=1 \
  --memory 65536 \
  --disk size=500,format=qcow2,bus=virtio,cache=none \
  --network network=default \
  --location 'https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/' \
  --os-variant debian12 \
  --graphics none --console pty,target_type=serial \
  --extra-args 'console=ttyS0,115200n8 auto=true priority=critical'
```

Inside the VM, after first boot, run the **clean-vm-bootstrap** snippet:

```bash
#!/bin/bash
# clean-vm-bootstrap.sh — runs once inside the freshly installed VM
set -euo pipefail
RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; NC=$'\e[0m'

# 1) APT pinning — block accidental upgrades during the test
apt-mark hold linux-image-amd64 linux-headers-amd64 || true

# 2) Stock R from CRAN
apt-get update
apt-get install -y --no-install-recommends \
    r-base r-base-dev \
    libopenblas0-serial \
    libgdal-dev libproj-dev libgeos-dev libudunits2-dev \
    git curl jq build-essential

# 3) Force serial BLAS (match production)
update-alternatives --set libblas.so.3-x86_64-linux-gnu \
    /usr/lib/x86_64-linux-gnu/openblas-serial/libblas.so.3
update-alternatives --set liblapack.so.3-x86_64-linux-gnu \
    /usr/lib/x86_64-linux-gnu/openblas-serial/liblapack.so.3

# 4) Strict no-profile environment
cat > /etc/profile.d/clean-vm-no-rprofile.sh <<'EOF'
export R_PROFILE=/dev/null
export R_PROFILE_USER=/dev/null
export R_ENVIRON=/dev/null
export R_ENVIRON_USER=/dev/null
export R_LIBS_SITE=
EOF
chmod 0644 /etc/profile.d/clean-vm-no-rprofile.sh

# 5) Local user, local home, local workdir
id clean &>/dev/null || useradd -m -u 1000 -s /bin/bash clean
install -d -o clean -g clean -m 0755 /home/clean/work

echo "${GREEN}clean-vm-bootstrap: done. Reboot, then SSH in as 'clean'.${NC}"
```

Snapshot the VM here (`clean-vm-<DATE>-pristine`). Every L4 test starts
from this snapshot and is **discarded after**.

---

## Running an L4 test

### Step 1 — Copy the user script in (read-only)

```bash
# From the production host:
scp /path/to/user.R clean@clean-vm-YYYYMMDD:/home/clean/work/
ssh clean@clean-vm-YYYYMMDD chmod 0444 /home/clean/work/user.R   # READ-ONLY (HC-13)
```

The script lives in `/home/clean/work/`. **Do not** put it on any
network mount; the whole point is local disk only.

### Step 2 — Install only the required CRAN packages

```bash
ssh clean@clean-vm-YYYYMMDD <<'EOF'
set -euo pipefail
# Extract library() calls from the user script (read-only parse)
LIBS=$(grep -oE 'library\(([a-zA-Z0-9._]+)\)' /home/clean/work/user.R \
       | sed -E 's/library\(([^)]+)\)/\1/' | sort -u | paste -sd, -)
echo "Required libs: $LIBS"
Rscript -e "install.packages(strsplit('$LIBS', ',')[[1]], \
                              repos='https://cloud.r-project.org', \
                              Ncpus=8)"
EOF
```

If the user script needs input data, copy a **minimal** synthetic
fixture, not the production NFS data. The L4 question is "does the
script's *logic* fail in isolation?", not "does NFS fail?".

### Step 3 — Run with NO profile, capture everything

```bash
ssh clean@clean-vm-YYYYMMDD <<'EOF'
set -euo pipefail
cd /home/clean/work
TS=$(date +%Y%m%d_%H%M%S)
LOG=/home/clean/work/L4_${TS}.log

# Belt + suspenders: env says no profile, --no-init-file says no profile
env R_PROFILE=/dev/null R_PROFILE_USER=/dev/null \
    R_ENVIRON=/dev/null R_ENVIRON_USER=/dev/null \
    timeout --kill-after=10s 1800s \
    Rscript --no-init-file --no-site-file --no-environ \
            /home/clean/work/user.R "$@" 2>&1 | tee "$LOG"
EC=${PIPESTATUS[0]}
echo "EXIT_CODE=$EC" | tee -a "$LOG"
EOF
```

### Step 4 — Collect evidence

```bash
mkdir -p /tmp/L4_clean_vm_<TS>/
scp clean@clean-vm-YYYYMMDD:/home/clean/work/L4_*.log /tmp/L4_clean_vm_<TS>/
ssh clean@clean-vm-YYYYMMDD \
    'Rscript -e "writeLines(capture.output(sessionInfo()))"' \
    > /tmp/L4_clean_vm_<TS>/sessionInfo.txt
ssh clean@clean-vm-YYYYMMDD \
    'Rscript -e "cat(format(installed.packages()[,c(\"Package\",\"Version\")]),sep=\"\n\")"' \
    > /tmp/L4_clean_vm_<TS>/installed.packages.txt
ssh clean@clean-vm-YYYYMMDD 'uname -a; cat /etc/debian_version; lscpu' \
    > /tmp/L4_clean_vm_<TS>/host_info.txt
```

### Step 5 — Discard the VM

```bash
virsh destroy clean-vm-YYYYMMDD
virsh undefine clean-vm-YYYYMMDD --remove-all-storage
```

(Or `virsh snapshot-revert` to the pristine snapshot if you intend to
re-use the VM for another L4 test soon.)

---

## Verdict matrix

| L3 (production) | L4 (clean VM) | Verdict | Action |
|-----------------|---------------|---------|--------|
| FAIL | **PASS** | production-VM-specific | Re-bisect on production: NFS mount, fragment, cgroup, `R_LIBS_USER` drift. Fix lands in `templates/` or `scripts/`. |
| FAIL | **FAIL identical** | user-script or upstream bug → **L5** | Build a ≤30-line minimal reproducer (still on the clean VM). File upstream issue if it's a CRAN package; otherwise reply to user with reproducer + `sessionInfo()`. |
| FAIL | **FAIL different** | two bugs (rare) | Document both. Fix the production one system-side; treat the L4 one as L5. |
| PASS | n/a | should not happen at L4 | If L3 has started passing while you were preparing the clean VM, the production fix already landed (likely a fragment redeploy). Confirm and close. |

---

## L5 — what to send to the user

Per HC-13, only at L5 (clean-VM reproduces) may the sysadmin propose code
changes — and even then, **as a suggestion for the user's review**, not a
silent commit.

Mandatory contents of the L5 report (`/tmp/L4_clean_vm_<TS>/L5_report.md`):

1. Clean-VM spec (copy from this doc).
2. The minimal reproducer (≤30 lines, runs in <60 s, isolates the
   failing call).
3. `sessionInfo()` from the clean VM.
4. `installed.packages()` versions for the relevant packages.
5. `host_info.txt` (uname, debian version, lscpu).
6. Kernel-stack evidence from `biome_hang_diag()` if it was a hang.
7. The **proposed** patch as a unified diff against the user's `.R`,
   clearly marked: *"For your review — we will not apply without your OK."*

---

## What the clean VM does **NOT** test

- NFS performance / mount option pathologies → L0..L3 territory.
- AD/SSSD/Kerberos UID mismatch → L0..L3 territory.
- Cgroup memory caps → L0..L3 (though clean VM has `64 GB` host RAM as a
  natural ceiling).
- Profile fragment interactions → L1/L2.
- Custom `/Rtmp` semantics → L0.

If the production failure is on any of those surfaces, L4 will
**incorrectly** PASS and mislead you. That's why L0..L3 must be
exhausted first.

---

## See also

- `docs/operations/USER_SCRIPT_TROUBLESHOOTING.md` — full L0..L5 ladder.
- `docs/operations/LUSSU_HANG_BISECTION.md` — concrete worked example.
- `docs/architecture/USER_CONTRACT.md` — what "portable R" means.
- `.ai/agents.md` §6.6 — HC-13 architectural rule.
- `.ai/agents.md` §8 — note that the Vagrant sandbox is BROKEN; it is
  **not** an L4 substitute.
