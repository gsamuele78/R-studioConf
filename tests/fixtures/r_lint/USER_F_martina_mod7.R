# tests/fixtures/r_lint/USER_F_martina_mod7.R
# Anonymized fixture: USER_A — synthetic NIMBLE+PSOCK pattern.
# Expected findings: R005 (setwd), R011 (cross-user path), R012 (compileNimble+parLapply), R014 (save cross-user), R016 (relative load), R017 (makeCluster no type)

library(parallel)
library(nimble)

# R005: setwd to a hardcoded absolute path
# R011: cross-user absolute path
# R005: setwd to a hardcoded absolute path
# R011: cross-user absolute path
setwd("/nfs/home/USER_A/test_USER_A")

load(file = "Data_for_spGDMM_Lagorai.RData")

run_MCMC <- function(seed, data, code, constants, inits, niter, nburnin) {
    require(nimble)
    myModel <- nimbleModel(code = code, data = data, constants = constants)
    myMCMC <- buildMCMC(configureMCMC(myModel))
    CmyModel <- compileNimble(myMCMC, myModel)
    runMCMC(CmyModel$myMCMC, niter = niter, nburnin = nburnin, inits = inits[[seed]])
}

cl <- makeCluster(4)
clusterEvalQ(cl, {
    library(nimble)
})
clusterExport(cl, varlist = c("run_MCMC", "data_mod", "constants", "init_list"))

# compileNimble inside parLapply worker — serialization trap
chain_output <- parLapply(cl, 1:4,
    fun = run_MCMC,
    data = data_mod, code = nimble_code, constants = constants,
    inits = init_list, niter = 25000, nburnin = 20000
)

stopCluster(cl)

# R014: cross-user write
# R014: cross-user write
save(chain_output, file = "/media/r_projects/USER_B/mod7_output.RData")
