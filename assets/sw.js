// Beach Tennis Club - avisos push + instalacao como app (PWA) · v4
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
// necessario para o navegador oferecer "Instalar app" (nao guarda nada em cache)
self.addEventListener('fetch', () => {});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data.json(); } catch (_) { d = { title: 'Beach Tennis Club', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Beach Tennis Club', {
    body: d.body || '',
    icon: '/assets/icones/logo-icon-192.png?v=4',
    badge: '/assets/icones/badge-96.png?v=4',
    lang: 'pt-BR',
    timestamp: Date.now(),
    data: { url: d.url || '/' },
    tag: 'tcc-' + Date.now(),
    renotify: false,
    vibrate: [200, 100, 200]
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ('focus' in c) return c.focus(); }
    return clients.openWindow(new URL(e.notification.data.url || '/', self.location.origin + '/').href);
  }));
});