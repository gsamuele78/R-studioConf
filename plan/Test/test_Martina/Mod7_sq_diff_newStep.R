# this code runs model 7 for the Foreste Casentinesi
graphics.off()
options(device = "RStudioGD")
plot(1:10, 1:10)


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

setwd("test_Martina_orig/BECAUSE")
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
lm_out$convergence # 0

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
# Lagorai sig2_psi = 0.07
init_list <- replicate(n = 4, expr = {
    list(
        beta_0 = lm_out$par[1] + rnorm(n = 1, mean = 0, sd = .1),
        log_beta = lm_out$par[2:(N_col_XforGDM + 1)] + rnorm(n = length(2:(N_col_XforGDM + 1)), mean = 0, sd = .05), # changed .01 to .05 for log_beta
        sig2_psi = 0.6 + rnorm(n = 1, mean = 0, sd = .01), sigma2 = sigma(lm_mod)^2 + rnorm(n = 1, mean = 0, sd = .01),
        psi = lm_out$par[-(1:(N_col_XforGDM + 1))] + rnorm(n = N_sites, mean = 0, sd = .0005)
    ) # changed .00001 to .01 #changed .01 to .005
}, simplify = F)

names(init_list) <- paste0("Ch_", seq_len(n_chains))


# !!!!!!! fino a qua!!!!!
