options(error = function() {
  traceback(2)
  q(status = 1)
})

cat("Starting script\n")

geo_distmat <- readRDS("geodistmat.rds")

cat("Object loaded\n")
cat("dim =", dim(geo_distmat), "\n")
cat("range =", range(geo_distmat), "\n")
cat("isSymmetric =", isSymmetric(geo_distmat), "\n")

res <- vector("list", 50)

for (i in 1:50) {
  cat("\n--- iteration:", i, "---\n")
  flush.console()
  
  rho_scaling <- max(geo_distmat) / i
  cat("rho_scaling =", rho_scaling, "\n")
  flush.console()
  
  r_spatial <- exp(-geo_distmat / rho_scaling)
  cat("r_spatial built\n")
  flush.console()
  
  out <- isSymmetric((1 / 0.001) * solve(r_spatial))
  cat("result =", out, "\n")
  flush.console()
  
  res[[i]] <- out
}

cat("\nCompleted successfully\n")
print(res)