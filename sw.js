// Beach Tennis Club - recebe os avisos push e abre o site ao tocar na notificação
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data.json(); } catch (_) { d = { title: 'Beach Tennis Club', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Beach Tennis Club', {
    body: d.body || '',
    icon: 'logo-icon-512.png',
    badge: 'logo-icon-512.png',
    data: { url: d.url || './' },
    tag: 'lesson-request',
    renotify: true,
    vibrate: [120, 60, 120]
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ('focus' in c) return c.focus(); }
    return clients.openWindow(e.notification.data.url || './');
  }));
});
