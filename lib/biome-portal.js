/**
 * biome-portal.js — Biome Research Platform shared UI utilities
 *
 * Provides a single `Biome` namespace used by every page wrapper:
 *   portal_index, server_status, terminal_wrapper, nextcloud_wrapper, api/docs
 *
 * Load once in <head> via Nginx static file (/biome-portal.js).
 * No external dependencies. ES5-compatible with ES6+ fallback checks.
 */
(function (global) {
    'use strict';

    /* ------------------------------------------------------------------ */
    /* Constants                                                            */
    /* ------------------------------------------------------------------ */
    var CHANNEL_NAME = 'biome-portal-nav';

    /* ------------------------------------------------------------------ */
    /* Navigation                                                           */
    /* ------------------------------------------------------------------ */

    /**
     * goBack() — Return to the Biome Portal tab that opened this service tab.
     *
     * Strategy: BroadcastChannel tells the portal tab to focus() itself,
     * then this tab closes.  Fallback: redirect to '/' for older browsers.
     */
    function goBack() {
        if (typeof BroadcastChannel !== 'undefined') {
            new BroadcastChannel(CHANNEL_NAME).postMessage({ type: 'goHome' });
            setTimeout(function () { window.close(); }, 100);
        } else {
            window.location.href = '/';
        }
    }

    /**
     * listenForGoHome() — Portal tab calls this so service tabs can navigate back.
     * Closes any previously registered channel before registering a new one.
     */
    function listenForGoHome() {
        if (typeof BroadcastChannel === 'undefined') return;
        if (global._biomePortalChannel) {
            global._biomePortalChannel.close();
        }
        global._biomePortalChannel = new BroadcastChannel(CHANNEL_NAME);
        global._biomePortalChannel.onmessage = function (e) {
            if (e.data && e.data.type === 'goHome') {
                window.focus();
            }
        };
    }

    /* ------------------------------------------------------------------ */
    /* Metric utilities (telemetry strip + status page)                    */
    /* ------------------------------------------------------------------ */

    /** Clamp value v between lo and hi. */
    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    /**
     * Return a CSS colour string for a percentage value.
     * @param {number} pct   0-100
     * @param {number} [warnAt=70]
     * @param {number} [critAt=90]
     */
    function colorForPct(pct, warnAt, critAt) {
        warnAt = (warnAt === undefined) ? 70 : warnAt;
        critAt = (critAt === undefined) ? 90 : critAt;
        if (pct >= critAt) return '#f44336';
        if (pct >= warnAt) return '#ff9800';
        return '#4caf50';
    }

    /* ------------------------------------------------------------------ */
    /* Live clock                                                           */
    /* ------------------------------------------------------------------ */

    /**
     * startClock(badgeId) — Update element text every second with '↻ HH:MM:SS'.
     * @param {string} badgeId  DOM id of the badge/span to update.
     * @returns {number}        interval handle (pass to clearInterval to stop).
     */
    function startClock(badgeId) {
        function tick() {
            var el = document.getElementById(badgeId);
            if (el) el.textContent = '\u21bb ' + new Date().toLocaleTimeString();
        }
        tick();
        return setInterval(tick, 1000);
    }

    /* ------------------------------------------------------------------ */
    /* Problem Reporter                                                   */
    /* ------------------------------------------------------------------ */
    function showProblemReporter() {
        if (document.getElementById('biome-problem-modal')) return;

        var overlay = document.createElement('div');
        overlay.id = 'biome-problem-modal';
        overlay.style.position = 'fixed';
        overlay.style.top = '0';
        overlay.style.left = '0';
        overlay.style.width = '100%';
        overlay.style.height = '100%';
        overlay.style.backgroundColor = 'rgba(0,0,0,0.6)';
        overlay.style.backdropFilter = 'blur(5px)';
        overlay.style.zIndex = '999999';
        overlay.style.display = 'flex';
        overlay.style.alignItems = 'center';
        overlay.style.justifyContent = 'center';
        overlay.style.fontFamily = "'Outfit', sans-serif";

        var modal = document.createElement('div');
        modal.style.background = '#fff';
        modal.style.padding = '24px';
        modal.style.borderRadius = '12px';
        modal.style.width = '550px';
        modal.style.maxWidth = '90%';
        modal.style.boxShadow = '0 10px 40px rgba(0,0,0,0.5)';
        modal.style.display = 'flex';
        modal.style.flexDirection = 'column';
        modal.style.gap = '15px';

        var header = document.createElement('h2');
        header.textContent = '🐞 Report a Problem';
        header.style.margin = '0';
        header.style.color = '#2c3e50';
        header.style.fontSize = '1.4rem';

        var instructions = document.createElement('p');
        instructions.style.margin = '0';
        instructions.style.fontSize = '14px';
        instructions.style.color = '#555';
        instructions.innerHTML = 'Please describe the issue. You can also paste screenshots here (<kbd>Ctrl+V</kbd> or <kbd>Cmd+V</kbd>).';

        var textarea = document.createElement('textarea');
        textarea.style.width = '100%';
        textarea.style.height = '140px';
        textarea.style.padding = '12px';
        textarea.style.border = '1px solid #ccd1d9';
        textarea.style.borderRadius = '6px';
        textarea.style.resize = 'vertical';
        textarea.style.boxSizing = 'border-box';
        textarea.style.fontFamily = 'inherit';
        textarea.placeholder = 'Type here or paste an image...';

        var imageList = document.createElement('div');
        imageList.style.display = 'flex';
        imageList.style.gap = '8px';
        imageList.style.flexWrap = 'wrap';
        imageList.style.maxHeight = '120px';
        imageList.style.overflowY = 'auto';

        var images = [];

        textarea.addEventListener('paste', function (e) {
            if (!e.clipboardData || !e.clipboardData.items) return;
            var items = e.clipboardData.items;
            for (var i = 0; i < items.length; i++) {
                if (items[i].type.indexOf('image') !== -1) {
                    var blob = items[i].getAsFile();
                    var reader = new FileReader();
                    reader.onload = function (event) {
                        var base64data = event.target.result;
                        images.push(base64data);
                        var imgWrap = document.createElement('div');
                        imgWrap.style.position = 'relative';
                        var img = document.createElement('img');
                        img.src = base64data;
                        img.style.height = '60px';
                        img.style.borderRadius = '4px';
                        img.style.border = '1px solid #ddd';
                        imgWrap.appendChild(img);
                        imageList.appendChild(imgWrap);
                    };
                    reader.readAsDataURL(blob);
                }
            }
        });

        var btnContainer = document.createElement('div');
        btnContainer.style.display = 'flex';
        btnContainer.style.justifyContent = 'flex-end';
        btnContainer.style.gap = '10px';
        btnContainer.style.marginTop = '10px';

        var cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'Cancel';
        cancelBtn.style.padding = '10px 18px';
        cancelBtn.style.border = '1px solid #ccc';
        cancelBtn.style.background = '#f5f5f5';
        cancelBtn.style.color = '#333';
        cancelBtn.style.borderRadius = '6px';
        cancelBtn.style.cursor = 'pointer';
        cancelBtn.style.fontWeight = 'bold';
        cancelBtn.onclick = function () { document.body.removeChild(overlay); };

        var submitBtn = document.createElement('button');
        submitBtn.textContent = 'Send Report';
        submitBtn.style.padding = '10px 18px';
        submitBtn.style.border = 'none';
        submitBtn.style.background = '#1E88E5'; /* Biome primary blue */
        submitBtn.style.color = '#fff';
        submitBtn.style.borderRadius = '6px';
        submitBtn.style.cursor = 'pointer';
        submitBtn.style.fontWeight = 'bold';

        submitBtn.onclick = function () {
            if (!textarea.value.trim() && images.length === 0) {
                alert('Please provide some text or an image.');
                textarea.focus();
                return;
            }
            submitBtn.textContent = 'Sending...';
            submitBtn.disabled = true;
            submitBtn.style.opacity = '0.7';

            var targetUrl = window.location.protocol + '//' + window.location.host + '/api/v1/report-problem';

            var appName = "Biome Portal";
            var path = window.location.pathname;
            if (path.indexOf('/rstudio') !== -1) appName = "RStudio";
            else if (path.indexOf('/terminal') !== -1) appName = "Terminal";
            else if (path.indexOf('/files') !== -1) appName = "Nextcloud";

            fetch(targetUrl, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: textarea.value,
                    application: appName,
                    images: images,
                    context: {
                        url: window.location.href,
                        userAgent: navigator.userAgent
                    }
                })
            }).then(function (res) {
                if (res.ok) {
                    alert('Problem report sent successfully!');
                    document.body.removeChild(overlay);
                } else {
                    res.text().then(function (t) { alert('Error sending report: ' + t); });
                    submitBtn.textContent = 'Send Report';
                    submitBtn.disabled = false;
                    submitBtn.style.opacity = '1';
                }
            }).catch(function (err) {
                alert('Failed to send report: ' + err);
                submitBtn.textContent = 'Send Report';
                submitBtn.disabled = false;
                submitBtn.style.opacity = '1';
            });
        };

        btnContainer.appendChild(cancelBtn);
        btnContainer.appendChild(submitBtn);

        modal.appendChild(header);
        modal.appendChild(instructions);
        modal.appendChild(textarea);
        modal.appendChild(imageList);
        modal.appendChild(btnContainer);
        overlay.appendChild(modal);

        document.body.appendChild(overlay);
        textarea.focus();
    }

    /* ------------------------------------------------------------------ */
    /* Public API                                                           */
    /* ------------------------------------------------------------------ */
    global.Biome = {
        CHANNEL: CHANNEL_NAME,
        goBack: goBack,
        listenForGoHome: listenForGoHome,
        clamp: clamp,
        colorForPct: colorForPct,
        startClock: startClock,
        showProblemReporter: showProblemReporter
    };

}(window));
