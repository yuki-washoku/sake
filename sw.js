/* 酒帖 — オフライン用 Service Worker */
const C = "sakecho-v1";
const CORE = ["./", "./index.html"];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(C).then(c => c.addAll(CORE)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== C).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("message", e => { if (e.data === "skip") self.skipWaiting(); });

self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET") return;
  let u;
  try { u = new URL(r.url); } catch (_) { return; }
  // データ通信はキャッシュしない（在庫は常に最新を取りに行く）
  if (u.pathname.includes("/rest/v1/") || u.pathname.includes("/auth/v1/") ||
      u.pathname.includes("/realtime/") || u.protocol === "ws:" || u.protocol === "wss:") return;

  e.respondWith((async () => {
    const c = await caches.open(C);
    const hit = await c.match(r, { ignoreSearch: u.origin === location.origin });
    const net = fetch(r).then(res => {
      if (res && res.status === 200 && (res.type === "basic" || res.type === "cors")) {
        c.put(r, res.clone()).catch(() => {});
      }
      return res;
    }).catch(() => null);

    if (hit) { net; return hit; }              // まず手元、裏で更新
    const res = await net;
    if (res) return res;
    if (r.mode === "navigate") {
      const f = (await c.match("./index.html")) || (await c.match("./"));
      if (f) return f;
    }
    return new Response("", { status: 504, statusText: "offline" });
  })());
});
