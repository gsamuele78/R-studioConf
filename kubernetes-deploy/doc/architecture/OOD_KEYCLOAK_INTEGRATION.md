# OIDC and Keycloak Integration (OAuth2-Proxy Sidecar)

The Kubernetes implementation utilizes `oauth2-proxy` to broker Single Sign-On (SSO) between external Identity Providers (like Keycloak deployed in `Infra-Iam-PKI`) and the Nginx Portal.

## Architecture

Instead of handling complex reverse proxy logic inside the application container, `oauth2-proxy` is deployed as a cluster-internal authentication broker (`oauth2-proxy-deployment.yaml`).

Nginx operates using `auth_request` sub-requests to validate sessions.

1. **User requests `/rstudio/`** -> Nginx intercepts.
2. Nginx emits an internal sub-request to `http://oauth2-proxy.botanical.svc.cluster.local:4180/oauth2/auth`.
3. If no session cookie exists, proxy returns HTTP 401.
4. Nginx redirects the user to `/oauth2/sign_in`, which bounces the user to the Keycloak Login Page.
5. User authenticates via Keycloak -> returns Token -> Proxy sets Secure Cookie -> Traffic permitted to RStudio backend.

## Configuration Variables

The variables required to bind the OIDC flow have been extracted securely out of YAML manifests and into the `env/.env.prd` file.

| Variable | Target Manifest | Purpose |
|----------|-----------------|---------|
| `OAUTH2_COOKIE_SECRET` | `secrets.yaml` | The cryptographic entropy used to sign the session token cookies. Must be EXACTLY 32 bytes (base64 encoded). |
| `OIDC_CLIENT_ID` | `secrets.yaml` | The OIDC client registration string configured in Keycloak. |
| `OIDC_CLIENT_SECRET` | `secrets.yaml` | The OIDC client password configured in Keycloak. |
| `OIDC_ISSUER_URL` | `configmaps.yaml` | The discovery URI for the auth server (e.g. `https://keycloak.../realms/personale`). |

## Enabling OIDC in Nginx

To fully shift Nginx from internal PAM authentication (Active Directory direct) to federated OIDC Single Sign-On, the Nginx configuration must be toggled:

1. Open `kubernetes-deploy/conf/nginx_proxy_location.conf`.
2. Navigate to the `/auth-check` location directive.
3. Comment out the `auth_pam` lines.
4. Uncomment the `auth_request /oauth2/auth;` lines.
5. Apply the updated ConfigMap using `./scripts/deploy_k8s.sh`.
