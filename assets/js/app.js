// Colloq — JavaScript entry point
// LiveView client, hooks, and service worker registration

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import Hooks from "./hooks.js";

// PWA — Service Worker registration
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js", { scope: "/" }).then(() => {
    console.log("[Colloq] SW registrado.");
  }).catch((err) => {
    console.error("[Colloq] Error registrando SW:", err);
  });
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
  longPollFallbackMs: 2500
});

document.addEventListener("DOMContentLoaded", () => liveSocket.connect());

window.liveSocket = liveSocket;
