# Troubleshooting & Testing

## Common Issues

### 1. Authentication Fails (RStudio)

* **Symptom**: "Incorrect or invalid username/password"
* **Check**:
  * Is the host joined to AD? (`getent passwd <user>`)
  * Is the socket mounted? (`docker exec -it rstudio ls -l /var/lib/sss/pipes/nss`)
  * Are permissions correct on the socket?
  * Logs: `docker-compose logs rstudio`

### 2. Nginx 502 Bad Gateway

* **Symptom**: Portal loads, but RStudio/Terminal shows 502.
* **Check**:
  * Is the backend container running? (`docker ps`)
  * Are they on the same network? (Check `docker-compose.yml` networks)
  * Logs: `docker-compose logs nginx`

### 3. Terminal (TTYD) Immediate Logout

* **Symptom**: Terminal opens but immediately closes or says "Forbidden".
* **Check**:
  * Nginx header passing: `X-Forwarded-User` must be set.
  * RStudio container logs: TTYD runs *inside* the RStudio container. Check `docker logs rstudio`.

## Testing Procedures

### 1. Verify Host Prerequisites

```bash
# Time Sync
timedatectl status

# AD Join
id <ad_user>
```

### 2. Verify Container Trust

```bash
# Check if Root CA is installed in RStudio container
docker exec -it rstudio ls -l /usr/local/share/ca-certificates/step_root_ca.crt
```

### 3. Verify SSL (Nginx)

Access `https://<HOST_DOMAIN>` and view the certificate details in the browser. It should be issued by "Internal Step-CA", not "Snakeoil".
