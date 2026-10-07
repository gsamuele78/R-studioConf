#!/usr/bin/env Rscript

# install_botanical_packages.R
# Installs packages defined in the original r_env_manager.conf
# Docker tier: plain install.packages() against rocker's binary repository
# (no bspm in T2, see .ai/project.yml TD-T2-05).

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
    # Sysadmin Optimization: Parallel compilation for C++ packages
    opts <- options(Ncpus = parallel::detectCores())
    install.packages(pkgs)
    options(opts)
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

# Fail the image build if any requested package cannot be loaded.
# install.packages() and install_github() only warn on failure, which let
# images ship without loadeR.java / climate4R.UDG / loadeR unnoticed.
requested <- unique(c(cran_packages, sub("^.*/", "", github_packages)))
load_error <- vapply(requested, function(pkg) {
    tryCatch({ loadNamespace(pkg); "" }, error = function(e) conditionMessage(e))
}, character(1))
if (any(nzchar(load_error))) {
    bad <- load_error[nzchar(load_error)]
    message(sprintf("  %s: %s", names(bad), bad), sep = "\n")
    stop("packages not loadable after install: ",
         paste(names(bad), collapse = ", "), call. = FALSE)
}
message("All ", length(requested), " requested packages load.")
