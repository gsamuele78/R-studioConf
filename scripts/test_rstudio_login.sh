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

echo "=== TEST 1: Standard Plaintext (persit=1, no v) ==="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP|Location"

echo "=== TEST 2: Plaintext in 'package' field ==="
# Maybe it still expects 'package' but unencrypted?
PAYLOAD="$USERNAME\n$PASSWORD"
# Encode newlines?
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    --data-urlencode "package=$PAYLOAD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP|Location"

echo "=== TEST 3: Plaintext with 'v=1' ==="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "v=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP|Location"

