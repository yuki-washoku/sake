/* 酒帖 — オフライン用 Service Worker */
const C = "sakecho-v3";
const CORE = [
  "./", "./index.html",
  "./icon-192.png", "./icon-512.png",
  "./apple-touch-icon.png", "./favicon-32.png"
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(C)
      .then(c => Promise.allSettled(CORE.map(u => c.add(u))))
      .then(() => self.skipWaiting())
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

const isData = u =>
  u.pathname.includes("/rest/v1/") ||
  u.pathname.includes("/auth/v1/") ||
  u.pathname.includes("/realtime/") ||
  u.pathname.includes("/storage/v1/");

self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET") return;
  let u;
  try { u = new URL(r.url); } catch (_) { return; }
  if (isData(u)) return;                       // 在庫データは常に本体へ

  const isPage = r.mode === "navigate" ||
                 (r.headers.get("accept") || "").includes("text/html");

  e.respondWith((async () => {
    const c = await caches.open(C);

    // ページ本体は「まず通信、だめなら手元」。更新がすぐ反映される
    if (isPage) {
      try {
        const res = await Promise.race([
          fetch(r),
          new Promise((_, rej) => setTimeout(() => rej(new Error("slow")), 4000))
        ]);
        if (res && res.status === 200) {
          c.put("./index.html", res.clone()).catch(() => {});
          return res;
        }
      } catch (_) {}
      const f = (await c.match("./index.html")) || (await c.match("./"));
      if (f) return f;
      return new Response("オフラインです", {
        status: 503,
        headers: { "Content-Type": "text/plain; charset=utf-8" }
      });
    }

    // それ以外は「まず手元、裏で更新」
    const hit = await c.match(r, { ignoreSearch: u.origin === location.origin });
    const net = fetch(r).then(res => {
      if (res && res.status === 200 && (res.type === "basic" || res.type === "cors")) {
        c.put(r, res.clone()).catch(() => {});
      }
      return res;
    }).catch(() => null);

    if (hit) { net; return hit; }
    const res = await net;
    if (res) return res;
    return new Response("", { status: 504 });
  })());
});
