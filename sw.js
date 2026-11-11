// FORGED service worker: phone alerts only (no offline caching).
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "FORGED", {
    body: d.body || "",
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    tag: d.tag || "forged",
    data: { url: d.url || "/" },
  }));
});
// Tapping an alert opens the app on the right tab (and the right chat).
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/", self.location.origin).href;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const c = all.find((w) => w.url.startsWith(self.location.origin));
    if (c) {
      try {
        c.postMessage({ fgOpen: new URL(url).hash || "#home" });
        await c.focus();
        return;
      } catch (_) { /* fall through and open fresh */ }
    }
    await self.clients.openWindow(url);
  })());
});
