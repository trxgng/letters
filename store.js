/* Connects the Letters page to Supabase (or to a demo store in this browser when config.js is empty).
   Anyone with the secret code (you and your friend) can read, write, reply and add pictures.
   Gives the page the same small API it used on Claude: claude.use("db" | "user" | "assets"). */
(() => {
  const C = window.LETTERS_CONFIG || {};
  const Q = new URLSearchParams(location.search);
  const demo = !(C.supabaseUrl && C.supabaseKey);
  const ls = {get: k => { try { return localStorage.getItem(k) || ""; } catch (e) { return ""; } }, set: (k, v) => { try { if (v) localStorage.setItem(k, v); else localStorage.removeItem(k); } catch (e) {} }};
  let code = (Q.get("k") || ls.get("letters.k")).trim();
  if (Q.get("k")) { ls.set("letters.k", code); const u = new URL(location.href); u.searchParams.delete("k"); history.replaceState(null, "", u.pathname + u.search + u.hash); }
  const rid = () => [...crypto.getRandomValues(new Uint8Array(16))].map(b => b.toString(16).padStart(2, "0")).join("");

  let B;
  if (demo) {
    const LS = "letters.demo";
    let st; try { st = JSON.parse(localStorage.getItem(LS)) || {}; } catch (e) { st = {}; }
    st.docs = st.docs || {}; st.replies = st.replies || []; st.files = st.files || {};
    const save = () => { try { localStorage.setItem(LS, JSON.stringify(st)); } catch (e) {} };
    B = {
      async open(k) { return k === "demo" ? "demofolder" : ""; },
      async all() { return Object.entries(st.docs).map(([path, data]) => ({path, data})); },
      async set(path, data) { st.docs[path] = data; save(); },
      async del(path) { delete st.docs[path]; save(); },
      async upload(blob, id) { id = id || rid(); st.files[id] = await new Promise(r => { const f = new FileReader(); f.onload = () => r(f.result); f.readAsDataURL(blob); }); save(); return id; },
      url: id => st.files[id] || "",
      async addReply(letter, author, body) { st.replies.push({id: Date.now(), letter, author, body, created_at: new Date().toISOString()}); save(); },
      async replies(letter) { return st.replies.filter(r => !letter || r.letter === letter); },
      async delReply(id) { st.replies = st.replies.filter(r => r.id !== id); save(); }
    };
  } else {
    const sb = supabase.createClient(C.supabaseUrl, C.supabaseKey, {auth: {persistSession: false, autoRefreshToken: false}});
    const base = C.supabaseUrl.replace(/\/$/, "") + "/storage/v1/object/public/letters/";
    let folder = "";
    const rpc = async (fn, args) => { const r = await sb.rpc(fn, {k: code, ...args}); if (r.error) throw r.error; return r.data; };
    const must = v => { if (v !== true) throw new Error("not allowed"); };
    B = {
      async open(k) { const r = await sb.rpc("open_site", {k}); if (r.error) throw r.error; folder = r.data || ""; return folder; },
      all: () => rpc("docs_all"),
      async set(p, d) { must(await rpc("doc_set", {p, d})); },
      async del(p) { must(await rpc("doc_del", {p})); },
      async upload(blob, id) { id = id || rid();
        const r = await sb.storage.from("letters").upload(folder + "/" + id, blob, {contentType: blob.type || "application/octet-stream", cacheControl: "31536000", upsert: false});
        if (r.error && !/exist|duplicate/i.test(r.error.message || "")) throw r.error; return id; },
      url: id => folder ? base + folder + "/" + encodeURIComponent(id) : "",
      async addReply(l, a, b) { must(await rpc("reply_add", {l, a, b})); },
      replies: l => rpc("replies_get", {l: l || null}),
      async delReply(i) { must(await rpc("reply_del", {i})); }
    };
  }

  /* ---------- the claude.use() shim the page already speaks ---------- */
  let member = false, cache = new Map(), started = null;
  const subs = new Set();
  const emit = () => { for (const s of subs) try { s(); } catch (e) {} };
  const refresh = async () => { if (!member) return; const rows = await B.all(); const m = new Map(); for (const r of rows || []) if (r && r.path) m.set(r.path, r.data); cache = m; emit(); };
  const start = () => started || (started = (async () => {
    if (code) { try { member = !!(await B.open(code)); } catch (e) { member = false; } if (!member) ls.set("letters.k", ""); }
    await refresh().catch(() => {});
    setInterval(() => { if (!document.hidden) refresh().catch(() => {}); }, 15000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh().catch(() => {}); });
  })());
  const guard = () => { if (!member) throw new Error("no code"); };
  const db = {
    collection: name => ({ onSnapshot(cb, err) {
      const run = () => cb({docs: [...cache.entries()].filter(([p]) => p.startsWith(name + "/") && p.indexOf("/", name.length + 1) < 0).map(([p, v]) => ({id: p.slice(name.length + 1), data: () => v}))});
      subs.add(run); start().then(run, err); return () => subs.delete(run); } }),
    doc: path => ({
      async set(data) { guard(); await B.set(path, data); cache.set(path, data); emit(); },
      async delete() { guard(); await B.del(path); cache.delete(path); emit(); },
      onSnapshot(cb, err) { const run = () => cb({exists: cache.has(path), data: () => cache.get(path)}); subs.add(run); start().then(run, err); return () => subs.delete(run); }
    })
  };
  const assets = { async upload(blob) { guard(); return {id: await B.upload(blob)}; } };
  const user = { async canEdit() { await start(); return member; } };
  window.claude = { use: async k => { await start(); return k === "db" ? db : k === "assets" ? (member ? assets : null) : k === "user" ? user : null; } };

  window.STORE = {
    demo, start, refresh,
    member: () => member,
    url: id => B.url(id),
    async tryCode(k) { k = (k || "").trim(); let f = ""; try { f = await B.open(k); } catch (e) {} if (!f) return false; ls.set("letters.k", k); return true; },
    link: () => location.origin + location.pathname + "?k=" + encodeURIComponent(code),
    forget: () => ls.set("letters.k", ""),
    myName: () => ls.get("letters.name"),
    setName: n => ls.set("letters.name", (n || "").trim().slice(0, 60)),
    addReply: (l, b) => B.addReply(l, ls.get("letters.name"), b),
    replies: l => B.replies(l),
    delReply: id => B.delReply(id),
    putAsset: (id, blob) => (guard(), B.upload(blob, id))
  };
})();
