/* Connects the Letters page to Supabase (or to a demo store in this browser when config.js is empty).
   Each person has their own personal code (in their link). Letters are only sent to people their writer picks:
   the server only ever returns letters you wrote or were picked for.
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
    /* Practice mode: everything lives in this browser. Codes are "demo" (owner) or what the friends list makes. */
    const LS = "letters.demo2";
    let st; try { st = JSON.parse(localStorage.getItem(LS)) || {}; } catch (e) { st = {}; }
    st.docs = st.docs || {}; st.replies = st.replies || []; st.files = st.files || {};
    st.people = st.people || [{id: "p-owner", name: "Me", code: "demo", owner: true}];
    const save = () => { try { localStorage.setItem(LS, JSON.stringify(st)); } catch (e) {} };
    const who = () => st.people.find(p => p.code === code);
    const can = (me, path) => { const d = st.docs[path]; return !!d && (d.by === me.id || (d.toIds || []).includes(me.id)); };
    B = {
      async open(k) { const p = st.people.find(x => x.code === k); return p ? {id: p.id, name: p.name, owner: !!p.owner, folder: "f"} : null; },
      async all() { const me = who(); if (!me) return [];
        const out = Object.entries(st.docs).filter(([p]) => p.startsWith("letters/") && can(me, p)).map(([path, data]) => ({path, data}));
        if (st.docs["settings/" + me.id]) out.push({path: "settings/main", data: st.docs["settings/" + me.id]}); return out; },
      async set(path, data) { const me = who(); if (path === "settings/main") { st.docs["settings/" + me.id] = data; save(); return; }
        const cur = st.docs[path]; if (cur && cur.by !== me.id) throw new Error("not yours");
        st.docs[path] = {...data, by: me.id, toIds: (data.toIds || []).filter(i => i !== me.id && st.people.some(p => p.id === i))}; save(); },
      async del(path) { const me = who(); if (st.docs[path] && st.docs[path].by === me.id) delete st.docs[path]; save(); },
      async upload(blob, id) { id = id || rid(); st.files[id] = await new Promise(r => { const f = new FileReader(); f.onload = () => r(f.result); f.readAsDataURL(blob); }); save(); return id; },
      url: id => st.files[id] || "",
      async addReply(l, b) { const me = who(); if (!can(me, "letters/" + l)) throw new Error("no"); st.replies.push({id: Date.now(), letter: l, author: me.name, aid: me.id, body: b, created_at: new Date().toISOString()}); save(); },
      async replies(l) { const me = who(); return st.replies.filter(r => (!l || r.letter === l) && can(me, "letters/" + r.letter)).map(r => ({...r, author: (st.people.find(p => p.id === r.aid) || r).name || r.author, mine: r.aid === me.id})); },
      async delReply(i) { const me = who(); st.replies = st.replies.filter(r => !(r.id === i && r.aid === me.id)); save(); },
      async people() { return st.people.map(p => ({id: p.id, name: p.name, is_owner: !!p.owner})); },
      async personAdd(n) { const p = {id: "p-" + rid().slice(0, 8), name: n, code: rid()}; st.people.push(p); save(); return p.code; },
      async personLink(i) { return (st.people.find(p => p.id === i) || {}).code || ""; },
      async personRename(i, n) { const p = st.people.find(x => x.id === i); if (p) p.name = n; save(); },
      async personRemove(i) { st.people = st.people.filter(p => p.id !== i || p.owner); for (const [k, d] of Object.entries(st.docs)) { if (d.by === i) delete st.docs[k]; else if (d.toIds) d.toIds = d.toIds.filter(x => x !== i); } save(); },
      async personNewcode(i) { const p = st.people.find(x => x.id === i); if (!p) return ""; p.code = rid(); save(); return p.code; }
    };
  } else {
    const sb = supabase.createClient(C.supabaseUrl, C.supabaseKey, {auth: {persistSession: false, autoRefreshToken: false}});
    const base = C.supabaseUrl.replace(/\/$/, "") + "/storage/v1/object/public/letters/";
    let folder = "";
    const rpc = async (fn, args) => { const r = await sb.rpc(fn, {k: code, ...args}); if (r.error) throw r.error; return r.data; };
    const must = v => { if (v !== true) throw new Error("not allowed"); return true; };
    B = {
      async open(k) { const r = await sb.rpc("open_site", {k}); if (r.error) throw r.error; if (r.data) folder = r.data.folder || ""; return r.data; },
      all: () => rpc("docs_all"),
      async set(p, d) { must(await rpc("doc_set", {p, d})); },
      async del(p) { must(await rpc("doc_del", {p})); },
      async upload(blob, id) { id = id || rid();
        const r = await sb.storage.from("letters").upload(folder + "/" + id, blob, {contentType: blob.type || "application/octet-stream", cacheControl: "31536000", upsert: false});
        if (r.error && !/exist|duplicate/i.test(r.error.message || "")) throw r.error; return id; },
      url: id => folder ? base + folder + "/" + encodeURIComponent(id) : "",
      async addReply(l, b) { must(await rpc("reply_add", {l, b})); },
      replies: l => rpc("replies_get", {l: l || null}),
      async delReply(i) { must(await rpc("reply_del", {i})); },
      people: () => rpc("people_list"),
      personAdd: n => rpc("person_add", {n}),
      personLink: i => rpc("person_link", {i}),
      async personRename(i, n) { must(await rpc("person_rename", {i, n})); },
      async personRemove(i) { must(await rpc("person_remove", {i})); },
      personNewcode: i => rpc("person_newcode", {i})
    };
  }

  /* reload by itself when a newer version of the site is uploaded (bump version.txt and the ?v= in index.html together) */
  const VER = "9";
  setInterval(async () => { if (document.hidden || demo) return; try { const v = (await (await fetch("version.txt?" + Date.now(), {cache: "no-store"})).text()).trim();
    if (v && v !== VER && !document.querySelector("#ed.show,#letter.show,.crop,.confirm:not([hidden])") && !(document.getElementById("replytext") || {}).value) location.reload(); } catch (e) {} }, 120000);

  /* ---------- the claude.use() shim the page already speaks ---------- */
  let me = null, cache = new Map(), started = null, people = [];
  const subs = new Set();
  const emit = () => { for (const s of subs) try { s(); } catch (e) {} };
  const refresh = async () => { if (!me) return; const [rows, ps] = await Promise.all([B.all(), B.people().catch(() => people)]);
    people = ps || []; const m = new Map(); for (const r of rows || []) if (r && r.path) m.set(r.path, r.data); cache = m; emit(); };
  const start = () => started || (started = (async () => {
    if (code) { try { me = await B.open(code); } catch (e) { me = null; } if (!me) ls.set("letters.k", ""); }
    await refresh().catch(() => {});
    setInterval(() => { if (!document.hidden) refresh().catch(() => {}); }, 15000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh().catch(() => {}); });
  })());
  const guard = () => { if (!me) throw new Error("no code"); };
  const db = {
    collection: name => ({ onSnapshot(cb, err) {
      const run = () => cb({docs: [...cache.entries()].filter(([p]) => p.startsWith(name + "/") && p.indexOf("/", name.length + 1) < 0).map(([p, v]) => ({id: p.slice(name.length + 1), data: () => v}))});
      subs.add(run); start().then(run, err); return () => subs.delete(run); } }),
    doc: path => ({
      async set(data) { guard(); await B.set(path, data); cache.set(path, path.startsWith("letters/") ? {...data, by: me.id} : data); emit(); },
      async delete() { guard(); await B.del(path); cache.delete(path); emit(); },
      onSnapshot(cb, err) { const run = () => cb({exists: cache.has(path), data: () => cache.get(path)}); subs.add(run); start().then(run, err); return () => subs.delete(run); }
    })
  };
  const assets = { async upload(blob) { guard(); return {id: await B.upload(blob)}; } };
  const user = { async canEdit() { await start(); return !!me; } };
  window.claude = { use: async k => { await start(); return k === "db" ? db : k === "assets" ? (me ? assets : null) : k === "user" ? user : null; } };

  const linkFor = c => location.origin + location.pathname + "?k=" + encodeURIComponent(c);
  window.STORE = {
    demo, start, refresh,
    member: () => !!me,
    me: () => me || {},
    isOwner: () => !!(me && me.owner),
    myId: () => (me && me.id) || "",
    myName: () => (me && me.name) || "",
    people: () => people,
    nameOf: id => (people.find(p => p.id === id) || {}).name || "",
    url: id => B.url(id),
    async tryCode(k) { k = (k || "").trim(); let r = null; try { r = await B.open(k); } catch (e) {} if (!r) return false; ls.set("letters.k", k); return true; },
    pageLink: () => location.origin + location.pathname,
    async setName(n) { n = (n || "").trim().slice(0, 60); await B.personRename(me.id, n); me.name = n; await refresh().catch(() => {}); },
    addReply: (l, b) => B.addReply(l, b),
    replies: l => B.replies(l),
    delReply: id => B.delReply(id),
    putAsset: (id, blob) => (guard(), B.upload(blob, id)),
    async addPerson(n) { const c = await B.personAdd(n); await refresh().catch(() => {}); return c ? linkFor(c) : ""; },
    async personLink(id) { const c = await B.personLink(id); return c ? linkFor(c) : ""; },
    async renamePerson(id, n) { await B.personRename(id, n); await refresh().catch(() => {}); },
    async removePerson(id) { await B.personRemove(id); await refresh().catch(() => {}); },
    async newLink(id) { const c = await B.personNewcode(id); if (id === me.id && c) { code = c; ls.set("letters.k", c); } return c ? linkFor(c) : ""; }
  };
})();
