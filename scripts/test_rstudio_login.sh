#!/bin/bash
# test_rstudio_login.sh
# Tests RStudio plaintext login using curl with multiple variations

USERNAME="gianfranco.samuele2"
# Ask for password safely
read -s -p "Enter Password for $USERNAME: " PASSWORD
echo ""

COOKIE_JAR="/tmp/rstudio_cookies.txt"
rm -f "$COOKIE_JAR"

echo "1. Fetching Login Page (for CSRF token)..."
URL_BASE="http://127.0.0.1:8787"

# Fetch page and headers (Follow redirects with -L to ensure we land on the real page)
curl -s -L -c "$COOKIE_JAR" "$URL_BASE/auth-sign-in" > /tmp/login_page.html

# Extract CSRF
CSRF=$(grep "rs-csrf-token" /tmp/login_page.html | sed -n 's/.*value="\([^"]*\)".*/\1/p')
echo "CSRF Token: $CSRF"

echo "--- Cookie Jar Content (Original) ---"
cat "$COOKIE_JAR"
echo "--------------------------"

# FIX: RStudio set cookies for /rstudio-inner, but we are posting to / (physically).
# Curl won't send cookies if path doesn't match. We must hack the jar.
sed -i 's|/rstudio-inner|/|g' "$COOKIE_JAR"

echo "--- Cookie Jar Content (Patched) ---"
cat "$COOKIE_JAR"
echo "--------------------------"

if [ -z "$CSRF" ]; then
    echo "Failed to get CSRF token"
    exit 1
fi

echo
echo "=========================================="
echo "TEST 1: Standard Plaintext (persist=1, NO v)"
echo "Payload: username, password, persist, clientPath, appUri, rs-csrf-token"
echo "URL: $URL_BASE/auth-do-sign-in (Patched cookies)"
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: $URL_BASE/auth-sign-in" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

echo ""
echo "=========================================="
echo "TEST 2: Plaintext WITH v=1"
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: $URL_BASE/auth-sign-in" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "v=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

echo ""
echo "=========================================="
echo "TEST 3: Plaintext Package in 'v' (v=user\npwd)"
echo "Payload: v=username\npassword, persist=1..."
echo "=========================================="
PAYLOAD="$(printf '%s\n%s' "$USERNAME" "$PASSWORD")"
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: $URL_BASE/auth-sign-in" \
    --data-urlencode "v=$PAYLOAD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

echo ""
echo "=========================================="
echo "TEST 6: Plaintext with EMPTY Referer"
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: " \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/rstudio-inner/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

echo ""
echo "=========================================="
echo "TEST 7: Plaintext with PORTAL Referer (simulating browser)"
echo "Referer: $URL_BASE/"
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: $URL_BASE/" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/rstudio-inner/auth-do-sign-in")

echo ""
echo "=========================================="
echo "TEST 8: Referer with EXTERNAL IP (Simulating Nginx current spoof)"
echo "Referer: http://137.204.119.225/rstudio-inner/auth-sign-in"
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: http://137.204.119.225/rstudio-inner/auth-sign-in" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/rstudio-inner/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

echo ""
echo "=========================================="
echo "TEST 9: Referer with LOCALHOST (Simulating proposed spoof)"
echo "Referer: http://127.0.0.1:8787/rstudio-inner/auth-sign-in"
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Origin: $URL_BASE" \
    -H "Referer: http://127.0.0.1:8787/rstudio-inner/auth-sign-in" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/rstudio-inner/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

