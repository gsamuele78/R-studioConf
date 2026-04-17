# this code runs model 7 - quick crash test version

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


# Data imported from GDM_ForesteCasentinesi.Rproj

# load(file = 'Casentino/Data_for_spGDMM_Casentino.RData')
# load(file= "Lagorai/Data_for_spGDMM_Lagorai.RData") # new 16.02
load(file = "Data_for_spGDMM_Lagorai.RData")

#------------------------------------------------------------------------
# Get Initial values for modeling fitting
#------------------------------------------------------------------------

# fit lm to log(dissimilarty) - latent dissimilarity - as a function of X_for_GDM
lm_mod <- lm(log(Obs_Z) ~ X_for_GDM)

lm_out <- optim(c(.3, ifelse(coef(lm_mod)[-1] > 0, log(coef(lm_mod)[-1]), -10), rnorm(N_sites)), function(par) {
  sum((log(Obs_Z) - par[1] - X_for_GDM %*% exp(par[2:(N_col_XforGDM + 1)]) - (par[N_col_XforGDM + 1 + row_ind] - par[N_col_XforGDM + 1 + col_ind])^2)^2)
}, method = "BFGS")

# check convergence
lm_out$convergence

#------------------------------------------------------------------------
# Source nimble models -- Models 1-9 match those in paper
#------------------------------------------------------------------------

source("nimble_models_10var21invgamma.R")

# create constants for nimble model
constants <- list(
  n = Smp_size,
  p = N_col_XforGDM,
  x = X_for_GDM,
  n_loc = N_sites,
  R_inv = R_inv,
  zeros = rep(0, N_sites),
  row_ind = row_ind,
  col_ind = col_ind
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
n_chains <- 4

set.seed(46534)

init_list <- replicate(n = 4, expr = {
  list(
    beta_0 = lm_out$par[1] + rnorm(n = 1, mean = 0, sd = .1),
    log_beta = lm_out$par[2:(N_col_XforGDM + 1)] + rnorm(n = length(2:(N_col_XforGDM + 1)), mean = 0, sd = .05),
    sig2_psi = abs(0.07 + rnorm(n = 1, mean = 0, sd = .01)),
    sigma2 = abs(sigma(lm_mod)^2 + rnorm(n = 1, mean = 0, sd = .01)),
    psi = lm_out$par[-(1:(N_col_XforGDM + 1))] + rnorm(n = N_sites, mean = 0, sd = .00001)
  )
}, simplify = FALSE)

names(init_list) <- paste0("Ch_", seq_len(n_chains))

#------------------------------------------------------------------------
# 1-chain quick test to see if it crashes
#------------------------------------------------------------------------

library(nimble)
library(nimbleHMC)

# get list of inits
test_n_chains <- 1
init_1ch <- init_list[seq_len(test_n_chains)]

# run the check
model_1ch <- nimbleModel(
  nimble_code7_10var,
  constants = constants,
  data = data_mod,
  inits = init_1ch[[1]],
  buildDerivs = TRUE
)

mcmcConf_1ch <- configureMCMC(model_1ch)

mcmcConf_1ch$removeSamplers(c("beta_0", "log_beta", "psi", "sig2_psi", "sigma2"))

# add AF_slice sampler only for psi params
mcmcConf_1ch$addSampler(target = c("psi"), type = "AF_slice")

# HMC for the other parameters
addHMC(conf = mcmcConf_1ch, target = c("beta_0", "log_beta", "sig2_psi", "sigma2"))

mcmcConf_1ch$addMonitors(c("beta_0", "beta", "sigma2", "psi", "sig2_psi"))

# check samplers being used
mcmcConf_1ch$printSamplers()
# check parameters being monitored
mcmcConf_1ch$printMonitors()

mcmcConf_1ch$enableWAIC <- FALSE

codeMCMC_1ch <- buildMCMC(mcmcConf_1ch)

Cmodel_1ch <- compileNimble(model_1ch)
Cmcmc_1ch <- compileNimble(codeMCMC_1ch, project = model_1ch)

test_start <- proc.time()

# OPTIMIZATION: Force garbage collection before the heavy run to free up system RAM
gc(verbose = FALSE)

# post_samples_1ch <- runMCMC(
#  Cmcmc_1ch,
#  niter = 200,
#  nburnin = 50,
#  inits = init_1ch,
#  thin = 1,
#  nchains = 1,
#  summary = TRUE,
#  WAIC = FALSE
# )

# Cmodel_1ch$codeMCMC_1ch
post_samples_1ch <- runMCMC(
  Cmcmc_1ch,
  niter = 5000,
  nburnin = 2000,
  inits = init_1ch,
  thin = 1,
  nchains = 1,
  summary = TRUE,
  WAIC = F,
  progressBar = TRUE
)


test_end <- proc.time() - test_start

print(test_end)
print(names(post_samples_1ch))
