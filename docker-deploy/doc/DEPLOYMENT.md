# Deployment Guide

How to build and deploy the RStudio "Pet Container" stack.

## 1. Configuration

Copy the `.env.example` (if exists) or check `.env`.

**Key Variables in `.env`:**

* `AUTH_BACKEND`: `sssd` or `samba` (Must match Host Join method).
* `HOST_DOMAIN`: The DNS name of this server (e.g., `botanical.example.com`).
* `STEP_CA_URL` / `STEP_TOKEN`: For automatic certificate enrollment.

## 2. Build Images

The stack uses a dynamic build process based on the `AUTH_BACKEND` profile.

```bash
# For SSSD Backend
docker-compose --profile sssd build

# For Samba Backend
docker-compose --profile samba build
```

## 3. Start Services

```bash
# Start in background
docker-compose --profile sssd up -d
```

## 4. Verify Access

* **Web Portal**: `https://<HOST_DOMAIN>/`
* **RStudio**: `https://<HOST_DOMAIN>/rstudio/`
* **Terminal**: `https://<HOST_DOMAIN>/terminal/`

## 5. Maintenance

* **Logs**: `docker-compose logs -f`
* **Restart**: `docker-compose restart`
* **Update Scripts**: If you change scripts in `docker-deploy/scripts/`, rebuild the containers.
