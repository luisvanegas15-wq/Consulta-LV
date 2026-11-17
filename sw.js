/* Consulta LV · service worker: siempre intenta la versión más nueva; sin internet usa la última guardada.
   Nunca guarda datos del servidor (Supabase) ni de otros sitios. */
const CACHE = 'consulta-lv-v8';
const BASE = ['./', './index.html', './supabase.js', './manifest.json', './icon-192.png', './icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(BASE)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== location.origin) return;
  e.respondWith(fetch(r).then(res => {
    if (res.ok && res.type === 'basic') { const cp = res.clone(); caches.open(CACHE).then(c => c.put(r.mode === 'navigate' ? './index.html' : r, cp)); }
    return res;
  }).catch(() => caches.match(r.mode === 'navigate' ? './index.html' : r).then(x => x || caches.match('./index.html'))));
});
