### This function is needed if we want to have an unknown rho/phi

# expcov <- nimbleFunction(     
#   run = function(dists = double(2), rho = double(0), sigma = double(0)) {
#     returnType(double(2))
#     n <- dim(dists)[1]
#     result <- matrix(nrow = n, ncol = n, init = FALSE)
#     sigma2 <- sigma*sigma
#     
#     for(i in 1:(n-1)){
#       for(j in (i+1):n){
#         temp <- sigma2*exp(-dists[i,j]/rho)
#         result[i, j] <- temp
#         result[j, i] <- temp
#       }
#     }
#     for(i in 1:(n)){
#       result[i, i] <- sigma2
#     }
#     return(result)
#   })
# 
# cExpcov <- compileNimble(expcov)

### Here, beta represents beta* discussed in the supplement, the product of alpha_k and \beta_{k,j}



nimble_code4_10var <- nimbleCode({
  
  beta_0 ~ dnorm(0, var = 10) # modified 100 to 10
  sig2_psi ~ dinvgamma(2, 1) # modified to 2, 1
  prec_use[1:n_loc, 1:n_loc] <- R_inv[1:n_loc, 1:n_loc] / sig2_psi
  psi[1:n_loc] ~ dmnorm(zeros[1:n_loc], prec = prec_use[1:n_loc, 1:n_loc])
  
  for(i in 1:p){
    log(beta[i]) ~ dnorm(0, var = 10) # modified 100 to 10
  }
  
  # for(i in 1:p_sigma){
  #   beta_sigma[i] ~ dnorm(0, var = 100)
  # }
  
  linpred[1:n] <- (x[1:n, 1:p] %*% beta[1:p])[1:n,1]
  sigma2 ~ dinvgamma(2, 1) # modified to 2, 1
  
  for(i in 1:n){
    mu[i] <- beta_0 + linpred[i] + abs(psi[row_ind[i]] - psi[col_ind[i]])
    
    censored[i] ~ dinterval(log_V[i], c[i])
    log_V[i] ~ dnorm(mu[i], var = sigma2)
  }
  
})


nimble_code7_10var <- nimbleCode({
  
  beta_0 ~ dnorm(0, var = 10) # modified 100 to 10
  sig2_psi ~ dinvgamma(2, 1) # modified to 2, 1
  prec_use[1:n_loc, 1:n_loc] <- R_inv[1:n_loc, 1:n_loc] / sig2_psi
  psi[1:n_loc] ~ dmnorm(zeros[1:n_loc], prec = prec_use[1:n_loc, 1:n_loc])
  
  for(i in 1:p){
    log(beta[i]) ~ dnorm(0, var = 10) # modified 100 to 10
  }
  
  # for(i in 1:p_sigma){
  #   beta_sigma[i] ~ dnorm(0, var = 100)
  # }
  
  linpred[1:n] <- (x[1:n, 1:p] %*% beta[1:p])[1:n,1]
  sigma2 ~ dinvgamma(2, 1) # modified to 2, 1
  
  for(i in 1:n){
    mu[i] <- beta_0 + linpred[i] + (psi[row_ind[i]] - psi[col_ind[i]])^2
    
    censored[i] ~ dinterval(log_V[i], c[i])
    log_V[i] ~ dnorm(mu[i], var = sigma2)
  }
  
})