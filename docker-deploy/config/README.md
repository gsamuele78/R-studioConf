# Docker Deployment Configuration

Configuration for this Docker deployment has been consolidated.

## Where is the config?

All Service, Version, and Port configuration is now located in the single **`.env`** file at the root of `docker-deploy/`.

## Why are files missing?

Legacy `*.vars.conf` files have been removed in favor of the standard `.env` approach for Docker. R package lists are embedded in `scripts/install_botanical_packages.R`.
