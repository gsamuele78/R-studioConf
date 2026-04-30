# this code runs model 7 for the Foreste Casentinesi

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

setwd("BECAUSE")
# avoid deleting the following objects: 'bash_script', 'check_quota', .Last.value (?)

to_del <- ls()
to_del <- to_del[!to_del %in% c("bash_script", "check_quota", ".Last.value")]

rm(list = to_del)
rm(to_del)

gc()

# Data imported from GDM_ForesteCasentinesi.Rproj

# load(file = 'Casentino/Data_for_spGDMM_Casentino.RData')
# load(file= "Lagorai/Data_for_spGDMM_Lagorai.RData") # new 16.02
load(file = "NEW/Lagorai/Data_for_spGDMM_Lagorai.RData")
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
source("Model/nimble_models_10var21invgamma.R")

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


# example borrowed from https://r-nimble.org/nimbleExamples/parallelizing_NIMBLE.html
# the idea is to run nchains independent processes. To ensure independence, the whole procedure to create and run the model
# is divided in independent runs

detectCores() # 24

N_cluster <- makeCluster(4, outfile = "cluster_log.txt")

# function for running independent processes - I modified the code related to wid_aic to have more control on whether waic should be computed or not
# notice that waic is not used to compare model formulations - waic it evaluates model performance in the parameter space

run_MCMC_allcode <- function(seed, data, code, constants, inits, niter, nburnin, thin = 1, smmry = T, wid_aic = F) {
  require(nimble)
  require(nimbleHMC)

  # model
  myModel <- nimbleModel(
    code = code,
    data = data,
    constants = constants,
    buildDerivs = T
  )

  # config
  myConfig <- configureMCMC(myModel)

  myConfig$removeSamplers(c("beta_0", "log_beta", "psi", "sig2_psi", "sigma2"))
  myConfig$addSampler(target = c("psi"), type = "AF_slice")
  addHMC(conf = myConfig, target = c("beta_0", "log_beta", "sig2_psi", "sigma2"))
  myConfig$addMonitors(c("beta_0", "beta", "sigma2", "psi", "sig2_psi"))
  if (wid_aic) myConfig$enableWAIC <- TRUE # this was modified to enableWAIC only if requested

  # build
  myMCMC <- buildMCMC(myConfig)

  # compile
  CmyModel <- compileNimble(myMCMC, myModel, showCompilerOutput = TRUE)

  # if(useWAIC)
  #  monitors <- myModel$getParents(myModel$getNodeNames(dataOnly = TRUE), stochOnly = TRUE)
  ## One may also wish to add additional monitors
  # CmyMCMC <- compileNimble(myMCMC)

  results <- runMCMC(CmyModel$myMCMC,
    niter = niter, nburnin = nburnin, thin = thin, nchains = 1, inits = inits[[seed]],
    summary = smmry, WAIC = wid_aic, setSeed = seed
  )

  rm(myModel, myConfig, myMCMC, CmyModel)

  gc()


  return(results)
}


# Note that you may get some warnings because we didn't initialize log_V where Z = 1.

st_process <- proc.time()

clusterExport(N_cluster, varlist = c("run_MCMC_allcode"), envir = environment())
# run the MCMC

chain_output <- parLapply(
  cl = N_cluster, X = 1:4,
  fun = run_MCMC_allcode,
  data = data_mod, code = nimble_code7_10var, constants = constants, inits = init_list,
  niter = N_tot_iter, nburnin = N_burn, thin = N_thin
)

clusterEvalQ(N_cluster, exists("run_MCMC_allcode"))



# It's good practice to close the cluster when you're done with it.
stopCluster(N_cluster)



elapsed <- proc.time() - st_process



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
