#!/usr/bin/env bash
# Improved RStudio Server detection script for correct OS/arch and latest download URL
set -euo pipefail

# Detect OS codename and version
os_codename="$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)"
os_version="$(lsb_release -rs 2>/dev/null || grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')"
arch="$(uname -m)"
case "$arch" in
    x86_64|amd64) deb_arch="amd64" ;;
    aarch64|arm64) deb_arch="arm64" ;;
    i386|i686) deb_arch="i386" ;;
    *) deb_arch="amd64" ;;
esac

# Map OS codename/version to supported download section
# Supported: Ubuntu 20/22/24, Debian 11/12
case "$os_codename" in
    jammy|bookworm|noble) os_section="ubuntu" ;; # Ubuntu 22/24, Debian 12
    focal|bullseye) os_section="ubuntu" ;; # Ubuntu 20, Debian 11
    *) os_section="ubuntu" ;; # Default to ubuntu
esac

# Fetch download page and extract latest .deb for detected arch
rstudio_url="https://posit.co/download/rstudio-server/"
html=$(curl -fsSL "$rstudio_url" 2>/dev/null || true)
echo "$html" > rstudio_download_page.html


# Improved extraction logic from saved HTML
html_file="rstudio_download_page.html"

# Extract the latest version (first occurrence)
version=$(grep -oP 'Version: \K[0-9.]+\+[0-9]+' "$html_file" | head -1)
release_date=$(grep -oP 'Released: \K[0-9-]+' "$html_file" | head -1)
url_jammy=$(grep -oP 'https://download2.rstudio.org/server/jammy/amd64/rstudio-server-[0-9.]+-[0-9]+-amd64.deb' "$html_file" | head -1)
url_focal=$(grep -oP 'https://download2.rstudio.org/server/focal/amd64/rstudio-server-[0-9.]+-[0-9]+-amd64.deb' "$html_file" | head -1)
url_opensuse=$(grep -oP 'https://download2.rstudio.org/server/opensuse15/x86_64/rstudio-server-[0-9.]+-[0-9]+-x86_64.rpm' "$html_file" | head -1)

echo "Latest RStudio Server version: $version"
echo "Release date: $release_date"
echo "Ubuntu 22.04 (jammy) download URL: $url_jammy"
echo "Ubuntu 20.04 (focal) download URL: $url_focal"
echo "openSUSE/SLES RPM download URL: $url_opensuse"
