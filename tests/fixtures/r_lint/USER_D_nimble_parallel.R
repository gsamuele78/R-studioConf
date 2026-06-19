# tests/fixtures/r_lint/USER_D_nimble_parallel.R
# Anonymized fixture: USER_D — synthetic NIMBLE+parLapply with extra anti-patterns.
# Expected findings: R009 (rm-list-ls), R012 (compileNimble+parLapply), R014 (cross-user save),
#                    R015 (function depends on globalenv 'init_list'), R016 (relative load),
#                    R017 (makeCluster no type)

library(parallel)
library(nimble)

rm(list = ls())

load(file = "Data_for_spGDMM.RData")

# Closure depends on globalenv name 'init_list'
run_one <- function(seed) {
    require(nimble)
    myModel <- nimbleModel(code = nimble_code, data = data_mod, constants = constants)
    myMCMC <- buildMCMC(configureMCMC(myModel))
    Cmcmc <- compileNimble(myMCMC, myModel)
    runMCMC(Cmcmc$myMCMC, niter = 1000, nburnin = 500, inits = init_list[[seed]])
}

cl <- makeCluster(4)
out <- parLapply(cl, 1:4, run_one)
stopCluster(cl)

save(out, file = "/media/r_projects/USER_C/run_out.RData")
