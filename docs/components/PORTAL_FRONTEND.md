# Portal Frontend Documentation

## 1. Overview

The **Portal Frontend** (`portal_index.html.template`) is the user's primary interface. It acts as a dashboard and an authentication broker.

**Key Technologies**:

- **HTML5**: Semantic structure.
- **CSS3**: Responsive design (Flexbox/Grid), Glassmorphism aesthetics.
- **JavaScript (Vanilla)**: Auto-login logic, Credential Management.

---

## 2. Authentication Logic (Auto-Login)

The core feature of the portal is the **"One-Click Connect"**.
Instead of asking users to log in to Nginx, then RStudio, then Nextcloud, the Portal handles the handshake.

### 2.1 The `handleConnect` Flow

1. **User Input**: User enters credentials in the "Secure Connect" modal.
2. **Validation**: `fetch('/auth-check')` tests these credentials against Nginx.
    - *Success (200)*: Proceed.
    - *Fail (401/403)*: Show error "Invalid Credentials".
3. **Parallel Sign-In**:
    - **RStudio**: Calls `loginRStudio(user, pass)`.
    - **Nextcloud**: Calls `loginNextcloud(user, pass)`.
4. **Terminal Prep**: Rewrites the "Secure Terminal" tile URL to `https://user:pass@host/terminal/` (New Tab Strategy).
5. **UI Unlock**: Removes the blur effect and changes the button to "Logout".

### 2.2 RStudio Integration Detail

RStudio uses a complex CSRF protection mechanism requiring a "Double Submit Cookie".

**The Algo**:

```javascript
function loginRStudio(username, password) {
    // 1. Generate strong random UUID (CSPRNG)
    var token = crypto.randomUUID();

    // 2. Set TWO cookies (legacy + modern names)
    // Path must match the proxy path /rstudio-inner/
    document.cookie = "csrf-token=" + token + "; path=/rstudio-inner/; secure";
    document.cookie = "rs-csrf-token=" + token + "; path=/rstudio-inner/; secure";

    // 3. Send credentials in Body + the SAME token
    var body = new URLSearchParams();
    body.append('csrf-token', token);
    // ... username/password ...
    
    // 4. POST to /auth-do-sign-in
    fetch("/rstudio-inner/auth-do-sign-in", { body: body ... });
}
```

### 2.3 Terminal Integration Detail

Since `ttyd` uses Basic Auth, we cannot straightforwardly "post" credentials.
**Strategy**: URL Injection.

- **Link**: `https://user:pass@host/terminal/`
- **Security**: The link opens in a `_blank` tab. The wrapper page inside that tab immediately runs `history.replaceState` to scrub the password from the address bar.

---

## 3. Responsive Design

The layout (`portal_style.css.template`) is built to be mobile-friendly.

- **Grid**: `grid-template-columns: repeat(auto-fit, minmax(280px, 1fr))` automatically stacks cards on smaller screens.
- **Scrolling**: `overflow-y: auto` ensures content is scrollable if it exceeds the viewport height (e.g., on phones).
- **Flex Header**: The header collapses gracefully, stacking the logo and title.

## 4. File Structure

- `templates/portal_index.html.template`: The main HTML/JS logic.
- `templates/portal_style.css.template`: The visual styling.
- `assets/`: Logo and background images.
