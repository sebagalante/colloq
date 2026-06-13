// Colloq Service Worker
// Cache strategies: static cache-first, forum network-first, API stale-while-revalidate

const CACHE_STATIC = "colloq-static-v1";
const CACHE_PAGES = "colloq-pages-v1";
const CACHE_API = "colloq-api-v1";

// Assets to pre-cache on install
const STATIC_ASSETS = [
  "/",
  "/manifest.json",
  "/icons/icon-192.png",
  "/icons/icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_STATIC).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => ![CACHE_STATIC, CACHE_PAGES, CACHE_API].includes(k))
          .map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== "GET") return;

  // Static assets: cache-first
  if (/\.(css|js|png|jpg|svg|ico|woff2?|json)$/.test(url.pathname)) {
    event.respondWith(cacheFirst(request, CACHE_STATIC));
    return;
  }

  // API responses: stale-while-revalidate
  if (url.pathname.startsWith("/api/")) {
    event.respondWith(staleWhileRevalidate(request, CACHE_API));
    return;
  }

  // Forum pages: network-first
  if (request.headers.get("Accept")?.includes("text/html")) {
    event.respondWith(networkFirst(request, CACHE_PAGES));
    return;
  }
});

// Push handler — goal alerts
self.addEventListener("push", (event) => {
  let data = { title: "Colloq", body: "Novedad" };
  try {
    data = event.data.json();
  } catch (_) {}

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      data: { url: data.url || "/" },
      vibrate: data.type === "Goal" ? [200, 100, 200] : [100],
      tag: "colloq-match",
      renotify: true
    })
  );
});

// Notification click → open thread
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: "window" }).then((clients) => {
      const url = event.notification.data.url || "/";
      for (const client of clients) {
        if (client.url.includes(url) && "focus" in client) {
          return client.focus();
        }
      }
      return clients.openWindow(url);
    })
  );
});

// Caching strategies
async function cacheFirst(request, cacheName) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) {
    const cache = await caches.open(cacheName);
    cache.put(request, response.clone());
  }
  return response;
}

async function networkFirst(request, cacheName) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(cacheName);
      cache.put(request, response.clone());
    }
    return response;
  } catch (_) {
    return caches.match(request);
  }
}

async function staleWhileRevalidate(request, cacheName) {
  const cached = caches.match(request);
  const fetched = fetch(request).then((response) => {
    const cache = await caches.open(cacheName);
    cache.put(request, response.clone());
    return response;
  });
  return (await cached) || (await fetched);
}