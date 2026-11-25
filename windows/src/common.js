// Shared helpers for the main window and the tray panel.
window.addEventListener("error", (e) => window.__TAURI__ && window.__TAURI__.core.invoke("log_js", { message: `${e.message} @ ${e.filename}:${e.lineno}` }));
window.addEventListener("unhandledrejection", (e) => window.__TAURI__ && window.__TAURI__.core.invoke("log_js", { message: "promise: " + String(e.reason) }));
// Line icons (Lucide-style paths), drawn with currentColor.
const ICONS = {
  home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4l2 2h9A1.5 1.5 0 0 1 21 8.5v10a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z"/>',
  download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 20h16"/>',
  card: '<path d="M7 3h8l4 4v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M10 7v3M13 7v3M16 8v2"/>',
  drive: '<rect x="3" y="12" width="18" height="7" rx="1.5"/><path d="M5 12 7.5 5h9L19 12"/><path d="M7 15.5h.01"/>',
  cloud: '<path d="M7 18a4 4 0 0 1-.6-7.96A6 6 0 0 1 18 9.5a4.5 4.5 0 0 1-.5 8.5z"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  eject: '<path d="M12 5 4 14h16z"/><path d="M4 19h16"/>',
  video: '<rect x="3" y="6" width="13" height="12" rx="1.5"/><path d="m16 10 5-3v10l-5-3"/>',
  photo: '<rect x="3" y="5" width="18" height="14" rx="1.5"/><circle cx="9" cy="10" r="1.6"/><path d="m21 16-5-5-9 8"/>',
  audio: '<path d="M9 18V6l11-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>',
  file: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/>',
  share: '<path d="M12 15V3"/><path d="m7 8 5-5 5 5"/><path d="M5 13v7h14v-7"/>',
};
function icon(name, size = 16) {
  return `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ICONS.file}</svg>`;
}

const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args);
const listen = (ev, fn) => T.event.listen(ev, fn);
const fileSrc = (p) => T.core.convertFileSrc(p);

const $ = (sel, el = document) => el.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function bytes(n) {
  if (n == null) return "–";
  const u = ["bytes", "KB", "MB", "GB", "TB"];
  let v = n, i = 0;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return i === 0 ? `${n} bytes` : `${v.toFixed(v < 10 ? 2 : 1)} ${u[i]}`;
}

function duration(s) {
  s = Math.round(s);
  if (s < 60) return `${s} s`;
  if (s < 3600) return `${Math.floor(s / 60)} min ${s % 60} s`;
  return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
}

function dateText(t, withTime) {
  if (!t) return "–";
  const d = new Date(t * 1000);
  const p = (x) => String(x).padStart(2, "0");
  const s = `${p(d.getDate())}.${p(d.getMonth() + 1)}.${String(d.getFullYear()).slice(2)}`;
  return withTime ? `${s} ${p(d.getHours())}.${p(d.getMinutes())}` : s;
}

function capBar(total, free, need = 0) {
  if (!total) return "";
  const used = Math.max(0, total - free) / total * 100;
  const n = need > 0 ? Math.max(0.6, Math.min(need, free) / total * 100) : 0;
  return `<div class="cap"><i class="used" style="width:${used}%"></i><i class="need ${need > free ? "over" : ""}" style="width:${n}%"></i></div>`;
}

const kindIcon = { video: icon("video", 14), photo: icon("photo", 14), audio: icon("audio", 14), sidecar: icon("file", 14), other: icon("file", 14) };
const kindLabel = { video: "Video", photo: "Photo", audio: "Audio", sidecar: "Sidecar", other: "Other" };
const toneSymbol = { green: '<span class="dot" style="background:var(--green)"></span>', orange: '<span class="dot" style="background:var(--orange)"></span>', red: '<span class="dot" style="background:var(--red)"></span>', accent: '<span class="dot" style="background:var(--accent)"></span>', gray: '<span class="dot" style="background:var(--faint)"></span>' };

function toast(msg, ms = 3800) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

async function call(cmd, args, okMsg) {
  try {
    const r = await invoke(cmd, args);
    if (okMsg) toast(okMsg);
    return r;
  } catch (e) {
    toast(String(e), 5200);
    throw e;
  }
}

// Share menu (used by tables, results, the panel).
function openMenu(x, y, items) {
  closeMenu();
  const m = document.createElement("div");
  m.className = "menu";
  m.id = "menu";
  for (const it of items) {
    if (it === "-") { m.appendChild(document.createElement("hr")); continue; }
    const b = document.createElement("button");
    b.textContent = it.label;
    b.disabled = !!it.disabled;
    b.onclick = () => { closeMenu(); it.run(); };
    m.appendChild(b);
  }
  document.body.appendChild(m);
  const r = m.getBoundingClientRect();
  m.style.left = Math.min(x, innerWidth - r.width - 8) + "px";
  m.style.top = Math.min(y, innerHeight - r.height - 8) + "px";
  setTimeout(() => addEventListener("mousedown", outside), 0);
}
function outside(e) { if (!e.target.closest("#menu")) closeMenu(); }
function closeMenu() { document.getElementById("menu")?.remove(); removeEventListener("mousedown", outside); }

function shareItems(paths, subject, isWindows) {
  const none = !paths.length;
  return [
    { label: "Copy files", disabled: none, run: () => call("share_copy_files", { paths }, "Files copied. Paste them anywhere.") },
    { label: "WhatsApp", disabled: none, run: async () => toast(await call("share_whatsapp", { paths }), 6000) },
    { label: "Email", disabled: none, run: async () => toast(await call("share_email", { paths, subject }), 6000) },
    { label: "Google Drive link", disabled: none, run: () => call("share_drive_link", { paths }) },
    "-",
    { label: isWindows ? "Show in Explorer" : "Show in Finder", disabled: none, run: () => call("reveal", { path: paths[0] }) },
  ];
}

function linkModal(task) {
  const host = document.getElementById("overlay");
  if (!task || (!task.running && !task.links.length && !task.error)) { host.innerHTML = ""; return; }
  const text = task.links.join("\n");
  host.innerHTML = `<div class="modal-bg"><div class="modal">
    <h3>Google Drive link</h3>
    ${task.running ? `<div class="row"><span class="spin"></span><span class="muted">${esc(task.label)}</span></div><div class="small muted">Files already on Drive aren't uploaded again.</div>` : ""}
    ${task.error ? `<div class="red">${esc(task.error)}</div>` : ""}
    ${task.links.length ? `<div class="green">Link copied to the clipboard.</div>
      <textarea readonly class="mono" style="width:100%;min-height:90px;user-select:text;background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px">${esc(text)}</textarea>
      <div class="small muted">Anyone with this link can open the files.</div>
      <div class="row"><button type="button" class="btn" id="lk-wa">Send via WhatsApp</button><button type="button" class="btn" id="lk-mail">Send via Email</button><button type="button" class="btn" id="lk-copy">Copy</button></div>` : ""}
    <div class="row" style="justify-content:flex-end"><button type="button" class="btn" id="lk-close" ${task.running ? "disabled" : ""}>Close</button></div>
  </div></div>`;
  if (task.links.length) invoke("copy_text", { text });
  $("#lk-close", host).onclick = () => invoke("clear_share");
  $("#lk-wa", host)?.addEventListener("click", () => invoke("open_url", { url: "whatsapp://send?text=" + encodeURIComponent(text) }).catch(() => toast("WhatsApp isn't installed. The link is on the clipboard.")));
  $("#lk-mail", host)?.addEventListener("click", () => invoke("open_url", { url: "mailto:?subject=Footage&body=" + encodeURIComponent(text) }));
  $("#lk-copy", host)?.addEventListener("click", () => invoke("copy_text", { text }).then(() => toast("Copied")));
}

// Status block for a plugged-in card (home screen and tray panel).
function statusBlock(j, compact) {
  const st = j.cardStatus;
  const orb = j.preview ? `<img src="${fileSrc(j.preview)}" alt="">` : icon("card", 20);
  let action = "";
  if (j.quickRunning || ["scanning", "planning", "copying", "uploading"].includes(j.stage)) action = `<span class="muted small">Working…</span>`;
  else if (st && st.safe) action = `<button type="button" class="btn go" data-act="eject" data-src="${esc(j.source)}">Eject</button>`;
  else if (st) action = `<button type="button" class="btn primary" data-act="open" data-src="${esc(j.source)}">${st.missing > 0 ? "Copy now" : "Open"}</button>`;
  const verify = st && !j.quickVerified && j.stage !== "done" && j.hasMatches && !j.quickRunning
    ? `<button type="button" class="link small" data-act="verify" data-src="${esc(j.source)}">Check file contents (hash) to be sure</button>` : "";
  return `<div class="status tone-${st ? st.tone : "gray"}">
    <div class="top"><div class="orb">${orb}</div><div style="min-width:0"><div style="font-weight:600">${esc(j.name)}</div>
      <div class="muted small">${esc(st ? st.headline : j.statusText)}</div></div></div>
    ${st ? `<div class="row"><span class="line ${st.tone}">${toneSymbol[st.tone] || toneSymbol.gray} ${esc(st.title)}</span><span class="grow" style="flex:1"></span>${action}</div>
      <div class="note">${esc(st.detail)}</div>${verify}` : ""}
  </div>`;
}

function bindStatusActions(root, onOpen) {
  root.querySelectorAll("[data-act]").forEach((b) => {
    b.onclick = async () => {
      const src = b.dataset.src;
      if (b.dataset.act === "eject") await call("eject", { source: src }, "Card ejected.");
      if (b.dataset.act === "open") onOpen(src);
      if (b.dataset.act === "verify") await call("run_quick_check", { source: src, thorough: true });
    };
  });
}
