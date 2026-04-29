# this code runs model 7 for the Foreste Casentinesi
# DEBUG VERSION - Creates detailed per-worker log files in /Rtmp
# This version uses PSOCK cluster and captures all output for troubleshooting

library(splines)
library(fields)
library(splines2)
library(nimble)
library(vegan)
library(geosphere)

# added by me
library(ggplot2)
library(ggpubr)
library(sf)
library(mapview)
library(terra)
library(MASS)
library(MCMCvis)

# for CV
library(scoringRules)

setwd("/nfs/home/gianfranco.samuele2/test_Martina")
# avoid deleting the following objects: 'bash_script', 'check_quota', .Last.value (?)

to_del <- ls()
to_del <- to_del[!to_del %in% c("bash_script", "check_quota", ".Last.value")]

rm(list = to_del)
rm(to_del)

gc()

# Data imported from GDM_ForesteCasentinesi.Rproj

# load(file = 'Casentino/Data_for_spGDMM_Casentino.RData')
# load(file= "Lagorai/Data_for_spGDMM_Lagorai.RData") # new 16.02
# load(file = "NEW/Lagorai/Data_for_spGDMM_Lagorai.RData")
load(file = "Data_for_spGDMM_Lagorai.RData")
#------------------------------------------------------------------------
# Get Initial values for modeling fitting
#------------------------------------------------------------------------

# fit lm to log(dissimilarty) - latent dissimilarity - as a function of X_for_GDM
lm_mod <- lm(log(Obs_Z) ~ X_for_GDM)

lm_out <- optim(c(.3, ifelse(coef(lm_mod)[-1] > 0, log(coef(lm_mod)[-1]), -10), rnorm(N_sites)), function(par) {
    sum((log(Obs_Z) - par[1] - X_for_GDM %*% exp(par[2:(N_col_XforGDM + 1)]) - (par[N_col_XforGDM + 1 + row_ind] - par[N_col_XforGDM + 1 + col_ind])^2)^2)
}, method = "BFGS", control = list(maxit = 1000))

# Warning message:
# In log(coef(lm_mod)[-1]) : NaNs produced
# check convergence
lm_out$convergence # 1

#------------------------------------------------------------------------
# Source nimble models -- Models 1-9 match those in paper
#------------------------------------------------------------------------

# The nimble_models.R script can be downloaded at this link: https://github.com/philawhite/spGDMM-code/blob/spGDMM_v1/nimble_code/nimble_models.R
# source("C://MOTIVATE/GDM_ForesteCasentinesi/spGDMM_fold/nimble_models.R")

# Import nimble_models_10var21invgamma - variance of priors of intercept and beta(s) is assumed to be 10 instead of 100
# also, sigma2 and sigma2_psi have more informative priors - dinvgamma(2, 1) - this prevents the sampler to consider extreme values as plausible
# plot nimble::rinvgamma(N, 2, 1) to check values considered by the prior
# source("Model/nimble_models_10var21invgamma.R")
# source("nimble_models_10var21invgamma.R")

### Here, beta represents beta* discussed in the supplement, the product of alpha_k and \beta_{k,j}


nimble_code4_10var <- nimbleCode({
    beta_0 ~ dnorm(0, var = 10) # modified 100 to 10
    sig2_psi ~ dinvgamma(2, 1) # modified to 2, 1
    prec_use[1:n_loc, 1:n_loc] <- R_inv[1:n_loc, 1:n_loc] / sig2_psi
    psi[1:n_loc] ~ dmnorm(zeros[1:n_loc], prec = prec_use[1:n_loc, 1:n_loc])

    for (i in 1:p) {
        log(beta[i]) ~ dnorm(0, var = 10) # modified 100 to 10
    }

    # for(i in 1:p_sigma){
    #   beta_sigma[i] ~ dnorm(0, var = 100)
    # }

    linpred[1:n] <- (x[1:n, 1:p] %*% beta[1:p])[1:n, 1]
    sigma2 ~ dinvgamma(2, 1) # modified to 2, 1

    for (i in 1:n) {
        mu[i] <- beta_0 + linpred[i] + abs(psi[row_ind[i]] - psi[col_ind[i]])

        censored[i] ~ dinterval(log_V[i], c[i])
        log_V[i] ~ dnorm(mu[i], var = sigma2)
    }
})


nimble_code7_10var <- nimbleCode({
    beta_0 ~ dnorm(0, var = 10) # modified 100 to 10
    sig2_psi ~ dinvgamma(2, 1) # modified to 2, 1
    prec_use[1:n_loc, 1:n_loc] <- R_inv[1:n_loc, 1:n_loc] / sig2_psi
    psi[1:n_loc] ~ dmnorm(zeros[1:n_loc], prec = prec_use[1:n_loc, 1:n_loc])

    for (i in 1:p) {
        log(beta[i]) ~ dnorm(0, var = 10) # modified 100 to 10
    }

    # for(i in 1:p_sigma){
    #   beta_sigma[i] ~ dnorm(0, var = 100)
    # }

    linpred[1:n] <- (x[1:n, 1:p] %*% beta[1:p])[1:n, 1]
    sigma2 ~ dinvgamma(2, 1) # modified to 2, 1

    for (i in 1:n) {
        mu[i] <- beta_0 + linpred[i] + (psi[row_ind[i]] - psi[col_ind[i]])^2

        censored[i] ~ dinterval(log_V[i], c[i])
        log_V[i] ~ dnorm(mu[i], var = sigma2)
    }
})

# create constants for nimble model

constants <- list(
    n = Smp_size, p = N_col_XforGDM, x = X_for_GDM, n_loc = N_sites,
    R_inv = R_inv, zeros = rep(0, N_sites), row_ind = row_ind, col_ind = col_ind
)

# create data for nimble model

data_mod <- list(
    log_V = ifelse(Obs_Z == 1, NA, log(Obs_Z)),
    censored = 1 * (Obs_Z == 1),
    c = rep(0, constants$n)
)

#------------------------------------------------------------------------
# Multi-core processing
#------------------------------------------------------------------------

# create initial values for multi-core processing
# modify according to the number of chains - in case of single-core processing, simply use lm_out$par as initial values

n_chains <- 4

# sigma^2 set to sigma(lm_mod)^2

set.seed(46534)

# mind the difference in scale between log(beta) and beta scale - if beta is close to 0 log(beta) takes a large negative value
# so if log(beta) from lm_out$par is a large negative number (e.g. -10) initial values should be set close to that value to allow
# beta to be close to 0
# sigma2_psi is set to 0.6 as this is close to the median value of dinvgamma(2, 1), which is used as prior

# setting dispersed inits prevents inducing false convergence after a short burn-in phase
# it also allows to better explore the posterior - for psi is better to create inits that are not too far from
# those estimated using optim

# Martina: for Lagorai area we change the parameter sig2_psi to 0.07 from the check of MCMC tests
# Martina: for Velino sig2_psi to 0.37
# Velino sigma positivi
# Lagorai sig2_psi = 0.10
init_list <- replicate(n = 4, expr = {
    list(
        beta_0 = lm_out$par[1] + rnorm(n = 1, mean = 0, sd = .1),
        log_beta = lm_out$par[2:(N_col_XforGDM + 1)] + rnorm(n = length(2:(N_col_XforGDM + 1)), mean = 0, sd = .05), # changed .01 to .05 for log_beta
        sig2_psi = 0.07 + rnorm(n = 1, mean = 0, sd = .01), sigma2 = sigma(lm_mod)^2 + rnorm(n = 1, mean = 0, sd = .01),
        psi = lm_out$par[-(1:(N_col_XforGDM + 1))] + rnorm(n = N_sites, mean = 0, sd = .0005)
    ) # changed .00001 to .01 #changed .01 to .005
}, simplify = F)

names(init_list) <- paste0("Ch_", seq_len(n_chains))

# check range of parameters

# check sigma to be positive!!

# intercept
lapply(init_list, "[[", 1)

# log_beta
lapply(init_list, function(x) range(x[[2]]))

# sig2_psi
lapply(init_list, "[[", 3)

# sigma2
lapply(init_list, "[[", 4)

# psi
lapply(init_list, function(x) range(x[[5]]))

# check
n_chains == length(init_list) # T

#----------set up parameters for MCMC

N_tot_iter <- 25000
N_burn <- 20000
N_thin <- 1 # no thinning - better run a longer burnin and don't sacrifice samples - see Link et al. 2012 (MEE)
N_post <- (N_tot_iter - N_burn) / N_thin # this is the final number of posterior samples per chain (so the numbr should be multiplied by n_chains)
# total number of posterior samples
N_post * n_chains # 20e3

library(parallel)


# ================================================================================
# DEBUG VERSION: Enhanced parallel processing with detailed logging
# ================================================================================
# Changes:
# 1. Uses PSOCK cluster type
# 2. Each worker creates its own log file in /Rtmp
# 3. All output (including compiler output) is captured
# 4. Errors are caught with tryCatch and logged with full details
# ================================================================================

detectCores() # 24

# Use PSOCK cluster type for better compatibility
N_cluster <- makeCluster(4, type = "PSOCK", outfile = "")

# Load required libraries on all worker nodes
clusterEvalQ(N_cluster, {
    library(nimble)
    library(nimbleHMC)
    NULL
})

# Export all required objects to workers
clusterExport(N_cluster, varlist = c(
    "nimble_code7_10var", "data_mod", "constants", "init_list",
    "N_tot_iter", "N_burn", "N_thin"
), envir = environment())

# DEBUG function for running independent processes with detailed logging
# Each worker creates its own log file in /Rtmp
run_MCMC_allcode_debug <- function(seed, data, code, constants, inits, niter, nburnin, thin = 1, smmry = T, wid_aic = F) {
    # Create a unique log file for this worker
    log_file <- paste0("/Rtmp/worker_", seed, "_debug.log")
    log_con <- file(log_file, open = "wt")

    # Redirect all output and messages to the log file
    sink(log_con, type = "output")
    sink(log_con, type = "message")

    cat("================================================================================\n")
    cat("--- Inizio Worker Seed:", seed, "---\n")
    cat("--- Timestamp:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "---\n")
    cat("================================================================================\n")

    result <- tryCatch(
        {
            # Create unique directories for each worker to avoid conflicts
            worker_compile_dir <- paste0("/Rtmp/nimble_worker_", seed)
            worker_log_dir <- paste0("/Rtmp/nimble_worker_", seed, "/logs")

            # Create directories if they don't exist
            if (!dir.exists(worker_compile_dir)) {
                dir.create(worker_compile_dir, recursive = TRUE, showWarnings = FALSE)
            }
            if (!dir.exists(worker_log_dir)) {
                dir.create(worker_log_dir, recursive = TRUE, showWarnings = FALSE)
            }

            # Set temp directory for compilation (unique per worker)
            Sys.setenv(TMPDIR = worker_compile_dir)
            cat("TMPDIR impostato a:", Sys.getenv("TMPDIR"), "\n")
            cat("Worker compile directory:", worker_compile_dir, "\n")
            cat("Worker log directory:", worker_log_dir, "\n")

            # Load required packages
            cat("\n[1] Caricamento pacchetti...\n")
            require(nimble)
            require(nimbleHMC)
            cat("Pacchetti caricati con successo.\n")

            # Create model
            cat("\n[2] Creazione modello nimble...\n")
            cat("Dimensioni dati: n =", constants$n, ", p =", constants$p, ", n_loc =", constants$n_loc, "\n")
            myModel <- nimbleModel(
                code = code,
                data = data,
                constants = constants,
                buildDerivs = T
            )
            cat("Modello creato con successo.\n")
            cat("Nodi del modello:", paste(myModel$getNodeNames(), collapse = ", "), "\n")

            # Configure MCMC
            cat("\n[3] Configurazione MCMC...\n")
            myConfig <- configureMCMC(myModel)

            myConfig$removeSamplers(c("beta_0", "log_beta", "psi", "sig2_psi", "sigma2"))
            myConfig$addSampler(target = c("psi"), type = "AF_slice")
            addHMC(conf = myConfig, target = c("beta_0", "log_beta", "sig2_psi", "sigma2"))
            myConfig$addMonitors(c("beta_0", "beta", "sigma2", "psi", "sig2_psi"))
            if (wid_aic) myConfig$enableWAIC <- TRUE

            cat("Configurazione MCMC completata.\n")
            cat("Samplers configurati:\n")
            print(myConfig$getSamplers())

            # Build MCMC
            cat("\n[4] Build MCMC...\n")
            myMCMC <- buildMCMC(myConfig)
            cat("MCMC costruito con successo.\n")

            # Compile model and MCMC
            cat("\n[5] Compilazione C++ del modello...\n")
            cat("Directory di compilazione:", worker_compile_dir, "\n")
            CmyModel <- compileNimble(myMCMC, myModel, showCompilerOutput = TRUE, dirName = worker_compile_dir)
            cat("Compilazione completata con successo.\n")

            # Run MCMC
            cat("\n[6] Esecuzione MCMC...\n")
            cat("Parametri: niter =", niter, ", nburnin =", nburnin, ", thin =", thin, "\n")
            cat("Seed:", seed, "\n")

            results <- runMCMC(CmyModel$myMCMC,
                niter = niter, nburnin = nburnin, thin = thin, nchains = 1, inits = inits[[seed]],
                summary = smmry, WAIC = wid_aic, setSeed = seed
            )

            cat("MCMC completato con successo.\n")
            cat("Dimensioni risultati:", dim(results), "\n")

            # Clean up
            rm(myModel, myConfig, myMCMC, CmyModel)
            gc()

            cat("\n================================================================================\n")
            cat("--- Worker Seed:", seed, "COMPLETATO CON SUCCESSO ---\n")
            cat("================================================================================\n")

            return(results)
        },
        error = function(e) {
            cat("\n!!! ERRORE RILEVATO !!!\n")
            cat("Tipo errore:", class(e)[1], "\n")
            cat("Messaggio errore:", conditionMessage(e), "\n")
            cat("Call:", conditionCall(e), "\n")

            # Try to get more details
            cat("\nStack trace parziale:\n")
            print(sys.calls())

            cat("\n!!! ERRORE nel worker", seed, "!!!\n")

            # Clean up if possible
            tryCatch(
                {
                    rm(myModel, myConfig, myMCMC)
                    if (exists("CmyModel")) rm(CmyModel)
                    gc()
                },
                error = function(e2) {}
            )

            # Return error information
            return(list(
                error = TRUE,
                seed = seed,
                message = conditionMessage(e),
                call = deparse(conditionCall(e))
            ))
        },
        warning = function(w) {
            cat("\n!!! WARNING RILEVATO !!!\n")
            cat("Messaggio warning:", conditionMessage(w), "\n")
            invokeRestart("muffleWarning")
        }
    )

    # Close log file
    sink(type = "message")
    sink(type = "output")
    close(log_con)

    return(result)
}


# Note that you may get some warnings because we didn't initialize log_V where Z = 1.

st_process <- proc.time()

cat("\n")
cat("================================================================================\n")
cat("AVVIO ESECUZIONE PARALLELA CON DEBUG\n")
cat("================================================================================\n")
cat("Numero di worker:", n_chains, "\n")
cat("Tipo cluster: PSOCK\n")
cat("Log files: /Rtmp/worker_*_debug.log\n")
cat("================================================================================\n")
cat("\n")

# Export the debug function to workers
clusterExport(N_cluster, varlist = c("run_MCMC_allcode_debug"), envir = environment())

# Verify function is available on workers
cat("Verifica disponibilità funzione sui worker...\n")
check_results <- clusterEvalQ(N_cluster, exists("run_MCMC_allcode_debug"))
cat("Worker 1:", check_results[[1]], "\n")
cat("Worker 2:", check_results[[2]], "\n")
cat("Worker 3:", check_results[[3]], "\n")
cat("Worker 4:", check_results[[4]], "\n")

if (!all(unlist(check_results))) {
    stop("ERRORE: La funzione run_MCMC_allcode_debug non è disponibile su tutti i worker!")
}

cat("\nEsecuzione MCMC in corso...\n")
cat("I log dettagliati saranno disponibili in /Rtmp/worker_*_debug.log\n")
cat("\n")

# run the MCMC with debug function
chain_output <- parLapply(
    cl = N_cluster, X = 1:4,
    fun = run_MCMC_allcode_debug,
    data = data_mod, code = nimble_code7_10var, constants = constants, inits = init_list,
    niter = N_tot_iter, nburnin = N_burn, thin = N_thin
)

# It's good practice to close the cluster when you're done with it.
stopCluster(N_cluster)

elapsed <- proc.time() - st_process

cat("\n")
cat("================================================================================\n")
cat("ESECUZIONE COMPLETATA\n")
cat("================================================================================\n")
cat("Tempo impiegato:", round(elapsed[3] / 60, 2), "minuti\n")
cat("================================================================================\n")

# Check for errors in results
cat("\nVerifica risultati...\n")
for (i in 1:4) {
    if (is.list(chain_output[[i]]) && !is.null(chain_output[[i]]$error)) {
        cat("!!! Worker", i, "ha riportato un errore:\n")
        cat("   Messaggio:", chain_output[[i]]$message, "\n")
        cat("   Call:", chain_output[[i]]$call, "\n")
        cat("   Controlla il log: /Rtmp/worker_", i, "_debug.log\n")
    } else {
        cat("Worker", i, ": OK\n")
    }
}

cat("\n")
cat("================================================================================\n")
cat("ISTRUZIONI PER IL DEBUG\n")
cat("================================================================================\n")
cat("Per analizzare gli errori, controlla i file di log:\n")
cat("  /Rtmp/worker_1_debug.log\n")
cat("  /Rtmp/worker_2_debug.log\n")
cat("  /Rtmp/worker_3_debug.log\n")
cat("  /Rtmp/worker_4_debug.log\n")
cat("\n")
cat("Per visualizzare un log:\n")
cat("  cat /Rtmp/worker_1_debug.log\n")
cat("  tail -n 100 /Rtmp/worker_1_debug.log\n")
cat("================================================================================\n")

# 18 ore

# Lagorai sample 285 47h --- sample 201 22h ---- 55K 31h
# Save output
# save(chain_output, file = "/media/r_projects/manuele.bazzichetto/mod7_4Ch60k40k5T_200625_296pl.RData")

# save(chain_output, file = "/media/r_projects/manuele.bazzichetto/mod7_4ch65k60k1T_270625_296pl.RData") #saved on 27/06/2025

# save(chain_output, file = "/media/r_projects/manuele.bazzichetto/mod7_4ch75k70k1T_120825_296pl.RData")

# save(chain_output, file = "/media/r_projects/manuele.bazzichetto/mod7_4ch85k80k1T_250825_296pl.RData")

# save(chain_output, file = "/media/r_projects/manuele.bazzichetto/mod7_HMC_4ch15k10k1T_080925_296pl.RData")
# save(chain_output, file= "Lagorai/mod7_HMC_4ch40k35k1T_171225_108pl_Lagorai.RData")

# save(chain_output, file= "Velino/mod7_HMC_4ch40k35k1T_191225_168pl_Velino.RData")
save(chain_output, file = "Lagorai/mod7_HMC_4ch55k50k1T_200226_201pl_Lagorai.RData")
# Traceplots

library(coda)

out_list <- mcmc.list(lapply(chain_output, function(i) as.mcmc(i[["samples"]])))


traceplot(out_list)

MCMCvis::MCMCtrace(lapply(chain_output, function(i) i[["samples"]]), pdf = FALSE)
