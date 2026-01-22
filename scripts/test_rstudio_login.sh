#!/bin/bash
# test_rstudio_login.sh
# Tests RStudio plaintext login using curl

USERNAME="gianfranco.samuele2"
# Ask for password safely
read -s -p "Enter Password for $USERNAME: " PASSWORD
echo ""

COOKIE_JAR="/tmp/rstudio_cookies.txt"
rm -f "$COOKIE_JAR"

echo "1. Fetching Login Page (for CSRF token)..."
# Using 127.0.0.1:8787 directly to bypass Nginx for raw server check
# Note: RStudio might expect /rstudio-inner/ path if www-root-path is set
URL_BASE="http://127.0.0.1:8787"

# Fetch page and headers
curl -s -c "$COOKIE_JAR" "$URL_BASE/auth-sign-in" > /tmp/login_page.html

# Extract CSRF
CSRF=$(grep "rs-csrf-token" /tmp/login_page.html | sed -n 's/.*value="\([^"]*\)".*/\1/p')
echo "CSRF Token: $CSRF"

if [ -z "$CSRF" ]; then
    echo "Failed to get CSRF token"
    exit 1
fi

echo "2. Attempting Plaintext Login (No 'v', using 'persist')..."
# Send POST
# Hypothesis: Sending 'v' triggers encrypted auth mode. Removing it to force plaintext check.
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/rstudio-inner/auth-do-sign-in")

# Note: Changed URL to include /rstudio-inner/ prefix to match Nginx proxy path validation if needed
# But tested directly against 8787, so maybe path doesn't matter as much, but let's be safe.
# Actually, if testing against 127.0.0.1:8787 directly, the path is likely just /auth-do-sign-in
# UNLESS www-root-path is set (which it is: /rstudio-inner).
# So request should probably go to $URL_BASE/auth-do-sign-in but with Referer?
# Wait, rserver.conf has www-root-path=/rstudio-inner
# So the server LISTENS on /, but expects the path to be /rstudio-inner/auth-do-sign-in?
# Or does it rewrite?
# Nginx does `proxy_pass http://127.0.0.1:8787/;` (stripping prefix).
# So physically on port 8787, the endpoint is likely `/auth-do-sign-in`.
# Let's revert to $URL_BASE/auth-do-sign-in first.

response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")

echo "--- Response Headers ---"
echo "$response" | head -n 20
echo "--- End Headers ---"

if echo "$response" | grep -q "302 Found"; then
    echo "SUCCESS: Login Redirected (302)"
else
    echo "FAILURE: Login did not redirect"
fi
