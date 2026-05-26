#-------------------1 chain HMC for potential debugging

# notice that settings in this script may differ from those reported in the main script (running the 4-chain MCMC)
# this 1-chain test is meant to be used to detect warnings/errors during nimble compiling or running the model
# that would not show up when running the process in parallel

# single chain run to check everything works fine
library(nimble)
library(nimbleHMC) # version ‘0.2.3’

to_del <- ls()
to_del <- to_del[!to_del %in% c("bash_script", "check_quota", ".Last.value")]

# rm(list = to_del)
# rm(to_del)

gc()

# get list of inits

test_n_chains <- 1

init_1ch <- init_list[seq_len(test_n_chains)]

# run the check

model_1ch <- nimbleModel(nimble_code7_10var, constants = constants, data = data_mod, buildDerivs = T)

mcmcConf_1ch <- configureMCMC(model_1ch)

mcmcConf_1ch$removeSamplers(c("beta_0", "log_beta", "psi", "sig2_psi", "sigma2"))

# add AF_slice sampler only for psi params: I'm trying the AF_slice sampler for psi params (in combo with HMC for the other parameters)
mcmcConf_1ch$addSampler(target = c("psi"), type = "AF_slice")

# I'm leaving out psi (see above)
addHMC(conf = mcmcConf_1ch, target = c("beta_0", "log_beta", "sig2_psi", "sigma2"))

mcmcConf_1ch$addMonitors(c("beta_0", "beta", "sigma2", "psi", "sig2_psi"))

# check samplers being used
mcmcConf_1ch$printSamplers()
# check parameters being monitored
mcmcConf_1ch$printMonitors()

mcmcConf_1ch$enableWAIC <- FALSE

codeMCMC_1ch <- buildMCMC(mcmcConf_1ch)

Cmodel_1ch <- nimble::compileNimble(model_1ch)
# CmodelMCMC_1ch <- nimble::compileNimble(codeMCMC_1ch, project = model_1ch)
CmodelMCMC_1ch <- nimble::compileNimble(codeMCMC_1ch, model_1ch)
