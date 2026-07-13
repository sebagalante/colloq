// Colloq — JavaScript entry point
// LiveView client, hooks, emojis, and service worker registration

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import Hooks from "./hooks.js";
import { initTwemoji, parseEmojis } from "./emojis.js";

// PWA — Service Worker registration.
// In development the cache-first service worker serves stale assets and masks
// server changes, so we skip registration on localhost and actively tear down
// any worker + caches left over from a previous session.
const isLocalhost = ["localhost", "127.0.0.1", "[::1]"].includes(window.location.hostname);

if ("serviceWorker" in navigator && !isLocalhost) {
  navigator.serviceWorker.register("/sw.js", { scope: "/" }).then(() => {
    console.log("[Colloq] SW registrado.");
  }).catch((err) => {
    console.error("[Colloq] Error registrando SW:", err);
  });
} else if ("serviceWorker" in navigator) {
  navigator.serviceWorker.getRegistrations().then((regs) => regs.forEach((r) => r.unregister()));
  if (window.caches) {
    caches.keys().then((keys) => keys.forEach((k) => caches.delete(k)));
  }
}

// Twemoji — consistent emoji rendering across platforms
initTwemoji();

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
  longPollFallbackMs: 2500,
  dom: {
    onBeforeElUpdated(from, to) {
      // Re-parse emojis on LiveView DOM updates
      if (to.querySelectorAll) {
        parseEmojis(to);
      }
    }
  }
});

document.addEventListener("DOMContentLoaded", () => {
  liveSocket.connect();
  parseEmojis(document.body);
});

window.liveSocket = liveSocket;
