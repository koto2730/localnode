/* =============================================================================
 * LocalNode Web UI theme hook (#304) — example / starter
 * =============================================================================
 *
 * Point the server at this file to run custom JS in the Web UI:
 *   localnode-cli --theme-js /etc/localnode/theme.js
 * or `server.theme-js` in config.yaml, or pick it in the GUI app settings.
 *
 * How it works:
 *   - Served same-origin as /theme.js and loaded (deferred) after the app's
 *     own script, on every page including the login screen.
 *   - Omitting --theme-js serves an empty file, so nothing runs.
 *   - Trust: only an administrator can set this path, and the server already
 *     controls everything it serves — so this runs with full page access.
 *     Keep it small and audited; it is not a sandbox.
 *
 * Everything below is optional. This file is a safe no-op as shipped (the real
 * examples are commented out). Uncomment what you want.
 * ========================================================================== */

(function () {
  'use strict';

  // The app initializes on DOMContentLoaded; run your code after that so the
  // main UI already exists. Use `load` if you also need images/fonts ready.
  function onReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn, { once: true });
    } else {
      fn();
    }
  }

  onReady(function () {
    // --- Example 1: brand the browser tab title -----------------------------
    // document.title = 'Home Server — ' + document.title;

    // --- Example 2: add a small banner at the top ---------------------------
    // const banner = document.createElement('div');
    // banner.textContent = '社内ファイル共有 — 取り扱い注意';
    // banner.style.cssText =
    //   'background:#6366f1;color:#fff;padding:6px 12px;text-align:center;font-size:13px;';
    // document.body.prepend(banner);

    // --- Example 3: react to tab changes ------------------------------------
    // The tab buttons carry data-tab="files" | "clipboard".
    // document.querySelectorAll('.tab-btn').forEach(function (btn) {
    //   btn.addEventListener('click', function () {
    //     console.log('tab switched to', btn.dataset.tab);
    //   });
    // });

    // --- Example 4: default the clipboard "from" tag ------------------------
    // const tag = document.getElementById('clipboardTagInput');
    // if (tag && !tag.value) tag.value = 'Reception PC';
  });
})();
