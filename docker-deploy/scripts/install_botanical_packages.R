#!/usr/bin/env Rscript

# install_botanical_packages.R
# Installs packages defined in the original r_env_manager.conf
# Uses bspm if available (enabled in Dockerfile)

# CRAN Packages list extracted from r_env_manager.conf
cran_packages <- c(
    "terra", "raster", "sf", "enmSdmX", "dismo", "spThin", "rnaturalearth", "furrr", "future",
    "doParallel", "future", "caret", "CoordinateCleaner", "tictoc", "devtools", "nimbleHMC",
    "tidyverse", "dplyr", "spatstat", "ggplot2", "iNEXT", "DHARMa", "lme4", "TMB", "glmmTMB",
    "geodata", "osmdata", "parallel", "doSNOW", "progress", "nngeo", "wdpar", "igraph", "rgee", "tidyrgee",
    "data.table", "jsonlite", "httr", "prioritizr", "prioritizrdata", "highs", "MASS", "MCMCvis", "scoringRules"
)

# Install CRAN packages
install_cran <- function(pkgs) {
    if (!require("bspm", quietly = TRUE)) {
        message("BSPM not found, falling back to standard install")
    }
    install.packages(pkgs)
}

install_cran(cran_packages)

# GitHub Packages
# Note: GitHub packages require 'remotes' or 'devtools'
if (!require("remotes", quietly = TRUE)) install.packages("remotes")

github_packages <- c(
    "SantanderMetGroup/loadeR.java",
    "SantanderMetGroup/climate4R.UDG",
    "SantanderMetGroup/loadeR",
    "SantanderMetGroup/transformeR",
    "SantanderMetGroup/visualizeR",
    "SantanderMetGroup/downscaleR",
    "SantanderMetGroup/climate4R.datasets",
    "SantanderMetGroup/mopa",
    "HelgeJentsch/ClimDatDownloadR"
)

remotes::install_github(github_packages, upgrade = "never")
