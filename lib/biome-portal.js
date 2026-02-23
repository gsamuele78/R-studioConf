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
    /* Public API                                                           */
    /* ------------------------------------------------------------------ */
    global.Biome = {
        CHANNEL: CHANNEL_NAME,
        goBack: goBack,
        listenForGoHome: listenForGoHome,
        clamp: clamp,
        colorForPct: colorForPct,
        startClock: startClock
    };

}(window));
