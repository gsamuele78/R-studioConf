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

# Fetch page and headers
curl -s -c "$COOKIE_JAR" "$URL_BASE/auth-sign-in" > /tmp/login_page.html

# Extract CSRF
CSRF=$(grep "rs-csrf-token" /tmp/login_page.html | sed -n 's/.*value="\([^"]*\)".*/\1/p')
echo "CSRF Token: $CSRF"

if [ -z "$CSRF" ]; then
    echo "Failed to get CSRF token"
    exit 1
fi

echo "=========================================="
echo "TEST 1: Standard Plaintext (persist=1, NO v)"
echo "Payload: username, password, persist, clientPath, appUri, rs-csrf-token"
echo "Headers: Origin, Referer, Content-Type"
echo "=========================================="
# Logic: RStudio might require Referer/Origin to validate the request is "legit" before parsing body? 
# or maybe it's just strict about Content-Type.
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
echo "TEST 3: Plaintext Package (package=user\npwd)"
echo "Payload: package, persist..."
echo "=========================================="
PAYLOAD="$(printf '%s\n%s' "$USERNAME" "$PASSWORD")"
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    --data-urlencode "package=$PAYLOAD" \
    -d "persist=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"

echo ""
echo "=========================================="
echo "TEST 4: Plaintext Package WITH v=1"
echo "Payload: package, persist, v=1..."
echo "=========================================="
response=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    --data-urlencode "package=$PAYLOAD" \
    -d "persist=1" \
    -d "v=1" \
    -d "clientPath=/rstudio-inner/" \
    -d "appUri=" \
    -d "rs-csrf-token=$CSRF" \
    "$URL_BASE/auth-do-sign-in")
echo "$response" | grep -E "HTTP/|Location"
