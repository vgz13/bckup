// BCKUP main window.
let S = null; // state from get_state
let J = null; // detail of the open card/folder
let route = { view: "home", source: null };
let settingsTab = "dest";
let projectsCache = null;
let projectsOnlyMissing = false;
let dl = { source: "downloads", days: 14, items: [], sel: new Set(), project: "", sub: "", move: false, msg: "" };
let fileFilter = "all";
let fileSel = new Set();
let filesOpen = false;
let showAllThumbs = false;
let remotes = [];
let driveFolders = [];
const isWin = () => S && S.platform === "windows";
const fileManager = () => (isWin() ? "Explorer" : "Finder");

// MARK: data flow

let pending = false;
async function refresh() {
  if (pending) return;
  pending = true;
  setTimeout(async () => {
    pending = false;
    S = await invoke("get_state");
    if (route.view === "job" && route.source) J = await invoke("get_job", { source: route.source });
    renderSidebar();
    renderView();
    testAuto();
    linkModal(S.shareTask);
  }, 16);
}

function go(view, source = null) {
  route = { view, source };
  fileSel = new Set();
  fileFilter = "all";
  filesOpen = false;
  showAllThumbs = false;
  J = null;
  if (view === "projects") loadProjects(false);
  if (view === "downloads") loadDownloads();
  refresh();
}

// MARK: sidebar

function navItem(key, iconName, title, sub, on, trailing = "") {
  return `<div class="nav ${on ? "on" : ""}" data-nav="${esc(key)}"><span class="ic">${icon(iconName)}</span>
    <span class="t"><div>${esc(title)}</div>${sub ? `<div class="s">${esc(sub)}</div>` : ""}</span>${trailing}</div>`;
}

function jobFor(src) { return S.jobs.find((j) => j.source === src); }

function renderSidebar() {
  const sb = $("#sidebar");
  const r = route;
  let h = `<h4>Library</h4>`;
  h += navItem("v:home", "home", "Home", "", r.view === "home");
  h += navItem("v:projects", "folder", "Projects", "", r.view === "projects");
  h += navItem("v:downloads", "download", "Sort downloads", "", r.view === "downloads");
  h += `<h4>Cards</h4>`;
  if (!S.cards.length) h += `<div class="nav"><span class="ic faint">${icon("card")}</span><span class="t muted small">Plug in a camera card…</span></div>`;
  for (const c of S.cards) {
    const j = jobFor(c.path);
    const st = j && j.cardStatus;
    const trail = st ? `<span class="badge">${toneSymbol[st.tone] || ""}</span>` : "";
    h += navItem("s:" + c.path, "card", c.name, j ? j.statusText : bytes(c.total), r.source === c.path, trail);
  }
  if (S.otherDrives.length) {
    h += `<h4>Other drives</h4>`;
    for (const d of S.otherDrives) h += navItem("s:" + d.path, "drive", d.name, bytes(d.total), r.source === d.path);
  }
  if (S.sources.length) {
    h += `<h4>Folders</h4>`;
    for (const s of S.sources) h += navItem("s:" + s.key, s.kind === "drop" ? "file" : "folder", s.name, (jobFor(s.key) || {}).statusText || s.subtitle, r.source === s.key);
  }
  h += `<h4>Destinations</h4>`;
  if (!S.destinations.length) h += `<div class="nav" data-nav="a:primary"><span class="ic">${icon("folder")}</span><span class="t accent">Choose main folder…</span></div>`;
  for (const d of S.destinations) {
    h += `<div class="nav" title="${esc(d.path)}"><span class="ic ${d.connected ? "green" : "faint"}">${icon("drive")}</span><span class="t">
      <div>${esc(d.name)} <span class="s">${d.role}</span></div>
      ${d.connected ? capBar(d.total, d.free) + `<div class="s">${bytes(d.free)} free</div>` : `<div class="s">Not connected</div>`}</span></div>`;
  }
  if (S.settings.cloudEnabled) {
    h += `<div class="nav"><span class="ic accent">${icon("cloud")}</span><span class="t"><div>Google Drive</div><div class="s ${S.cloudIssue ? "orange" : ""}">${esc(S.cloudIssue || S.cloudDisplay)}</div></span></div>`;
  }
  sb.innerHTML = h;
  sb.querySelectorAll("[data-nav]").forEach((el) => {
    el.onclick = () => {
      const k = el.dataset.nav;
      if (k.startsWith("v:")) go(k.slice(2));
      else if (k.startsWith("s:")) go("job", k.slice(2));
      else if (k === "a:primary") call("choose_primary");
    };
    el.oncontextmenu = (e) => {
      const k = el.dataset.nav;
      if (!k.startsWith("s:")) return;
      e.preventDefault();
      const key = k.slice(2);
      const src = S.sources.find((s) => s.key === key);
      const drive = S.otherDrives.find((d) => d.path === key);
      if (src) openMenu(e.clientX, e.clientY, [{ label: "Remove from list", run: () => { call("remove_source", { key }); if (route.source === key) go("home"); } }]);
      if (drive) openMenu(e.clientX, e.clientY, [{ label: "Hide from list", run: () => call("hide_volume", { id: drive.id }) }]);
    };
  });
}

// MARK: views

function setBar(html) {
  const bar = $("#bar");
  if (!html) { bar.classList.add("hidden"); bar.innerHTML = ""; return; }
  bar.classList.remove("hidden");
  bar.innerHTML = html;
}

function renderView() {
  if (!S.settings.primaryRoot && route.view !== "settings") return renderSetup();
  if (route.view === "settings") return renderSettings();
  if (route.view === "projects") return renderProjects();
  if (route.view === "downloads") return renderDownloads();
  if (route.view === "job") return renderJob();
  return renderHome();
}

function renderSetup() {
  setBar("");
  $("#view").innerHTML = `<div style="max-width:560px;padding-top:30px;display:flex;flex-direction:column;gap:16px">
    <div style="font-size:34px;font-weight:700">BCKUP</div>
    <div class="muted" style="font-size:16px">Copy camera cards to several drives at once. Every file is checked by hash, files already there are skipped, and you know when a card is safe to format.</div>
    <div class="sep"></div>
    <div>Start by choosing the folder where all your footage lives, for example your jobs folder on your working drive. Backup drives and Google Drive can be added later in Settings.</div>
    <div><button type="button" class="btn primary big" id="setup-pick">Choose main folder…</button></div></div>`;
  $("#setup-pick").onclick = () => call("choose_primary");
}

function renderHome() {
  setBar("");
  let h = `<h1>Home</h1>`;
  if (!S.cards.length) {
    h += `<div class="panel"><div style="font-size:16px;font-weight:500">Plug in a camera card</div>
      <div class="muted">BCKUP checks right away whether its contents are already on your drives and tells you from the ${isWin() ? "tray icon" : "menu bar"}. You can also drag a card, folder or files onto this window.</div>
      <div><button type="button" class="btn" id="home-src">Choose a source folder…</button></div></div>`;
  } else {
    h += `<div><h2>Plugged-in cards</h2><div class="panel">${S.cards.map((c, i) => (i ? `<div class="sep"></div>` : "") + statusBlock(jobFor(c.path) || { source: c.path, name: c.name, statusText: "Reading the card…" })).join("")}</div></div>`;
  }
  if (S.plugged.length) {
    h += `<div><h2>Drives</h2><div class="panel">${S.plugged.map(([n, r]) => `<div class="row"><span>${icon("drive")}</span><span style="flex:1">${esc(n)}</span><span class="muted">${esc(r)}</span></div>`).join("")}</div></div>`;
  }
  $("#view").innerHTML = h;
  $("#home-src")?.addEventListener("click", chooseSource);
  bindStatusActions($("#view"), (src) => go("job", src));
}

// MARK: card / folder job

function stageBusy(st) { return ["scanning", "planning", "copying", "uploading"].includes(st); }

function renderJob() {
  if (!J) { $("#view").innerHTML = `<div class="empty"><span class="spin"></span></div>`; setBar(""); return; }
  const j = J.job;
  const v = $("#view");
  const focused = document.activeElement && document.activeElement.closest && document.activeElement.closest("#form");
  const scan = j.scan;

  let h = `<div class="head"><div class="t"><h1>${esc(j.name)}</h1><div class="meta">${esc(metaLine(scan, j))}</div></div>
    <button type="button" class="btn icon" id="jb-rescan" title="Re-read the card" ${stageBusy(j.stage) ? "disabled" : ""}>${icon("refresh")}</button>
    <button type="button" class="btn" id="jb-side" title="Open the card and its destination folder side by side">Open side by side</button>
    ${j.isVolume ? `<button type="button" class="btn" id="jb-eject" ${stageBusy(j.stage) ? "disabled" : ""}>${icon("eject")} Eject</button>` : ""}</div>`;

  if (!scan) {
    h += j.stage === "error" ? `<div class="panel red">${esc(j.error)}</div>` : `<div class="empty"><span class="spin"></span><div style="margin-top:10px">Reading the card…</div></div>`;
    v.innerHTML = h;
    bindJobHeader(j);
    setBar("");
    return;
  }

  if (j.stage === "copying" || j.stage === "uploading") h += progressPanel(j) + summaryPanel();
  else if (j.stage === "done" && j.result) h += resultPanel(j) + summaryPanel();
  else {
    if (j.stage === "planned" && j.plan) h += planPanel(j);
    if (j.stage === "error") h += `<div class="panel red">${esc(j.error)}</div>`;
    h += `<div id="form-slot"></div>` + previewPanel(scan);
  }

  const oldForm = $("#form");
  v.innerHTML = h;
  const slot = $("#form-slot");
  if (slot) {
    if (focused && oldForm) slot.replaceWith(oldForm);
    else slot.outerHTML = formPanel(j);
    bindForm(j);
  }
  bindJobHeader(j);
  bindJobBody(j);
  renderJobBar(j);
}

function metaLine(scan, j) {
  if (!scan) return "";
  const parts = [scan.model ? `${scan.model} (${scan.camera})` : scan.camera, `${scan.files.length} files`, bytes(scan.totalBytes)];
  const kinds = ["video", "photo", "audio"].filter((k) => scan.counts[k]).map((k) => `${scan.counts[k]} ${k}`);
  if (kinds.length) parts.push(kinds.join(", "));
  if (scan.firstDate) {
    const a = dateText(scan.firstDate), b = dateText(scan.lastDate);
    parts.push(a === b ? a : `${a}–${b}`);
  }
  return parts.join("  ·  ");
}

function formPanel(j) {
  const f = j.form || {};
  const s = S.settings;
  const d = f.date ? new Date(f.date * 1000) : new Date();
  const iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const disabled = stageBusy(j.stage) ? "disabled" : "";
  const crumbs = J.breadcrumb.map(([t, isNew], i) => (i ? `<span class="chev">›</span>` : "") + (isNew ? `<b>${esc(t)}</b>` : `<span>${esc(t)}</span>`)).join("");
  const anyNew = J.breadcrumb.some((c) => c[1]);
  const dests = S.destinations.map((dd) => {
    const main = dd.role === "Main";
    const on = main || !(f.backupsOff || []).includes(dd.path);
    const need = j.plan ? (j.plan.summaries.find((x) => x.root === dd.path) || {}).bytes || 0 : 0;
    return `<div class="dest ${dd.connected ? "" : "off"}">
      <input type="checkbox" class="dest-toggle" data-path="${esc(dd.path)}" ${on && dd.connected ? "checked" : ""} ${main || !dd.connected ? "disabled" : ""} ${disabled}>
      <div style="min-width:0"><div><span class="name">${esc(dd.name)}</span><span class="role">${main ? "main" : "backup"}</span>${dd.connected ? "" : ` <span class="orange small">Not connected</span>`}</div>
        <div class="path">${esc(dd.path)}</div>${dd.connected ? `<div style="max-width:340px">${capBar(dd.total, dd.free, need)}</div>` : ""}</div>
      <div class="free">${dd.connected ? `${bytes(dd.free)}<div class="small muted">free</div>` : ""}</div></div>`;
  }).join("");
  const cloud = s.cloudEnabled ? `<div class="dest"><input type="checkbox" id="f-cloud" ${f.useCloud ? "checked" : ""} ${disabled}>
      <div><div class="name">Google Drive</div><div class="path ${S.cloudIssue ? "orange" : ""}">${esc(S.cloudIssue || S.cloudDisplay)}</div></div><div class="free small muted">MD5 checked</div></div>` : "";
  const copies = J.copies;
  return `<div id="form" style="display:flex;flex-direction:column;gap:18px">
    <div><h2>Project</h2><div class="panel">
      <div class="grid2">
        ${s.useClientFolder ? `<label>Client</label><input type="text" id="f-client" list="dl-clients" value="${esc(f.client)}" placeholder="Client name" ${disabled}><span></span><span></span>` : ""}
        <label>Project</label><input type="text" id="f-project" list="dl-projects" value="${esc(f.project)}" placeholder="Project / shoot name" ${disabled} style="grid-column: span 3">
        <label>Date</label><input type="date" id="f-date" value="${iso}" ${J.projectExists || s.datePosition === "none" ? "disabled" : disabled}>
        ${f.asAssets ? `<span></span><span></span>` : `<label>Roll</label><input type="text" id="f-roll" value="${esc(f.roll)}" placeholder="Roll / card name" ${disabled}>`}
      </div>
      <datalist id="dl-clients">${J.clients.map((c) => `<option value="${esc(c)}">`).join("")}</datalist>
      <datalist id="dl-projects">${J.projects.map((c) => `<option value="${esc(c)}">`).join("")}</datalist>
      <div class="crumb" title="${esc(J.previewPath)}"><div class="p">${crumbs}</div>
        <div class="small muted">${J.projectExists ? "This project already exists; new files go into the same folder." : anyNew ? "Highlighted folders will be created." : ""}</div></div>
      <div class="row" style="justify-content:flex-end"><button type="button" class="link small" id="f-rename">Rename folders…</button></div>
    </div></div>
    <div><h2>Save to</h2><div class="panel">${dests}${cloud}
      <div class="row small"><button type="button" class="link" id="f-primary">Change main folder…</button><button type="button" class="link" id="f-backup">Add backup drive…</button>
        <span style="flex:1"></span>${copies >= 2 ? `<span class="green">${copies} copies</span>` : `<span class="orange">1 copy, no backup yet</span>`}</div></div></div>
    <div><h2>Options</h2><div class="panel">
      <div class="row"><label class="check"><input type="checkbox" id="f-skip" ${f.skipExisting ? "checked" : ""} ${disabled}> Skip files that are already there</label><span style="flex:1"></span>
        <div class="seg"><button type="button" data-mode="thorough" class="${f.checkMode === "thorough" ? "on" : ""}" ${!f.skipExisting || disabled ? "disabled" : ""}>Thorough (hash)</button><button type="button" data-mode="fast" class="${f.checkMode === "fast" ? "on" : ""}" ${!f.skipExisting || disabled ? "disabled" : ""}>Quick</button></div></div>
      <div class="small muted">${f.skipExisting ? (f.checkMode === "thorough" ? "Safest. Files on the card are read and compared by content with what's already at the destination, so moved or renamed files are still recognised." : "Faster for big cards, but skipped files aren't compared by content, so a card can't be marked \"Safe to format\".") : "Every file on the card is copied. Files whose names already exist aren't overwritten; they get a _2 suffix."}</div>
      <div class="sep"></div>
      <label class="check"><input type="checkbox" id="f-assets" ${f.asAssets ? "checked" : ""} ${disabled}> Save as assets in the ${esc(S.settings.materialFolder || "MATERIAL")} folder</label>
      <div class="small muted">${f.asAssets ? `For logos, music, briefs and client footage. Files are sorted into ${S.settings.splitMaterial ? "Video, Photo, Audio, Graphics, Documents and more" : "one folder"}${S.settings.splitMaterial && S.settings.groupByDevice ? ", with a folder per camera or phone" : ""}.` : "For camera cards. Turn on for loose files that aren't from a card."}</div>
      ${f.asAssets ? "" : `<label class="check"><input type="checkbox" id="f-split" ${f.separateByType ? "checked" : ""} ${disabled}> Split into Video / Photo / Audio folders</label>`}
    </div></div></div>`;
}

let formTimer = null;
function readForm(j) {
  const f = { ...(j.form || {}) };
  const val = (id) => ($("#" + id) ? $("#" + id).value : undefined);
  if ($("#f-client")) f.client = val("f-client");
  f.project = val("f-project") ?? f.project;
  f.roll = val("f-roll") ?? f.roll;
  const d = val("f-date");
  if (d) { const [y, m, dd] = d.split("-").map(Number); f.date = new Date(y, m - 1, dd, 12).getTime() / 1000; }
  f.skipExisting = $("#f-skip") ? $("#f-skip").checked : f.skipExisting;
  f.separateByType = $("#f-split") ? $("#f-split").checked : f.separateByType;
  f.asAssets = $("#f-assets") ? $("#f-assets").checked : !!f.asAssets;
  if ($("#f-cloud")) f.useCloud = $("#f-cloud").checked;
  f.backupsOff = [...document.querySelectorAll(".dest-toggle")].filter((c) => !c.checked && !c.disabled).map((c) => c.dataset.path);
  return f;
}
function pushForm(j, immediate) {
  clearTimeout(formTimer);
  const send = async () => {
    const form = readForm(j);
    j.form = form;
    await invoke("update_form", { source: j.source, form });
    J = await invoke("get_job", { source: j.source });
    renderJobBar(J.job);
    const c = $(".crumb");
    if (c) c.outerHTML = (new DOMParser().parseFromString(formPanel(J.job), "text/html")).querySelector(".crumb").outerHTML;
    if (immediate) refresh();
  };
  if (immediate) send(); else formTimer = setTimeout(send, 250);
}
function bindForm(j) {
  ["f-client", "f-project", "f-roll"].forEach((id) => $("#" + id)?.addEventListener("input", () => pushForm(j, false)));
  ["f-client", "f-project", "f-roll"].forEach((id) => $("#" + id)?.addEventListener("change", () => { document.activeElement.blur(); pushForm(j, true); }));
  ["f-date", "f-skip", "f-split", "f-cloud", "f-assets"].forEach((id) => $("#" + id)?.addEventListener("change", () => pushForm(j, true)));
  $("#f-rename")?.addEventListener("click", renameModal);
  document.querySelectorAll(".dest-toggle").forEach((c) => c.addEventListener("change", () => pushForm(j, true)));
  document.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => { j.form.checkMode = b.dataset.mode; invoke("update_form", { source: j.source, form: { ...readForm(j), checkMode: b.dataset.mode } }).then(refresh); }));
  $("#f-primary")?.addEventListener("click", () => call("choose_primary"));
  $("#f-backup")?.addEventListener("click", () => call("add_backup"));
}

function bindJobHeader(j) {
  $("#jb-rescan")?.addEventListener("click", () => call("rescan", { source: j.source }));
  $("#jb-side")?.addEventListener("click", () => call("open_side_by_side", { source: j.source }));
  $("#jb-eject")?.addEventListener("click", async () => { await call("eject", { source: j.source }, "Card ejected."); go("home"); });
}

function previewPanel(scan) {
  const raw = ["arw", "cr2", "cr3", "nef", "raf", "rw2", "orf", "dng"];
  const media = scan.files.filter((f) => {
    const ext = f.rel.split(".").pop().toLowerCase();
    if (f.rel.toUpperCase().includes("THMBNL/")) return false;
    if (f.kind === "video") return ["mp4", "mov", "m4v", "webm"].includes(ext);
    return f.kind === "photo" && !raw.includes(ext) && ["jpg", "jpeg", "png", "webp", "gif", "heic"].includes(ext);
  });
  if (!media.length) return "";
  const list = media.slice(0, showAllThumbs ? 400 : 18);
  return `<div><h2>On this card</h2><div class="panel"><div class="thumbs">${list.map((f) => `<div class="thumb" data-open="${esc(f.path)}" title="Double-click to open">
      <div class="img">${f.kind === "video" ? `<video src="${fileSrc(f.path)}#t=0.5" preload="metadata" muted></video>` : `<img loading="lazy" src="${fileSrc(f.path)}" alt="">`}</div>
      <div class="n mono">${esc(f.rel.split("/").pop())}</div><div class="small muted">${bytes(f.size)}</div></div>`).join("")}</div>
    ${media.length > 18 ? `<button type="button" class="link small" id="thumbs-more">${showAllThumbs ? "Show fewer" : `Show all (${Math.min(media.length, 400)})`}</button>` : ""}</div></div>`;
}

function planPanel(j) {
  const p = j.plan;
  const rows = p.summaries.map((s) => {
    const over = s.free != null && s.bytes > s.free;
    return `<div class="row"><span class="${over ? "red" : "muted"}">${icon("drive")}</span><span style="min-width:120px;font-weight:500">${esc(s.name)}</span>
      <div style="width:220px">${capBar(s.total, s.free, s.bytes)}</div><span style="flex:1"></span>
      <span class="${over ? "red" : "muted"}">${over ? `Short of ${bytes(s.bytes - s.free)}` : `${s.copy} new · ${s.skip} already there`}</span></div>`;
  }).join("");
  const cloud = p.spec.cloud ? `<div class="row"><span class="accent">${icon("cloud")}</span><span style="font-weight:500">Google Drive</span><span style="flex:1"></span><span class="muted">uploaded, then MD5-checked</span></div>` : "";
  const clash = p.renamedCount ? `<div class="warnbox"><div style="font-weight:500">${p.renamedCount} files with the same name but different contents are already in this roll.</div>
    <div class="small muted" style="margin:4px 0 8px">Usually a card that was formatted and reused. To keep the card's structure intact, use a new roll name. If you go on, those files get a _2 suffix.</div>
    <button type="button" class="btn small" id="new-roll">Use roll "${esc(nextRoll(j.form.roll))}" and check again</button></div>` : "";
  const nothing = p.filesToCopy === 0 && p.items.length ? `<div class="green">Every file on the card is already at the destination. Nothing needs copying.</div>` : "";
  const files = p.items.map((it) => ({ path: it.file.path, rel: it.file.rel, kind: it.file.kind, size: it.file.size, status: it.actions && Object.values(it.actions).some((a) => a.type === "copy") ? (Object.values(it.actions).some((a) => a.renamed) ? "New (gets _2)" : "To copy") : "Already there", cat: Object.values(it.actions).some((a) => a.type === "copy") ? "todo" : "existing" }));
  return `<div><h2>Check result</h2><div class="panel">
    <div class="stats"><div class="stat"><div class="v accent">${p.filesToCopy}</div><div class="l">files to copy</div></div>
      <div class="stat"><div class="v">${bytes(p.bytesToCopy)}</div><div class="l">to read from the card</div></div>
      <div class="stat"><div class="v green">${p.items.length - p.filesToCopy}</div><div class="l">already on every destination</div></div>
      ${p.renamedCount ? `<div class="stat"><div class="v orange">${p.renamedCount}</div><div class="l">name clashes</div></div>` : ""}</div>
    ${rows}${cloud}${clash}${nothing}${fileTable(files)}</div></div>`;
}

function nextRoll(r) {
  const m = (r || "").match(/(\d+)$/);
  if (m) return r.slice(0, -m[1].length) + String(Number(m[1]) + 1).padStart(m[1].length, "0");
  return (r || "Roll") + " 2";
}

function progressPanel(j) {
  const p = j.progress;
  const pct = p.total ? Math.floor((p.done / p.total) * 100) : null;
  const remain = j.speed > 1 && p.total > p.done ? duration((p.total - p.done) / j.speed) : "…";
  const phase = p.phase === "Copying" ? "Copying from the card to every destination at once" : p.phase === "Verifying" ? "Reading the copies back and comparing hashes" : p.phase;
  return `<div class="panel"><div class="row top"><div style="flex:1"><div style="font-weight:600">${j.stage === "uploading" ? "Upload to Google Drive" : "Copying & verifying"}</div>
      <div class="muted">${esc(phase)}</div></div><div class="big-pct">${pct == null ? "…" : pct + "%"}</div></div>
    ${pct == null ? `<progress></progress>` : `<progress max="100" value="${pct}"></progress>`}
    ${p.isBytes ? `<div class="stats"><div class="stat"><div class="v">${bytes(p.done)}</div><div class="l">of ${bytes(p.total)} (copy + check)</div></div>
      <div class="stat"><div class="v">${j.speed > 1 ? bytes(j.speed) + "/s" : "…"}</div><div class="l">speed</div></div>
      <div class="stat"><div class="v">${remain}</div><div class="l">time left</div></div>
      <div class="stat"><div class="v">${p.fileCount ? `${p.fileIndex}/${p.fileCount}` : "…"}</div><div class="l">files</div></div></div>
      ${p.fileName ? `<div class="small muted mono">${esc(p.fileName)}</div>` : ""}` : `<div class="small muted">${esc(p.detail)}</div>`}
    <div class="small faint">The card is only read. If you cancel, unfinished files are not saved under their real names.</div></div>`;
}

function resultPanel(j) {
  const r = j.result;
  const v = r.verdict;
  const color = { safe: "var(--green)", failed: "var(--red)", oneCopy: "var(--orange)", unverified: "var(--orange)" }[v.kind] || "var(--faint)";
  const primary = r.spec.destinations[0];
  const dests = r.spec.destinations.map((d, i) => {
    const ok = r.items.filter((it) => { const o = it.outcomes[d]; return o && (o.type === "copied" || (o.type === "existing" && o.verified)); }).length;
    const all = ok === r.items.length;
    return `<div class="row"><span class="${all ? "green" : "orange"}">${all ? "✓" : "!"}</span><span style="font-weight:500">${esc(S.destinations.find((x) => x.path === d)?.name || d)}</span>
      <span class="small muted">${i === 0 ? "Main" : "Backup"}</span><span style="flex:1"></span><span class="muted">${ok} of ${r.items.length} files verified</span></div>`;
  }).join("");
  const cloud = r.cloudMessage ? `<div class="row"><span class="${r.cloudOk ? "green" : "red"}">${r.cloudOk ? "✓" : "!"}</span><span style="font-weight:500">Google Drive</span><span style="flex:1"></span><span class="muted">${esc(r.cloudMessage)}</span></div>` : "";
  const files = r.items.map((it) => {
    const fail = Object.values(it.outcomes).find((o) => o.type === "failed");
    const copied = Object.values(it.outcomes).some((o) => o.type === "copied");
    const loc = it.outcomes[primary] && (it.outcomes[primary].rel) ? joinPath(primary, it.outcomes[primary].rel) : it.file.path;
    return { path: loc, rel: it.file.rel, kind: it.file.kind, size: it.file.size, status: fail ? fail.message : copied ? "Copied & verified" : "Already there", cat: fail ? "failed" : copied ? "todo" : "existing" };
  });
  if (r.failures) filesOpen = true;
  const proj = joinPath(primary, r.spec.projectRel || [r.spec.clientFolder, r.spec.projectFolder].filter(Boolean).join("/"));
  return `<div class="verdict"><div class="stripe" style="background:${color}"></div><div><div class="title" style="color:${color}">${esc(v.title)}</div><div>${esc(v.detail)}</div></div></div>
    <div><h2>Copies</h2><div class="panel">${dests}${cloud}
      <div class="stats"><div class="stat"><div class="v accent">${r.copiedCount}</div><div class="l">copied · ${bytes(r.copiedBytes)}</div></div>
        <div class="stat"><div class="v green">${r.existingCount}</div><div class="l">already there</div></div>
        <div class="stat"><div class="v ${r.failures ? "red" : ""}">${r.failures}</div><div class="l">failed</div></div>
        <div class="stat"><div class="v">${duration(Math.max(0, r.finishedAt - r.startedAt))}</div><div class="l">time</div></div></div>
      <div class="row"><button type="button" class="link" id="r-open" data-path="${esc(proj)}">Show in ${fileManager()}</button>
        ${r.reports.length ? `<button type="button" class="link" id="r-report" data-path="${esc(r.reports.find((x) => x.endsWith(".txt")) || r.reports[0])}">Open report</button>` : ""}</div>
      <div class="sep"></div>
      <div class="row"><span style="font-weight:500">Share</span>
        <button type="button" class="btn small share-btn" data-paths='${esc(JSON.stringify([proj]))}'>${icon("share", 14)} Project folder</button>
        <button type="button" class="btn small share-btn" data-paths='${esc(JSON.stringify(files.map((f) => f.path)))}'>${icon("share", 14)} All files</button></div>
      <div class="small muted">WhatsApp, Email, a Google Drive link, or copy the files to paste anywhere. Big videos are best sent as a Google Drive link.</div>
      ${fileTable(files)}</div></div>`;
}

function joinPath(a, b) {
  const sep = isWin() ? "\\" : "/";
  return a.replace(/[\\/]+$/, "") + sep + String(b).split("/").join(sep);
}

function summaryPanel() {
  const parts = J.destinations.map((d) => S.destinations.find((x) => x.path === d)?.name || d);
  const f = J.job.form || {};
  if (f.useCloud && S.settings.cloudEnabled) parts.push("Google Drive");
  const mode = f.skipExisting ? (f.checkMode === "thorough" ? "skip what's there, hash check" : "skip what's there, quick check") : "copy everything";
  const crumbs = J.breadcrumb.map(([t], i) => (i ? `<span class="chev">›</span>` : "") + `<span>${esc(t)}</span>`).join("");
  return `<div><h2>Details</h2><div class="panel"><div class="crumb"><div class="p">${crumbs}</div></div><div class="muted">To ${esc(parts.join(", "))}  ·  ${mode}</div></div></div>`;
}

function fileTable(files) {
  const cats = [["all", "All"], ["todo", "To copy"], ["existing", "Already there"], ["failed", "Failed"]].filter(([k]) => k === "all" || files.some((f) => f.cat === k));
  const shown = (fileFilter === "all" ? files : files.filter((f) => f.cat === fileFilter)).slice(0, 5000);
  const color = { todo: "accent", existing: "green", failed: "red" };
  const head = `<div class="row"><button type="button" class="link" id="files-toggle" style="color:var(--text);font-weight:500">${filesOpen ? "▾" : "▸"} Files</button>
    ${filesOpen && fileSel.size ? `<span class="small muted">${fileSel.size} selected</span><button type="button" class="btn small" id="files-share">${icon("share", 14)} Share</button>` : ""}
    <span style="flex:1"></span>${filesOpen ? `<div class="seg">${cats.map(([k, l]) => `<button type="button" data-filter="${k}" class="${fileFilter === k ? "on" : ""}">${l} ${k === "all" ? files.length : files.filter((f) => f.cat === k).length}</button>`).join("")}</div>` : ""}</div>`;
  if (!filesOpen) return head;
  window.__files = files;
  return head + `<div class="tablebox"><div class="scroller" style="max-height:290px"><table><thead><tr><th style="width:30px"></th><th>File</th><th class="r" style="width:90px">Size</th><th style="width:190px">Status</th></tr></thead><tbody>
    ${shown.map((f) => `<tr data-path="${esc(f.path)}" class="${fileSel.has(f.path) ? "sel" : ""}" draggable="true"><td class="muted">${kindIcon[f.kind] || ""}</td><td title="${esc(f.rel)}">${esc(f.rel)}</td><td class="r num muted">${bytes(f.size)}</td><td class="${color[f.cat] || ""}" title="${esc(f.status)}">${esc(f.status)}</td></tr>`).join("")}
    </tbody></table></div></div><div class="small faint">Double-click to show a file. Right-click to share. Select several with Ctrl/Shift.</div>`;
}

function bindFileTable() {
  $("#files-toggle")?.addEventListener("click", () => { filesOpen = !filesOpen; renderView(); });
  document.querySelectorAll("[data-filter]").forEach((b) => b.addEventListener("click", () => { fileFilter = b.dataset.filter; renderView(); }));
  $("#files-share")?.addEventListener("click", (e) => openMenu(e.clientX, e.clientY, shareItems([...fileSel], "Footage", isWin())));
  let last = null;
  document.querySelectorAll("tbody tr[data-path]").forEach((tr) => {
    tr.addEventListener("click", (e) => {
      const p = tr.dataset.path;
      if (e.shiftKey && last) {
        const rows = [...document.querySelectorAll("tbody tr[data-path]")].map((r) => r.dataset.path);
        const [a, b] = [rows.indexOf(last), rows.indexOf(p)].sort((x, y) => x - y);
        rows.slice(a, b + 1).forEach((x) => fileSel.add(x));
      } else if (e.ctrlKey || e.metaKey) {
        fileSel.has(p) ? fileSel.delete(p) : fileSel.add(p);
      } else {
        fileSel = new Set([p]);
      }
      last = p;
      renderView();
    });
    tr.addEventListener("dblclick", () => call("reveal", { path: tr.dataset.path }));
    tr.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      const p = tr.dataset.path;
      if (!fileSel.has(p)) fileSel = new Set([p]);
      openMenu(e.clientX, e.clientY, shareItems([...fileSel], "Footage", isWin()));
    });
  });
}

function bindJobBody(j) {
  $("#thumbs-more")?.addEventListener("click", () => { showAllThumbs = !showAllThumbs; renderView(); });
  document.querySelectorAll("[data-open]").forEach((el) => el.addEventListener("dblclick", () => call("open_path", { path: el.dataset.open })));
  $("#new-roll")?.addEventListener("click", async () => {
    const form = { ...j.form, roll: nextRoll(j.form.roll) };
    await invoke("update_form", { source: j.source, form });
    await call("check_job", { source: j.source });
  });
  $("#r-open")?.addEventListener("click", (e) => call("open_path", { path: e.target.dataset.path }));
  $("#r-report")?.addEventListener("click", (e) => call("open_path", { path: e.target.dataset.path }));
  document.querySelectorAll(".share-btn").forEach((b) => b.addEventListener("click", (e) => openMenu(e.clientX, e.clientY, shareItems(JSON.parse(b.dataset.paths), "Footage", isWin()))));
  bindFileTable();
}

function renderJobBar(j) {
  let left = "", right = "";
  const p = j.progress;
  if (["ready", "idle", "scanning", "error"].includes(j.stage)) {
    left = J.validation ? `<span class="orange">${esc(J.validation)}</span>` : `<span class="muted">${j.form && j.form.skipExisting ? "Ready. BCKUP checks what's already there first." : "Ready. Every file will be copied."}</span>`;
    right = `<button type="button" class="btn primary big" id="b-check" ${J.validation || j.stage !== "ready" && j.stage !== "error" ? "disabled" : ""}>${j.isVolume ? "Check card" : "Check files"}</button>`;
  } else if (j.stage === "planning") {
    left = `<span class="spin"></span><span class="muted">${esc(p.phase)}</span>${p.total ? `<span class="muted num">${Math.floor(p.done / p.total * 100)}%</span>` : ""}`;
    right = `<button type="button" class="btn" id="b-cancel">Cancel</button>`;
  } else if (j.stage === "planned" && j.plan) {
    left = `<b>${j.plan.filesToCopy ? `${j.plan.filesToCopy} files to copy` : "Nothing to copy"}</b><span class="muted">· ${bytes(j.plan.bytesToCopy)} · ${j.plan.items.length - j.plan.filesToCopy} already complete</span>`;
    right = `<button type="button" class="btn" id="b-check">Check again</button><button type="button" class="btn primary big" id="b-start" ${j.plan.spaceProblem ? "disabled" : ""}>${j.plan.filesToCopy ? "Start copy" : "Finish"}</button>`;
  } else if (j.stage === "copying" || j.stage === "uploading") {
    const pct = p.total ? Math.floor(p.done / p.total * 100) : 0;
    left = `<progress max="100" value="${pct}" style="width:200px"></progress><b class="num">${pct}%</b>${j.speed > 1 ? `<span class="muted num">${bytes(j.speed)}/s</span>` : ""}`;
    right = `<button type="button" class="btn" id="b-cancel">Cancel</button>`;
  } else if (j.stage === "done" && j.result) {
    const v = j.result.verdict;
    left = `<b class="${v.kind === "safe" ? "green" : v.kind === "failed" ? "red" : "orange"}">${esc(v.title)}</b>`;
    right = `<button type="button" class="btn" id="b-reset">Check again</button>` + (j.isVolume && v.good ? `<button type="button" class="btn go big" id="b-eject">Eject card</button>` : `<button type="button" class="btn primary big" id="b-show">Show in ${fileManager()}</button>`);
  }
  setBar(`<div class="grow row">${left}</div>${right}`);
  $("#b-check")?.addEventListener("click", () => call("check_job", { source: j.source }));
  $("#b-start")?.addEventListener("click", () => call("start_job", { source: j.source }));
  $("#b-cancel")?.addEventListener("click", () => call("cancel_job", { source: j.source }));
  $("#b-reset")?.addEventListener("click", () => call("reset_job", { source: j.source }));
  $("#b-eject")?.addEventListener("click", async () => { await call("eject", { source: j.source }, "Card ejected."); go("home"); });
  $("#b-show")?.addEventListener("click", () => $("#r-open")?.click());
}

// MARK: projects

async function loadProjects(refreshDisk) {
  projectsCache = await invoke("get_projects", { refresh: refreshDisk });
  if (route.view === "projects") renderProjects();
}

function projectStatus(p) {
  const backups = S.settings.backupRoots;
  if (!backups.length) return { text: "No backup drive yet", cls: "muted", needs: false };
  if (!p.files) return { text: "Empty", cls: "muted", needs: false };
  const lacking = [];
  let unknown = 0;
  for (const b of backups) {
    const m = p.missing[b];
    if (m == null) unknown++;
    else if (m[0] > 0) lacking.push(`${S.destinations.find((d) => d.path === b)?.name || b}: missing ${m[0]}`);
  }
  if (lacking.length) return { text: lacking.join(", "), cls: "orange", needs: true };
  if (unknown === backups.length) return { text: "Backup drive not read yet", cls: "muted", needs: false };
  return { text: `Complete on ${backups.length - unknown} backup`, cls: "green", needs: false };
}

function renderProjects() {
  const t = S.backupTask;
  const list = (projectsCache || []).filter((p) => !projectsOnlyMissing || projectStatus(p).needs);
  const lacking = (projectsCache || []).filter((p) => projectStatus(p).needs);
  const rootName = (S.settings.primaryRoot || "").split(/[\\/]/).filter(Boolean).pop() || "";
  let h = `<div class="head"><div class="t"><h1>Projects</h1><div class="meta">${(projectsCache || []).length} projects in ${esc(rootName)}${S.settings.backupRoots.length ? `  ·  ${lacking.length ? `${lacking.length} not fully backed up` : "all fully backed up"}` : ""}</div></div>
    <label class="check"><input type="checkbox" id="p-only" ${projectsOnlyMissing ? "checked" : ""}> Only not backed up</label>
    <button type="button" class="btn icon" id="p-refresh" title="Re-read the main folder and backup drives">${icon("refresh")}</button></div>`;
  if (projectsCache == null) h += `<div class="empty"><span class="spin"></span></div>`;
  else if (!list.length) h += `<div class="empty"><h3>${projectsOnlyMissing ? "Every project is backed up" : "No projects yet"}</h3>${projectsOnlyMissing ? "Nothing is missing from the backup drives." : "Projects show up here after the first card is copied."}</div>`;
  else {
    h += `<div class="tablebox"><div class="scroller" style="max-height:calc(100dvh - 260px)"><table><thead><tr><th>Project</th><th class="r" style="width:90px">Size</th><th class="r" style="width:60px">Files</th><th style="width:120px">Last changed</th><th style="width:290px">Backup</th></tr></thead><tbody>
      ${list.map((p) => { const st = projectStatus(p); return `<tr data-rel="${esc(p.rel)}"><td style="font-weight:500" title="${esc(p.rel)}">${esc(p.rel)}</td><td class="r num muted">${bytes(p.bytes)}</td><td class="r num muted">${p.files}</td><td class="num muted">${dateText(p.modified, true)}</td>
        <td><span class="${t.running && t.label === p.rel ? "accent" : st.cls}">${t.running && t.label === p.rel ? "Backing up…" : esc(st.text)}</span> ${st.needs && !t.running ? `<button type="button" class="btn small" data-backup="${esc(p.rel)}">Back up</button>` : ""}</td></tr>`; }).join("")}
      </tbody></table></div></div>`;
  }
  $("#view").innerHTML = h;
  $("#p-only").onchange = (e) => { projectsOnlyMissing = e.target.checked; renderProjects(); };
  $("#p-refresh").onclick = () => { projectsCache = null; renderProjects(); loadProjects(true); };
  document.querySelectorAll("[data-backup]").forEach((b) => b.onclick = (e) => { e.stopPropagation(); call("backup_project", { rel: b.dataset.backup }); });
  document.querySelectorAll("tr[data-rel]").forEach((tr) => {
    const path = joinPath(S.settings.primaryRoot, tr.dataset.rel);
    tr.ondblclick = () => call("open_path", { path });
    tr.oncontextmenu = (e) => {
      e.preventDefault();
      openMenu(e.clientX, e.clientY, [{ label: `Show in ${fileManager()}`, run: () => call("open_path", { path }) },
        { label: "Back up now", disabled: t.running, run: () => call("backup_project", { rel: tr.dataset.rel }) }, "-", ...shareItems([path], tr.dataset.rel, isWin())]);
    };
  });
  let left;
  if (t.running) left = `<progress max="100" value="${t.progress.total ? Math.floor(t.progress.done / t.progress.total * 100) : 0}" style="width:180px"></progress><span class="muted">${esc(t.label)}: ${esc(t.progress.phase)}</span>`;
  else left = `<span class="muted small">${esc(t.message || "Backup status comes from what each backup drive held when it was last read, so it shows even when the drive isn't plugged in.")}</span>`;
  const first = lacking[0];
  setBar(`<div class="grow row">${left}</div>${!t.running && first ? `<button type="button" class="btn primary" id="p-backup-first">Back up ${lacking.length === 1 ? esc(first.name) : "the newest"}</button>` : ""}`);
  $("#p-backup-first")?.addEventListener("click", () => call("backup_project", { rel: first.rel }));
}

// MARK: sort downloads

async function loadDownloads() {
  dl.items = await invoke("get_downloads", { source: dl.source, days: dl.days });
  dl.options = await invoke("project_options");
  if (!dl.project && S && S.settings.lastProject && dl.options.includes(S.settings.lastProject)) dl.project = S.settings.lastProject;
  if (route.view === "downloads") renderDownloads();
}

function renderDownloads() {
  const items = dl.items || [];
  let h = `<div><h1>Sort downloads</h1><div class="meta muted" style="margin-top:3px">Put logos, music, briefs or client footage into a project's ${esc(S.settings.materialFolder || "MATERIAL")} folder, sorted by type and by camera or phone. Files are only copied; originals go to the ${isWin() ? "Recycle Bin" : "Bin"} only if you choose.</div></div>
    <div class="row"><div class="seg"><button type="button" data-src="downloads" class="${dl.source === "downloads" ? "on" : ""}">Downloads</button><button type="button" data-src="desktop" class="${dl.source === "desktop" ? "on" : ""}">Desktop</button></div>
      <select id="d-days" style="width:auto">${[7, 14, 30, 90].map((d) => `<option value="${d}" ${dl.days === d ? "selected" : ""}>${d} days</option>`).join("")}</select>
      <button type="button" class="btn icon" id="d-refresh">${icon("refresh")}</button></div>`;
  if (!items.length) h += `<div class="empty"><h3>No new files</h3>Nothing arrived in ${dl.source === "desktop" ? "Desktop" : "Downloads"} in the last ${dl.days} days.</div>`;
  else h += `<div class="tablebox"><div class="scroller" style="max-height:calc(100dvh - 300px)"><table><thead><tr><th>Name</th><th style="width:80px">Kind</th><th class="r" style="width:90px">Size</th><th style="width:110px">Added</th></tr></thead><tbody>
    ${items.map((i) => `<tr data-p="${esc(i.path)}" class="${dl.sel.has(i.path) ? "sel" : ""}"><td title="${esc(i.name)}"><span class="muted">${i.isFolder ? icon("folder", 14) : kindIcon[i.kind]}</span> ${esc(i.name)}</td><td class="muted">${i.isFolder ? "Folder" : kindLabel[i.kind]}</td><td class="r num muted">${i.isFolder ? "–" : bytes(i.size)}</td><td class="num muted">${dateText(i.date, true)}</td></tr>`).join("")}
    </tbody></table></div></div>`;
  $("#view").innerHTML = h;
  document.querySelectorAll("[data-src]").forEach((b) => b.onclick = () => { dl.source = b.dataset.src; dl.sel = new Set(); loadDownloads(); });
  $("#d-days").onchange = (e) => { dl.days = Number(e.target.value); loadDownloads(); };
  $("#d-refresh").onclick = loadDownloads;
  let last = null;
  document.querySelectorAll("tr[data-p]").forEach((tr) => {
    tr.onclick = (e) => {
      const p = tr.dataset.p;
      if (e.shiftKey && last) {
        const rows = items.map((i) => i.path);
        const [a, b] = [rows.indexOf(last), rows.indexOf(p)].sort((x, y) => x - y);
        rows.slice(a, b + 1).forEach((x) => dl.sel.add(x));
      } else if (e.ctrlKey || e.metaKey) dl.sel.has(p) ? dl.sel.delete(p) : dl.sel.add(p);
      else dl.sel = new Set([p]);
      last = p;
      renderDownloads();
    };
    tr.ondblclick = () => call("open_path", { path: tr.dataset.p });
    tr.oncontextmenu = (e) => {
      e.preventDefault();
      if (!dl.sel.has(tr.dataset.p)) dl.sel = new Set([tr.dataset.p]);
      openMenu(e.clientX, e.clientY, shareItems([...dl.sel], "Files", isWin()));
    };
  });
  const opts = dl.options || [];
  setBar(`<div class="grow" style="display:flex;flex-direction:column;gap:7px">
      <div class="row"><span class="muted">To</span><select id="d-project" style="max-width:300px"><option value="">Choose a project…</option>${opts.map((o) => `<option ${o === dl.project ? "selected" : ""}>${esc(o)}</option>`).join("")}</select>
        <span class="muted">/</span><input type="text" id="d-sub" value="${esc(dl.sub)}" placeholder="${esc(S.settings.materialFolder || "MATERIAL")}" title="Folder inside the project. Files are sorted into a folder per type inside it." style="width:120px"><span style="flex:1"></span>
        <button type="button" class="btn primary" id="d-copy" ${!dl.sel.size || !dl.project || dl.busy ? "disabled" : ""}>${dl.busy ? "Copying…" : dl.sel.size ? `Copy ${dl.sel.size}` : "Copy"}</button></div>
      <div class="row"><label class="check"><input type="checkbox" id="d-move" ${dl.move ? "checked" : ""}> Move originals to the ${isWin() ? "Recycle Bin" : "Bin"} after copying</label><span class="small muted">${esc(dl.msg)}</span></div></div>`);
  $("#d-project").onchange = (e) => { dl.project = e.target.value; renderDownloads(); };
  $("#d-sub").oninput = (e) => { dl.sub = e.target.value; };
  $("#d-move").onchange = (e) => { dl.move = e.target.checked; };
  $("#d-copy").onclick = async () => {
    dl.busy = true; renderDownloads();
    try { dl.msg = await call("copy_downloads", { items: [...dl.sel], project: dl.project, subfolder: dl.sub, moveOriginals: dl.move }); } catch (e) { dl.msg = String(e); }
    dl.busy = false; dl.sel = new Set();
    loadDownloads();
  };
}

// MARK: settings

async function renderSettings() {
  const s = S.settings;
  const tabs = [["dest", "Destinations"], ["folder", "Folder layout"], ["check", "Checking"], ["cloud", "Google Drive"]];
  let body = "";
  if (settingsTab === "dest") {
    body = `<div class="form">
      <label>Main folder</label><div class="row"><span style="flex:1;min-width:0" class="mono small">${esc(s.primaryRoot || "Not chosen")}</span><button type="button" class="btn" id="s-primary">Choose…</button></div>
      <label>Backups</label><div style="display:flex;flex-direction:column;gap:6px">${s.backupRoots.length ? s.backupRoots.map((b) => `<div class="row"><span style="flex:1;min-width:0" class="mono small">${esc(b)}</span><button type="button" class="btn small" data-rm="${esc(b)}">Remove</button></div>`).join("") : `<span class="muted">No backup drive yet</span>`}
        <div><button type="button" class="btn" id="s-backup">Add backup drive…</button></div></div>
      <span></span><div class="small muted">Cards are copied to the main folder and every connected backup at once, with the same folder layout.</div>
      <label>When a card goes in</label><label class="check"><input type="checkbox" id="s-auto" ${s.autoOpenOnCard ? "checked" : ""}> Show the ${isWin() ? "tray" : "menu bar"} panel</label>
      ${s.hiddenVolumes.length ? `<span></span><div><button type="button" class="link" id="s-unhide">Show hidden drives again (${s.hiddenVolumes.length})</button></div>` : ""}</div>`;
  } else if (settingsTab === "folder") {
    const formats = [["%d.%m.%y", "dd.MM.yy"], ["%d.%m.%Y", "dd.MM.yyyy"], ["%Y-%m-%d", "yyyy-MM-dd"], ["%y%m%d", "yyMMdd"], ["%d-%m-%Y", "dd-MM-yyyy"]];
    body = `<div class="form">
      <label>Client folders</label><label class="check"><input type="checkbox" id="s-client" ${s.useClientFolder ? "checked" : ""}> Make a folder per client</label>
      <label>Project folder name</label><select id="s-datepos"><option value="after" ${s.datePosition === "after" ? "selected" : ""}>Project name + date</option><option value="before" ${s.datePosition === "before" ? "selected" : ""}>Date + project name</option><option value="none" ${s.datePosition === "none" ? "selected" : ""}>No date</option></select>
      <label>Date format</label><select id="s-datefmt">${formats.map(([v, l]) => `<option value="${v}" ${s.dateFormat === v ? "selected" : ""}>${l}</option>`).join("")}</select>
      <label>File types</label><label class="check"><input type="checkbox" id="s-split" ${s.separateByType ? "checked" : ""}> Split into a folder per type</label>
      <label>Video folder</label><input type="text" id="s-vf" value="${esc(s.videoFolder)}">
      <label>Photo folder</label><input type="text" id="s-pf" value="${esc(s.photoFolder)}">
      <label>Audio folder</label><input type="text" id="s-af" value="${esc(s.audioFolder)}">
      <label style="font-weight:600;color:var(--text)">Assets</label><span class="small muted">Logos, music, briefs and client footage (Sort downloads, or loose files dragged in).</span>
      <label>Assets folder</label><input type="text" id="s-mf" value="${esc(s.materialFolder)}">
      <label>Sort by type</label><label class="check"><input type="checkbox" id="s-msplit" ${s.splitMaterial ? "checked" : ""}> Split into a folder per type</label>
      <label>Cameras and phones</label><label class="check"><input type="checkbox" id="s-mdev" ${s.groupByDevice ? "checked" : ""} ${s.splitMaterial ? "" : "disabled"}> Folder per camera or phone (Video and Photo)</label>
      <span></span><div><button type="button" class="btn" id="s-rename">Rename folders…</button></div></div>`;
  } else if (settingsTab === "check") {
    body = `<div class="form">
      <label>Default for new cards</label><label class="check"><input type="checkbox" id="s-skip" ${s.skipExisting ? "checked" : ""}> Only copy files that aren't there yet</label>
      <label>Check with</label><select id="s-mode"><option value="thorough" ${s.checkMode === "thorough" ? "selected" : ""}>Thorough: compare file contents (hash)</option><option value="fast" ${s.checkMode === "fast" ? "selected" : ""}>Quick: match name, size &amp; date</option></select>
      <span></span><div class="small muted">Existing files are recognised anywhere in the main folder, so footage already offloaded to another project isn't copied twice. Existing files are never overwritten.</div>
      <span></span><div class="small muted">Every copied file is read back from the destination disk and checked with xxHash64. Cards are only ever read. Unfinished files are saved under a temporary name, so a half-copied file never has its real name.</div></div>`;
  } else {
    const ct = S.connectTask;
    body = `<div class="form">
      <label>Upload</label><label class="check"><input type="checkbox" id="s-cloud" ${s.cloudEnabled ? "checked" : ""}> Upload to Google Drive after copying</label>
      <label>Connect with</label><select id="s-cmode"><option value="ownAccount" ${s.cloudMode === "ownAccount" ? "selected" : ""}>Google account (sign in through BCKUP)</option><option value="existingRemote" ${s.cloudMode === "existingRemote" ? "selected" : ""}>Existing rclone remote</option></select>
      ${s.cloudMode === "ownAccount" ? `
        <label>Google account</label><div class="row"><span class="${S.cloudConnected ? "green" : "muted"}" style="flex:1">${S.cloudConnected ? "Connected" : "Not connected"}</span>
          ${ct.running ? `<span class="spin"></span>` : S.cloudConnected ? `<button type="button" class="btn" id="s-connect">Switch account…</button><button type="button" class="btn" id="s-disconnect">Disconnect</button>` : `<button type="button" class="btn primary" id="s-connect">Connect Google account…</button>`}</div>
        <span></span><div class="small muted">${esc(ct.running ? ct.label : ct.message || "Everyone who uses BCKUP signs in with their own Google account. The sign-in is kept for BCKUP only, separate from any other rclone setup on this computer.")}</div>
        <label>Client ID (optional)</label><input type="text" id="s-cid" value="${esc(s.cloudClientId)}" placeholder="Your own OAuth client ID">
        <label>Client secret</label><input type="password" id="s-csec" value="${esc(s.cloudClientSecret)}">
        <span></span><div class="small muted">Recommended for regular use. rclone's built-in client ID is shared by many people and is being retired. Create one in Google Cloud Console (OAuth client, type Desktop app), enter it here, then connect again.</div>`
      : `<label>Remote</label><select id="s-remote"><option value="">Choose…</option>${remotes.map((r) => `<option ${r === s.cloudRemote ? "selected" : ""}>${esc(r)}</option>`).join("")}</select>`}
      <label>Folder on Drive</label><input type="text" id="s-cpath" value="${esc(s.cloudPath)}">
      <label>rclone</label><span class="small muted">${esc(S.rclone ? (S.rclone.includes("resources") ? "included with BCKUP" : S.rclone) : "not found")}</span>
      <label>No sign-in</label><div style="display:flex;flex-direction:column;gap:6px">${driveFolders.length ? driveFolders.map((f) => `<div class="row"><span class="mono small" style="flex:1;min-width:0">${esc(f)}</span>${s.backupRoots.some((b) => b.startsWith(f)) ? `<span class="green">In use</span>` : `<button type="button" class="btn small" data-gd="${esc(f)}">Use as backup</button>`}</div>`).join("") : `<span class="muted">Google Drive for desktop isn't installed on this computer.</span>`}
        <span class="small muted">If Google Drive for desktop is installed, its folder can be used as an ordinary backup drive. Make sure syncing has finished before you format a card.</span></div></div>`;
  }
  setBar("");
  $("#view").innerHTML = `<h1>Settings</h1><div class="tabs">${tabs.map(([k, l]) => `<button type="button" data-tab="${k}" class="${settingsTab === k ? "on" : ""}">${l}</button>`).join("")}</div><div class="panel">${body}</div>`;
  document.querySelectorAll("[data-tab]").forEach((b) => b.onclick = async () => {
    settingsTab = b.dataset.tab;
    if (settingsTab === "cloud") { remotes = await invoke("list_remotes"); driveFolders = await invoke("desktop_drive_folders"); }
    renderSettings();
  });
  const save = (patch) => invoke("save_settings", { settings: { ...S.settings, ...patch } });
  const bindv = (id, key, f = (e) => e.target.value) => $("#" + id)?.addEventListener("change", (e) => save({ [key]: f(e) }));
  const bindc = (id, key) => bindv(id, key, (e) => e.target.checked);
  $("#s-primary")?.addEventListener("click", () => call("choose_primary"));
  $("#s-backup")?.addEventListener("click", () => call("add_backup"));
  document.querySelectorAll("[data-rm]").forEach((b) => b.onclick = () => save({ backupRoots: S.settings.backupRoots.filter((x) => x !== b.dataset.rm) }));
  bindc("s-auto", "autoOpenOnCard");
  $("#s-unhide")?.addEventListener("click", () => save({ hiddenVolumes: [] }));
  bindc("s-client", "useClientFolder");
  bindv("s-datepos", "datePosition");
  bindv("s-datefmt", "dateFormat");
  bindc("s-split", "separateByType");
  bindv("s-vf", "videoFolder"); bindv("s-pf", "photoFolder"); bindv("s-af", "audioFolder");
  bindv("s-mf", "materialFolder");
  bindc("s-msplit", "splitMaterial");
  bindc("s-mdev", "groupByDevice");
  $("#s-rename")?.addEventListener("click", renameModal);
  bindc("s-skip", "skipExisting");
  bindv("s-mode", "checkMode");
  bindc("s-cloud", "cloudEnabled");
  bindv("s-cmode", "cloudMode");
  bindv("s-cid", "cloudClientId"); bindv("s-csec", "cloudClientSecret");
  bindv("s-remote", "cloudRemote");
  bindv("s-cpath", "cloudPath");
  $("#s-connect")?.addEventListener("click", () => call("connect_google"));
  $("#s-disconnect")?.addEventListener("click", () => call("disconnect_google"));
  document.querySelectorAll("[data-gd]").forEach((b) => b.onclick = () => call("use_desktop_drive", { folder: b.dataset.gd }));
}

// Test hook (BCKUP_TEST_AUTO): open the first card, name the project, check, then copy.
let autoStep = 0;
let testViewDone = false;
async function testAuto() {
  if (S.testView && !testViewDone) { testViewDone = true; go(S.testView); return; }
  if (!S.testAuto || !S.cards.length) return;
  if (autoStep === 0) { autoStep = 1; go("job", S.cards[0].path); return; }
  if (!J || !J.job.scan) return;
  const j = J.job;
  if (autoStep === 1 && j.stage === "ready" && !j.quickRunning) {
    autoStep = 2;
    await invoke("update_form", { source: j.source, form: { ...j.form, project: "Tauri Test" } });
    await invoke("check_job", { source: j.source });
  } else if (autoStep === 2 && j.stage === "planned") {
    autoStep = 3;
    if (S.testAuto && !window.__noStart) await invoke("start_job", { source: j.source });
  }
}

// MARK: rename folders

const ASSET_CATS = [["video", "Video", "mp4, mov, mxf"], ["photo", "Photo", "jpg, heic, raw"], ["audio", "Audio", "wav, mp3, aac"], ["graphics", "Graphics", "png, svg, ai, eps, psd"], ["documents", "Documents", "pdf, docx, pptx, xlsx, txt"], ["fonts", "Fonts", "ttf, otf"], ["projectFiles", "Project Files", "prproj, aep, drp, cube"], ["archives", "Archives", "zip, rar, 7z"], ["other", "Other", "everything else"]];

function renameModal() {
  const s = S.settings;
  const host = document.getElementById("modal");
  const names = s.materialNames || {};
  host.innerHTML = `<div class="modal-bg"><div class="modal">
    <h3>Folder names</h3>
    <div class="form">
      <label style="font-weight:600;color:var(--text)">Camera cards</label><span></span>
      <label>Video</label><input type="text" id="rn-video" value="${esc(s.videoFolder)}">
      <label>Photo</label><input type="text" id="rn-photo" value="${esc(s.photoFolder)}">
      <label>Audio</label><input type="text" id="rn-audio" value="${esc(s.audioFolder)}">
      <label style="font-weight:600;color:var(--text)">Assets</label><span></span>
      <label>Assets folder</label><input type="text" id="rn-material" value="${esc(s.materialFolder)}">
      <span></span><label class="check"><input type="checkbox" id="rn-split" ${s.splitMaterial ? "checked" : ""}> Split into a folder per type</label>
      <span></span><label class="check"><input type="checkbox" id="rn-dev" ${s.groupByDevice ? "checked" : ""}> Folder per camera or phone (Video and Photo)</label>
      ${ASSET_CATS.map(([k, d, ex]) => `<label title="${ex}">${d}</label><input type="text" data-cat="${k}" value="${esc(names[k] || d)}" title="${ex}">`).join("")}
    </div>
    <div class="small muted">New names apply to folders made from now on. Folders already on your drives aren't renamed.</div>
    <div class="row"><button type="button" class="btn" id="rn-reset">Reset to defaults</button><span style="flex:1"></span><button type="button" class="btn" id="rn-cancel">Cancel</button><button type="button" class="btn primary" id="rn-save">Save</button></div>
  </div></div>`;
  const close = () => { host.innerHTML = ""; };
  $("#rn-cancel", host).onclick = close;
  $("#rn-reset", host).onclick = async () => {
    await invoke("save_settings", { settings: { ...S.settings, videoFolder: "Video", photoFolder: "Photo", audioFolder: "Audio", materialFolder: "MATERIAL", splitMaterial: true, groupByDevice: true, materialNames: {} } });
    close();
  };
  $("#rn-save", host).onclick = async () => {
    const materialNames = {};
    host.querySelectorAll("[data-cat]").forEach((i) => { materialNames[i.dataset.cat] = i.value.trim(); });
    await invoke("save_settings", { settings: { ...S.settings,
      videoFolder: $("#rn-video", host).value.trim() || "Video", photoFolder: $("#rn-photo", host).value.trim() || "Photo",
      audioFolder: $("#rn-audio", host).value.trim() || "Audio", materialFolder: $("#rn-material", host).value.trim() || "MATERIAL",
      splitMaterial: $("#rn-split", host).checked, groupByDevice: $("#rn-dev", host).checked, materialNames } });
    close();
    if (route.view === "job" && J) pushForm(J.job, true);
  };
}

// MARK: boot

async function chooseSource() {
  const key = await call("choose_source");
  if (key) go("job", key);
}

$("#btn-source").innerHTML = icon("plus") + " Choose a source folder…";
$("#btn-settings").innerHTML = icon("gear") + " Settings";
$("#btn-source").onclick = chooseSource;
$("#btn-settings").onclick = () => go("settings");

listen("state", refresh);
listen("projects-changed", () => loadProjects(false));
listen("select-source", (e) => go("job", e.payload));
listen("open-view", (e) => go(e.payload.view, e.payload.source || null));

// Drag-and-drop highlight (the drop itself is handled by the backend).
T.event.listen("tauri://drag-enter", () => $("#drop").classList.remove("hidden"));
T.event.listen("tauri://drag-leave", () => $("#drop").classList.add("hidden"));
T.event.listen("tauri://drag-drop", () => $("#drop").classList.add("hidden"));

addEventListener("keydown", (e) => {
  const mod = e.ctrlKey || e.metaKey;
  if (mod && e.key === "1") go("home");
  if (mod && e.key === "2") go("projects");
  if (mod && e.key === "3") go("downloads");
  if (mod && e.key === ",") go("settings");
  if (e.key === "Escape") closeMenu();
});

refresh();
