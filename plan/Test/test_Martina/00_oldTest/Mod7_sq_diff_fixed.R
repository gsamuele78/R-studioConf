# plan/Test/test_Martina/Mod7_sq_diff_fixed.R
# Run via: Jobs tab -> Start Local Job, OR: Rscript Mod7_sq_diff_fixed.R
# Do NOT run line-by-line in the main console (heavy parallel NIMBLE compilation).

# ==============================================================================
# 1. LIBRARIES
# ==============================================================================
library(splines)
library(fields)
library(splines2)
library(nimble)
library(vegan)
library(geosphere)
library(ggplot2)
library(ggpubr)
library(sf)
library(mapview)
library(terra)
library(MASS)
library(MCMCvis)
library(scoringRules)
library(parallel)
library(coda)

# ==============================================================================
# 2. WORKING DIRECTORY & ENVIRONMENT CLEANUP
# ==============================================================================
setwd("test_Martina")

to_del <- ls()
to_del <- to_del[!to_del %in% c("bash_script", "check_quota", ".Last.value")]
rm(list = to_del)
rm(to_del)
gc()

# ==============================================================================
# 3. FILE-BASED LOGGING
# All cat() and message() output from this point is captured in the log file.
# Monitor progress: open 'mcmc_progress_log.txt' in the Files pane anytime.
# ==============================================================================
log_file_path  <- "mcmc_progress_log.txt"
log_connection <- file(log_file_path, open = "wt")
sink(log_connection, type = "output")
sink(log_connection, type = "message")

cat("====================================================\n")
cat(sprintf("Script started at: %s\n", Sys.time()))
cat(sprintf("R version: %s\n", R.version.string))
cat("====================================================\n\n")

# ==============================================================================
# 4. LOAD DATA
# ==============================================================================
cat("Loading data...\n")
load(file = "Data_for_spGDMM_Lagorai.RData")
cat(sprintf("  Sites: %d | Pairwise obs: %d | Predictors: %d\n\n",
    N_sites, Smp_size, N_col_XforGDM))

# ==============================================================================
# 5. INITIAL VALUES (lm + optim)
# ==============================================================================
cat("Fitting initial values via lm + optim...\n")

lm_mod <- lm(log(Obs_Z) ~ X_for_GDM)

lm_out <- optim(
  c(.3, ifelse(coef(lm_mod)[-1] > 0, log(coef(lm_mod)[-1]), -10), rnorm(N_sites)),
  function(par) {
    sum((log(Obs_Z) - par[1] -
         X_for_GDM %*% exp(par[2:(N_col_XforGDM + 1)]) -
         (par[N_col_XforGDM + 1 + row_ind] - par[N_col_XforGDM + 1 + col_ind])^2)^2)
  },
  method = "BFGS", control = list(maxit = 1000)
)

cat(sprintf("  optim convergence: %d  (0 = success, 1 = max iterations reached)\n\n",
    lm_out$convergence))

# ==============================================================================
# 6. NIMBLE MODEL CODE
# ==============================================================================
cat("Sourcing NIMBLE model...\n")
source("nimble_models_10var21invgamma.R")
cat("  nimble_code7_10var loaded.\n\n")

# ==============================================================================
# 7. NIMBLE CONSTANTS & DATA
# ==============================================================================
constants <- list(
  n      = Smp_size,
  p      = N_col_XforGDM,
  x      = X_for_GDM,
  n_loc  = N_sites,
  R_inv  = R_inv,
  zeros  = rep(0, N_sites),
  row_ind = row_ind,
  col_ind = col_ind
)

data_mod <- list(
  log_V    = ifelse(Obs_Z == 1, NA, log(Obs_Z)),
  censored = 1 * (Obs_Z == 1),
  c        = rep(0, constants$n)
)

# ==============================================================================
# 8. CHAIN INITIAL VALUES (dispersed across 4 chains)
# Martina: Lagorai sig2_psi = 0.07
# ==============================================================================
n_chains <- 4
set.seed(46534)

init_list <- replicate(n = n_chains, expr = {
  list(
    beta_0   = lm_out$par[1] + rnorm(1, mean = 0, sd = .1),
    log_beta = lm_out$par[2:(N_col_XforGDM + 1)] +
               rnorm(length(2:(N_col_XforGDM + 1)), mean = 0, sd = .05),
    sig2_psi = 0.07 + rnorm(1, mean = 0, sd = .01),
    sigma2   = sigma(lm_mod)^2 + rnorm(1, mean = 0, sd = .01),
    psi      = lm_out$par[-(1:(N_col_XforGDM + 1))] +
               rnorm(N_sites, mean = 0, sd = .0005)
  )
}, simplify = FALSE)
names(init_list) <- paste0("Ch_", seq_len(n_chains))

cat(sprintf("Initialized %d chains.\n", n_chains))
cat(sprintf("  beta_0 range:   [%.4f, %.4f]\n",
    min(sapply(init_list, `[[`, "beta_0")),
    max(sapply(init_list, `[[`, "beta_0"))))
cat(sprintf("  sig2_psi range: [%.4f, %.4f]\n",
    min(sapply(init_list, `[[`, "sig2_psi")),
    max(sapply(init_list, `[[`, "sig2_psi"))))
cat(sprintf("  sigma2 range:   [%.4f, %.4f]\n\n",
    min(sapply(init_list, `[[`, "sigma2")),
    max(sapply(init_list, `[[`, "sigma2"))))

# ==============================================================================
# 9. MCMC PARAMETERS
# ==============================================================================
N_tot_iter <- 25000
N_burn     <- 20000
N_thin     <- 1
N_post     <- (N_tot_iter - N_burn) / N_thin

cat("MCMC parameters:\n")
cat(sprintf("  Total iters:      %d\n", N_tot_iter))
cat(sprintf("  Burn-in:          %d\n", N_burn))
cat(sprintf("  Thinning:         %d\n", N_thin))
cat(sprintf("  Post samples/chain: %d  |  Total: %d\n\n", N_post, N_post * n_chains))

# ==============================================================================
# 10. PSOCK CLUSTER
# biome_make_cluster() routes NIMBLE compile to per-PID subdirs on /Rtmp
# (local disk, not NFS) — prevents unserialize(node$con) worker crashes.
# Worker stdout/stderr is captured in /Rtmp/biome_<user>/cluster_logs/
# ==============================================================================
cat(sprintf("Available cores: %d\n", detectCores()))
cat("Creating PSOCK cluster (4 workers, 1 BLAS thread/worker)...\n")

N_cluster <- biome_make_cluster(workers = 4, worker_threads = 1L)

cat("Cluster ready. Worker progress logs: /Rtmp/biome_<user>/cluster_logs/\n\n")

# ==============================================================================
# 11. WORKER FUNCTION
# ==============================================================================
run_MCMC_allcode <- function(seed, data, code, constants, inits,
                              niter, nburnin, thin = 1,
                              smmry = TRUE, wid_aic = FALSE) {
  require(nimble)
  require(nimbleHMC)

  # Guarantee per-worker NIMBLE compile dir on /Rtmp (NFS-safe fallback)
  local({
    nr <- Sys.getenv("BIOME_NIMBLE_DIR", "")
    if (!nzchar(nr))
      nr <- file.path("/Rtmp", paste0("biome_", Sys.info()[["user"]]), "nimble_compile")
    wd <- file.path(nr, paste0("worker_", Sys.getpid()))
    dir.create(wd, recursive = TRUE, showWarnings = FALSE, mode = "0700")
    if (dir.exists(wd)) options(nimble.dirName = wd)
  })

  message(sprintf("[Chain %d | PID %d] Started   %s", seed, Sys.getpid(),
                  format(Sys.time(), "%Y-%m-%d %H:%M:%S")))

  myModel <- nimbleModel(code = code, data = data, constants = constants, buildDerivs = TRUE)

  myConfig <- configureMCMC(myModel)
  myConfig$removeSamplers(c("beta_0", "log_beta", "psi", "sig2_psi", "sigma2"))
  myConfig$addSampler(target = "psi",  type = "AF_slice")
  addHMC(conf = myConfig, target = c("beta_0", "log_beta", "sig2_psi", "sigma2"))
  myConfig$addMonitors(c("beta_0", "beta", "sigma2", "psi", "sig2_psi"))
  if (wid_aic) myConfig$enableWAIC <- TRUE

  myMCMC   <- buildMCMC(myConfig)
  CmyModel <- compileNimble(myMCMC, myModel)

  message(sprintf("[Chain %d | PID %d] Compiled  %s — running MCMC...", seed, Sys.getpid(),
                  format(Sys.time(), "%H:%M:%S")))

  results <- runMCMC(
    CmyModel$myMCMC,
    niter    = niter,
    nburnin  = nburnin,
    thin     = thin,
    nchains  = 1,
    inits    = inits[[seed]],
    summary  = smmry,
    WAIC     = wid_aic,
    setSeed  = seed
  )

  message(sprintf("[Chain %d | PID %d] Finished  %s", seed, Sys.getpid(),
                  format(Sys.time(), "%H:%M:%S")))

  rm(myModel, myConfig, myMCMC, CmyModel)
  gc()
  return(results)
}

# ==============================================================================
# 12. RUN MCMC
# ==============================================================================
cat(sprintf("Launching parLapply (%d chains) at %s ...\n", n_chains, Sys.time()))
cat("Each worker logs to /Rtmp/biome_<user>/cluster_logs/ (check for per-chain progress).\n\n")

clusterExport(N_cluster, varlist = "run_MCMC_allcode", envir = environment())

st_process <- proc.time()

chain_output <- parLapply(
  cl  = N_cluster,
  X   = 1:4,
  fun = run_MCMC_allcode,
  data      = data_mod,
  code      = nimble_code7_10var,
  constants = constants,
  inits     = init_list,
  niter     = N_tot_iter,
  nburnin   = N_burn,
  thin      = N_thin
)

stopCluster(N_cluster)

elapsed <- proc.time() - st_process
cat(sprintf("All chains finished at %s\n", Sys.time()))
cat(sprintf("Elapsed: %.2f hours (%.0f minutes)\n\n", elapsed["elapsed"] / 3600, elapsed["elapsed"] / 60))

# ==============================================================================
# 13. CONVERGENCE DIAGNOSTICS
# ==============================================================================
cat("--- Gelman-Rubin R-hat (should be < 1.1 for convergence) ---\n")
out_list <- mcmc.list(lapply(chain_output, function(i) as.mcmc(i[["samples"]])))

key_params <- tryCatch({
  all_pars <- colnames(chain_output[[1]][["samples"]])
  all_pars[all_pars %in% c("beta_0", "sigma2", "sig2_psi")]
}, error = function(e) character(0))

if (length(key_params) > 0) {
  gd <- tryCatch(
    gelman.diag(out_list[, key_params, drop = FALSE], multivariate = FALSE),
    error = function(e) { cat(sprintf("  gelman.diag error: %s\n", e$message)); NULL }
  )
  if (!is.null(gd)) print(gd$psrf)
} else {
  cat("  (key_params not found in samples — skipping R-hat)\n")
}
cat("\n")

# ==============================================================================
# 14. SAVE RESULTS
# ==============================================================================
result_file <- sprintf("Lagorai/mod7_HMC_4ch%dk%dk%dT_%s_Lagorai.rds",
  N_tot_iter / 1000, N_burn / 1000, N_thin,
  format(Sys.Date(), "%d%m%y"))

saveRDS(chain_output, file = result_file)
cat(sprintf("Results saved to: %s\n", result_file))

cat("\n====================================================\n")
cat(sprintf("Script completed at: %s\n", Sys.time()))
cat("====================================================\n")

# ==============================================================================
# 15. END LOGGING
# ==============================================================================
sink(type = "message")
sink(type = "output")
close(log_connection)

# ==============================================================================
# 16. CLEANUP (CRITICAL — prevents C++ pointer leak on session save)
# Compiled NIMBLE objects (CmyModel etc.) live inside chain_output workers
# and are already destroyed there. Clear remaining large objects.
# ==============================================================================
rm(chain_output, out_list, data_mod, constants, init_list, lm_mod, lm_out)
if (exists("nimble_code7_10var")) rm(nimble_code7_10var)
gc()
