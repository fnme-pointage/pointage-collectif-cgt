const CACHE='pointage-collectif-v3';
const ASSETS=['./','./index.html','./manifest.json','./config.js'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));
self.addEventListener('fetch',e=>{
  if(e.request.url.includes('supabase.co') || e.request.url.includes('jsdelivr.net')) return;
  e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));
});