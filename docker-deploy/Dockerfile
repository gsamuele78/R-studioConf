# Dockerfile for RStudio Botanical "Pet Container"
FROM rocker/geospatial:latest

LABEL maintainer="docker-deploy-botanical"

# 1. System Setup for BSPM and Auth (SSSD/Samba)
# We install BOTH SSSD and Samba client libraries to support either mount strategy.
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    python3-launchpadlib \
    # Auth Packages (Pet Container Support)
    samba winbind libpam-winbind libnss-winbind krb5-user \
    sssd-client libpam-sss libnss-sss \
    # Utilities
    nano iputils-ping \
    && add-apt-repository -y ppa:c2d4u.team/c2d4u4.0+ \
    && apt-get update \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Configure BSPM & OpenBLAS CORETYPE Wrappers
# Enable BSPM in R for faster installs
RUN echo "bspm::enable()" >> /usr/local/lib/R/etc/Rprofile.site

# Inject migration-safe OpenBLAS CORETYPE wrappers to evaluate CPU vendor/flags 
# *before* R and libopenblas.so launch.
RUN cat <<'EOF' > /etc/profile.d/biome-coretype.sh
# BIOME-CALC: Detect CPU vendor and set OPENBLAS_CORETYPE.
# Profile.d script for terminal R usage.
VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | tr -d ' ')
FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2)
if echo "$VENDOR" | grep -qi "AMD"; then
  if echo "$FLAGS" | grep -q "avx2"; then CT="ZEN"
  elif echo "$FLAGS" | grep -q "avx";  then CT="BULLDOZER"
  else CT="SANDYBRIDGE"; fi
elif echo "$VENDOR" | grep -qiE "Intel|Genuine"; then
  if echo "$FLAGS" | grep -q "avx512"; then CT="SKYLAKEX"
  elif echo "$FLAGS" | grep -q "avx2";  then CT="HASWELL"
  elif echo "$FLAGS" | grep -q "avx";   then CT="SANDYBRIDGE"
  else CT="PRESCOTT"; fi
else
  CT="SANDYBRIDGE"
fi
export OPENBLAS_CORETYPE="${CT}"
EOF

RUN chmod 755 /etc/profile.d/biome-coretype.sh && \
    mkdir -p /etc/rstudio && \
    cat <<'EOF' > /etc/rstudio/rsession-profile
#!/bin/sh
# BIOME-CALC: Evaluate CPU capabilities before spawning rsession.
if [ -f /etc/profile.d/biome-coretype.sh ]; then
  . /etc/profile.d/biome-coretype.sh
fi
EOF

RUN chmod 755 /etc/rstudio/rsession-profile

# 3. Install Botanical Packages
# Copy the installation script
COPY scripts/install_botanical_packages.R /rocker_scripts/install_botanical_packages.R
RUN Rscript /rocker_scripts/install_botanical_packages.R

# 4. Entrypoint / Init Configuration
# We need a custom init script to check for mounted sockets/pipes and configure PAM/NSS accordingly.
COPY scripts/entrypoint_auth_pet.sh /usr/local/bin/entrypoint_auth_pet.sh
RUN chmod +x /usr/local/bin/entrypoint_auth_pet.sh

# 5. Environment Variables
# Prevent RStudio from asking for auth (we handle it via PAM but some env vars help)
ENV PASSWORD="preset_but_unused_if_pam_works"

# Overwrite entrypoint to use our custom setup before handing off to S6/RStudio
ENTRYPOINT ["/usr/local/bin/entrypoint_auth_pet.sh"]
CMD ["/init"]
