// KILL-SWITCH service worker.
// The previous cache-first worker served stale assets in development and could
// not be updated (it re-served its own cached app.js). This replacement
// unregisters itself and deletes all caches on the next navigation, then
// reloads open pages so they fetch fresh from the server.
// The original worker is preserved as sw.js.pwa-backup — restore it (and the
// registration in assets/js/app.js) when re-enabling the PWA for production.

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
      await self.registration.unregister();
      const clients = await self.clients.matchAll({ type: "window" });
      clients.forEach((client) => client.navigate(client.url));
    })()
  );
});

// Pass every request straight through to the network — no caching.
self.addEventListener("fetch", (event) => {
  event.respondWith(fetch(event.request));
});
