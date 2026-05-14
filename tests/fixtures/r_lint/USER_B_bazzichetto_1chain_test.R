# r have to be present
# Anonymized fixture: USER_B — single-chain HMC test variant.
# Expected findings: R009 (rm-list-ls), R014 (cross-user save), R015 (init_list[[ from globalenv), R016 (relative load)

library(nimble)

load(file = "Data_for_spGDMM.RData")

# init_list is expected to live in globalenv after the load() above
chain_seed <- 1
inits_used <- init_list[[chain_seed]]

myModel <- nimbleModel(code = nimble_code, data = data_mod, constants = constants, inits = inits_used)

# ... run ...
to_del <- ls()
rm(list = to_del)

save(myModel, file = "/media/r_projects/USER_B/1chain_HMC_test.RData")
