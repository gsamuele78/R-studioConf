# tests/fixtures/r_lint/martina_mod7.R
# Anonymized fixture: <user_b> — synthetic NIMBLE+PSOCK pattern.
# Expected findings: R005 (setwd), R011 (cross-user path), R012 (compileNimble+parLapply), R014 (save cross-user), R016 (relative load), R017 (makeCluster no type)

library(parallel)
library(nimble)

setwd("/nfs/home/<user_b>/test_<user_b>")

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

save(chain_output, file = "/media/r_projects/<user_other>/mod7_output.RData")
