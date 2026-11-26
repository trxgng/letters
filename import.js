/* One-time move of the letters from the old Claude page. Runs only when the page is opened with ?import=PASS.
   import.bin is encrypted; PASS is only in the link Claude gave the owner. */
(() => {
  const pass = new URLSearchParams(location.search).get("import");
  if (!pass || !window.STORE) return;
  const bar = document.createElement("div");
  bar.style.cssText = "position:fixed;left:50%;top:16px;transform:translateX(-50%);z-index:60;background:#fff;color:#3c4630;border-radius:16px;padding:14px 18px;box-shadow:0 8px 30px rgba(0,0,0,.2);font:700 15px Nunito,sans-serif;max-width:90vw;display:grid;gap:10px;text-align:center";
  const msg = document.createElement("span"), btn = document.createElement("button");
  btn.textContent = "Bring over my old letters";
  btn.style.cssText = "min-height:44px;border:0;border-radius:999px;background:#3c4630;color:#fff;font:800 15px Nunito,sans-serif;padding:10px 18px;cursor:pointer";
  bar.append(msg, btn);
  const say = t => { msg.textContent = t; };
  const done = () => { const u = new URL(location.href); u.searchParams.delete("import"); history.replaceState(null, "", u.pathname + u.search + u.hash); };
  const b64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
  STORE.start().then(() => {
    if (!STORE.member() || !STORE.myName()) { const t = setInterval(() => { if (STORE.member() && STORE.myName()) { clearInterval(t); show(); } }, 1000); return; }
    show();
  });
  function show() { say("Your letters from the old page are ready to move here."); document.body.append(bar); }
  btn.addEventListener("click", async () => {
    btn.disabled = true; say("Opening…");
    try {
      const raw = new Uint8Array(await (await fetch("import.bin", {cache: "no-store"})).arrayBuffer());
      const key = await crypto.subtle.importKey("raw", await crypto.subtle.digest("SHA-256", new TextEncoder().encode(pass)), "AES-GCM", false, ["decrypt"]);
      const data = JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({name: "AES-GCM", iv: raw.slice(0, 12)}, key, raw.slice(12))));
      const ids = Object.keys(data.files); let n = 0;
      for (const id of ids) { n++; say("Moving photos… " + n + " of " + ids.length); const f = data.files[id];
        await STORE.putAsset(id, new Blob([b64(f.b64)], {type: f.type})); }
      const db = await claude.use("db"), me = STORE.myName();
      let i = 0; const L = Object.entries(data.letters);
      for (const [id, v] of L) { i++; say("Moving letters… " + i + " of " + L.length); await db.doc("letters/" + id).set({...v, by: me}); }
      if (data.settings) { const have = new Set(ids), keep = a => (a || []).filter(x => have.has(x));
        await db.doc("settings/main").set({font: "", fontName: "", motif: "", ...data.settings, library: keep(data.settings.library), stickers: keep(data.settings.stickers)}); }
      done(); await STORE.refresh(); say("Done! " + L.length + " letters and " + ids.length + " pictures moved."); btn.remove();
      setTimeout(() => bar.remove(), 6000);
    } catch (e) { say("Something went wrong: " + ((e && e.message) || "please try again")); btn.disabled = false; btn.textContent = "Try again"; }
  });
})();
