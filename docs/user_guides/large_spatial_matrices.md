# BIOME-CALC: Working with Large Spatial Correlation Matrices

## Problem: OOM on Dense Distance Matrix Operations

If your code looks like this:

```r
# THIS WILL OOM FOR N > ~5,000 on a 400GB server
geo_distmat <- geosphere::distm(coords)  # N × N dense matrix
sapply(1:50, function(i) {
  rho_scaling <- max(geo_distmat)/i
  r_spatial <- exp(-geo_distmat/rho_scaling)
  solve(r_spatial)  # Matrix inversion: O(n³) + ~3× memory of input
})
```

**Why it fails**: A 100,000 × 100,000 matrix uses **~74.5 GB**. The `solve()` function
needs ~3× that (input + output + LAPACK workspace) = **~225 GB** just for the inversion.
With 50 iterations in `sapply`, R accumulates temporary copies faster than the garbage
collector can free them.

## Memory Requirements by Matrix Size

| N (points) | Distance Matrix | solve() Total | Feasible on 400GB? |
|-----------|----------------|---------------|---------------------|
| 1,000     | 7.6 MB         | ~30 MB        | ✅ Yes              |
| 5,000     | 190 MB         | ~760 MB       | ✅ Yes              |
| 10,000    | 760 MB         | ~3 GB         | ✅ Yes              |
| 20,000    | 3 GB           | ~12 GB        | ✅ Yes              |
| 50,000    | 19 GB          | ~75 GB        | ⚠️ Tight (1 iter)  |
| 100,000   | 74.5 GB        | ~300 GB       | ❌ OOM              |

## Solution 1: Sparse Matrix with Distance Threshold (Recommended)

For spatial correlations, points far apart have near-zero correlation.
Set a threshold distance and zero out everything beyond it:

```r
library(Matrix)    # For sparse matrices
library(geosphere) # For distance computation

# Step 1: Compute distances IN CHUNKS (never build full dense matrix)
build_sparse_corr <- function(coords, rho, max_dist = NULL) {
  n <- nrow(coords)
  if (is.null(max_dist)) max_dist <- 3 * rho  # exp(-3) ≈ 0.05

  # Build sparse correlation matrix using only nearby points
  message(sprintf("Building sparse correlation (n=%d, rho=%.0f, cutoff=%.0f)...", n, rho, max_dist))
  triplets <- list(i = integer(0), j = integer(0), x = numeric(0))

  chunk_size <- 500  # Process 500 rows at a time
  for (start in seq(1, n, by = chunk_size)) {
    end <- min(start + chunk_size - 1, n)
    # Only compute distances from these rows to ALL other points
    d_chunk <- geosphere::distm(coords[start:end, ], coords)
    for (local_row in seq_len(end - start + 1)) {
      row_idx <- start + local_row - 1
      # Find neighbors within max_dist
      neighbors <- which(d_chunk[local_row, ] < max_dist & seq_len(n) >= row_idx)
      if (length(neighbors) > 0) {
        corr_vals <- exp(-d_chunk[local_row, neighbors] / rho)
        triplets$i <- c(triplets$i, rep(row_idx, length(neighbors)))
        triplets$j <- c(triplets$j, neighbors)
        triplets$x <- c(triplets$x, corr_vals)
      }
    }
    if (start %% 5000 == 1) message(sprintf("  ... processed %d/%d rows", end, n))
  }

  # Build symmetric sparse matrix
  R <- sparseMatrix(
    i = c(triplets$i, triplets$j),
    j = c(triplets$j, triplets$i),
    x = c(triplets$x, triplets$x),
    dims = c(n, n), symmetric = TRUE
  )
  diag(R) <- 1  # Diagonal is always 1
  return(R)
}

# Step 2: Use Cholesky instead of solve() for SPD matrices
# This is 2× faster and uses 50% less memory
check_spd <- function(R_sparse) {
  tryCatch({
    L <- Matrix::Cholesky(R_sparse, perm = TRUE)
    return(TRUE)  # If Cholesky succeeds, matrix is SPD → inverse is symmetric
  }, error = function(e) {
    return(FALSE)  # Not positive definite
  })
}

# Step 3: Run the analysis
coords <- my_data[, c("lon", "lat")]  # Your coordinates
results <- sapply(1:50, function(i) {
  rho_scaling <- 500000 / i  # Use a fixed max distance, not max(distmat)
  R_sparse <- build_sparse_corr(coords, rho = rho_scaling, max_dist = 3 * rho_scaling)
  gc()  # Force cleanup between iterations
  check_spd(R_sparse)
})
```

**Memory reduction**: For 100k points with a 50km cutoff, the sparse matrix might be
**~500 MB** instead of 74.5 GB (99.3% reduction).

## Solution 2: Nearest Neighbor Gaussian Process (NNGP)

For large-scale spatial analysis, use the `spNNGP` or `BRISC` packages:

```r
library(BRISC)  # Bayesian Regression with Nearest Neighbors

# BRISC handles 100k+ points efficiently using NNGP
# No need to build the full distance matrix at all
result <- BRISC_estimation(
  coords = coords,          # N × 2 matrix
  y = response_variable,    # N × 1 vector
  n.neighbors = 15,         # Only use 15 nearest neighbors
  cov.model = "exponential" # Matches exp(-d/rho)
)
```

## Solution 3: Block Processing for `geosphere::distm()`

If you do need the full distance matrix, compute it in blocks:

```r
# Instead of: distmat <- geosphere::distm(coords)  # FULL N×N matrix
# Do this: process in blocks and write to disk

library(bigmemory)  # Memory-mapped matrix (lives on disk, not RAM)

n <- nrow(coords)
geo_distmat <- big.matrix(n, n, type = "double",
                          backingfile = "distmat.bin",
                          descriptorfile = "distmat.desc")

chunk_size <- 1000
for (start in seq(1, n, by = chunk_size)) {
  end <- min(start + chunk_size - 1, n)
  geo_distmat[start:end, ] <- geosphere::distm(coords[start:end, ], coords)
  gc()
  message(sprintf("Computed rows %d-%d of %d", start, end, n))
}
```

## When to Use NFS Fallback

If you need to materialize temporary raster files during spatial analysis,
BIOME-CALC v9.6 will automatically redirect to NFS when tmpfs exceeds 75%.

For explicit large-data operations:
```r
Sys.setenv(BIOME_FORCE_NFS_TMP = "true")  # Before loading terra/raster
library(terra)
# terra will now write temps to NFS, not RAMDisk
```

## Quick Reference: Maximum Safe Matrix Sizes

| Available RAM | Max N for solve() | Max N for Cholesky | Max N sparse (15 neighbors) |
|--------------|-------------------|--------------------|-----------------------------|
| 50 GB        | ~8,000            | ~11,000            | ~500,000                    |
| 100 GB       | ~11,500           | ~16,000            | ~1,000,000                  |
| 200 GB       | ~16,000           | ~23,000            | ~2,000,000                  |
| 300 GB       | ~20,000           | ~28,000            | ~5,000,000                  |
