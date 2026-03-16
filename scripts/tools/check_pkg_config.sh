#!/bin/bash

# Function to check and print pkg-config variables
check_pkg_config_vars() {
  echo "Checking pkg-config variables for OpenBLAS and OpenMP..."

  # Get the compiler and linker flags for OpenBLAS
  OPENBLAS_CFLAGS=$(pkg-config --cflags openblas)
  OPENBLAS_LIBS=$(pkg-config --libs openblas)

  # Get the compiler and linker flags for OpenMP
  OPENMP_CFLAGS=$(pkg-config --cflags openmp)
  OPENMP_LIBS=$(pkg-config --libs openmp)

  # Print the flags
  echo "OpenBLAS CFLAGS: $OPENBLAS_CFLAGS"
  echo "OpenBLAS LIBS: $OPENBLAS_LIBS"
  echo "OpenMP CFLAGS: $OPENMP_CFLAGS"
  echo "OpenMP LIBS: $OPENMP_LIBS"
}

# Check pkg-config variables
check_pkg_config_vars

echo "All done."
