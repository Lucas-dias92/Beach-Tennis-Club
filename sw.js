// Beach Tennis Club - avisos push + instalacao como app (PWA)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
// necessario para o navegador oferecer "Instalar app" (nao guarda nada em cache)
self.addEventListener('fetch', () => {});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data.json(); } catch (_) { d = { title: 'Beach Tennis Club', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Beach Tennis Club', {
    body: d.body || '',
    icon: 'logo-icon-192.png',
    badge: 'logo-icon-192.png',
    data: { url: d.url || './' },
    tag: 'btc-' + Date.now(),
    requireInteraction: true,
    vibrate: [200, 100, 200]
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ('focus' in c) return c.focus(); }
    return clients.openWindow(e.notification.data.url || './');
  }));
});