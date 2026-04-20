# ==============================================================================
# SAFE HEAVY CALCULATION TEMPLATE (BIOME-CALC SERVER)
# ==============================================================================
# INSTRUCTIONS:
# 1. Do NOT run this script line-by-line in the main RStudio console.
# 2. To run: Go to the "Jobs" tab -> "Start Local Job" -> Select this script.
#    (Alternatively, run via the Secure Terminal using `Rscript this_file.R`)
# 3. You can safely close your browser, shut your laptop, and log out.
# 4. Check progress anytime by opening 'mcmc_progress_log.txt' in the Files pane.
# ==============================================================================

# --- 1. LOAD LIBRARIES & DATA ---
library(nimble)
library(coda)
# (Load your other required libraries here)

# Load your starting data (This is fine for input data, just don't save it back on exit!)
load(file = "Data_for_spGDMM_Lagorai.RData")

# --- 2. SETUP FILE-BASED LOGGING ---
# We pipe the output to a text file so you can check progress after closing your browser.
log_file_path <- "mcmc_progress_log.txt"
log_connection <- file(log_file_path, open = "wt")

sink(log_connection, type = "output")
sink(log_connection, type = "message") # This captures the NIMBLE progress bar!

cat("====================================================\n")
cat(sprintf("Calculation started at: %s\n", Sys.time()))
cat("====================================================\n")
cat("Compiling NIMBLE models. This may take a moment...\n")

# --- 3. COMPILE AND RUN THE MODEL ---
# (Using your Martina2 structure as the example)
Cmodel_1ch <- compileNimble(model_1ch)
Cmcmc_1ch <- compileNimble(codeMCMC_1ch, project = model_1ch)

cat("Models compiled successfully. Starting MCMC...\n")

# Run the calculation! 
post_samples_1ch <- runMCMC(
  Cmcmc_1ch,
  niter = 5000,
  nburnin = 2000,
  inits = init_1ch,
  thin = 1,
  nchains = 1,
  summary = TRUE,
  WAIC = FALSE,
  progressBar = TRUE  # This prints directly into the text file now
)

cat("\n====================================================\n")
cat(sprintf("MCMC finished at: %s\n", Sys.time()))
cat("====================================================\n")

# --- 4. END LOGGING ---
sink(type = "message")
sink(type = "output")
close(log_connection)

# ==============================================================================
# 5. REQUIRED CLEANUP & SAFE SAVING (CRITICAL FOR SERVER STABILITY)
# ==============================================================================

# A. Save ONLY the final mathematical results (the actual samples)
final_data_file <- "MCMC_results_Lagorai_Model7.rds"
saveRDS(post_samples_1ch, file = final_data_file)
print(paste("✅ Results safely saved to:", final_data_file))

# B. Destroy C++ Pointers in RAM
# If RStudio attempts to auto-save compiled NIMBLE models, it will corrupt the 
# session and cause a massive memory leak that crashes the server on your next login.
rm(model_1ch, Cmodel_1ch, codeMCMC_1ch, Cmcmc_1ch, mcmcConf_1ch)

# C. Clear massive input dataframes to free up RAM
# rm(Obs_Z, X_for_GDM, data_mod) 

# D. Force the Linux Kernel to reclaim the freed RAM immediately
gc()

print("✅ Environment cleaned. You can now safely close RStudio.")
