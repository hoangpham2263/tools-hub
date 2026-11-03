// Product Review's window, on macOS and Windows alike, drawn like Windows 10 classic controls; the work itself runs
// in PowerShell through server.mjs.
"use strict";

// ---------- helpers ----------
const api = async (cmd, args = {}) => {
  const r = await fetch("/api/rpc", { method: "POST", body: JSON.stringify({ cmd, args }) });
  const body = await r.json();
  if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
  return body.result;
};
// PowerShell unrolls one-item arrays; lists always come back as arrays here.
const list = (v) => (Array.isArray(v) ? v : v == null ? [] : [v]);
const fileUrl = (p) => `/file?path=${encodeURIComponent(p)}&t=${Date.now()}`;

function el(tag, cls = "", props = {}) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  for (const [k, v] of Object.entries(props)) {
    if (k === "text") e.textContent = v;
    else if (k === "style") Object.assign(e.style, v);
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e[k] = v;
  }
  return e;
}
// left, top, width, height (px), plus right/bottom for anchored edges, like WinForms Location/Size/Anchor.
function at(e, l, t, w, h, anchor = {}) {
  const s = e.style;
  if (anchor.right != null) { s.right = anchor.right + "px"; if (anchor.left !== false) s.left = l + "px"; else s.width = w + "px"; }
  else { s.left = l + "px"; if (w != null) s.width = w + "px"; }
  if (anchor.bottom != null) { s.bottom = anchor.bottom + "px"; if (anchor.top !== false) s.top = t + "px"; else s.height = h + "px"; }
  else { s.top = t + "px"; if (h != null) s.height = h + "px"; }
  if (anchor.right != null && anchor.left !== false) s.removeProperty("width");
  if (anchor.bottom != null && anchor.top !== false) s.removeProperty("height");
  return e;
}
const label = (text, cls = "") => el("div", "label " + cls, { text });
const button = (text, primary = false) => el("button", "btn" + (primary ? " primary" : ""), { text, type: "button" });
function picture(cls = "") {
  const p = el("div", "pic " + cls);
  const img = el("img");
  img.hidden = true;
  p.append(img);
  p.set = (path, emptyText = "") => {
    p.querySelector(".empty")?.remove();
    p.classList.toggle("has", !!path);
    img.hidden = !path;
    if (path) { img.src = fileUrl(path); img.onerror = () => { img.hidden = true; }; }
    else if (emptyText) p.append(el("div", "empty", { text: emptyText }));
  };
  // A small × on hover removes the shown image (Add-RemoveOverlay).
  p.onRemove = (fn) => { const x = el("div", "x", { text: "×" }); x.addEventListener("click", (e) => { e.stopPropagation(); fn(); }); p.append(x); };
  return p;
}
function numeric(min, max, value) {
  const box = el("div", "num");
  const input = el("input", "", { value: String(value) });
  const spin = el("div", "spin");
  const up = el("button", "up", { type: "button" }), down = el("button", "down", { type: "button" });
  spin.append(up, down);
  box.append(input, spin);
  const clamp = (v) => Math.max(box.min, Math.min(box.max, Number.isFinite(v) ? Math.round(v) : box.min));
  Object.assign(box, { min, max });
  Object.defineProperty(box, "value", { get: () => clamp(Number(input.value)), set: (v) => { input.value = String(clamp(v)); } });
  Object.defineProperty(box, "enabled", { set: (on) => { input.disabled = !on; up.disabled = !on; down.disabled = !on; box.classList.toggle("disabled", !on); } });
  up.onclick = () => { box.value = box.value + 1; };
  down.onclick = () => { box.value = box.value - 1; };
  input.onblur = () => { box.value = Number(input.value); };
  return box;
}
function combo(items = []) {
  const s = el("select", "combo");
  s.setItems = (values, labels = values) => { s.replaceChildren(...values.map((v, i) => new Option(labels[i], v))); };
  s.setItems(items);
  return s;
}
function checkbox(text) {
  const wrap = el("label", "check");
  const input = el("input", "", { type: "checkbox" });
  wrap.append(input, document.createTextNode(text));
  wrap.input = input;
  return wrap;
}
// Pick image files from disk; each one is uploaded so PowerShell gets a real file path.
async function upload(file) {
  const r = await fetch(`/api/upload?name=${encodeURIComponent(file.name || "clipboard.png")}`, { method: "POST", body: file });
  const body = await r.json();
  if (!r.ok) throw new Error(body.error);
  return body.path;
}
const imageFiles = (items) => [...items].filter((f) => /^image\/(png|jpeg)$/.test(f.type));

// Errors in this window are logged on the Mac side (workspace/logs/app-errors.log) and go out with Gửi lỗi.
const reportError = (message, stack) => fetch("/api/client-error", { method: "POST", body: JSON.stringify({ message: String(message || ""), stack: String(stack || "") }) }).catch(() => {});
addEventListener("error", (e) => reportError(e.message, e.error?.stack || `${e.filename}:${e.lineno}:${e.colno}`));
addEventListener("unhandledrejection", (e) => reportError(e.reason?.message || e.reason, e.reason?.stack));

// A product link as the list shows it, short and readable (Format-ShortProductUrl on Windows).
function shortUrl(link) {
  let u;
  try { u = new URL(link.trim()); } catch { return link.trim(); }
  if (u.hostname === "local.invalid") return "Sản phẩm tự thêm (không có link)";
  const site = u.hostname.replace(/^www\./, "");
  const parts = u.pathname.split("/").filter(Boolean);
  if (!parts.length) return site;
  let name = decodeURIComponent(parts.at(-1)).replace(/\.(html?|php|aspx?)$/, "");
  if (name.length > 32) name = name.slice(0, 31) + "…";
  return `${site} › ${name}`;
}

// ---------- fit to the window ----------
// Laid out for 1024 x 721 at least (#client). A smaller window scales the whole page down to fit instead of cutting
// it off; below 60% it stops shrinking and scrolls. Child windows are centred in the page's own (scaled) size.
let zoom = 1;
const viewWidth = () => innerWidth / zoom, viewHeight = () => innerHeight / zoom;
function fitWindow() {
  zoom = Math.max(0.6, Math.min(1, innerWidth / 1024, innerHeight / 721));
  document.documentElement.style.zoom = zoom === 1 ? "" : String(zoom);
  document.body.style.overflow = viewWidth() < 1023 || viewHeight() < 720 ? "auto" : "";
}
fitWindow();
addEventListener("resize", fitWindow);

// ---------- child windows ----------
const stack = [];
function openWindow(title, w, h, { white = false } = {}) {
  const modal = el("div", "modal");
  const win = el("div", "window");
  const bar = el("div", "titlebar");
  const close = el("button", "close", { text: "✕", type: "button" });
  bar.append(el("div", "t", { text: title }), close);
  const body = el("div", "wbody" + (white ? " white" : ""));
  body.style.width = w + "px";
  body.style.height = h + "px";
  win.append(bar, body);
  modal.append(win);
  document.body.append(modal);
  const place = () => {
    win.style.left = Math.max(0, Math.round((viewWidth() - win.offsetWidth) / 2)) + "px";
    win.style.top = Math.max(0, Math.round((viewHeight() - win.offsetHeight) / 2)) + "px";
  };
  place();
  const view = { body, win, onClose: null, closed: false, cancel: null };
  view.close = () => {
    if (view.closed) return;
    view.closed = true;
    modal.remove();
    stack.splice(stack.indexOf(view), 1);
    updateActionAvailability();
    view.onClose?.();
  };
  close.onclick = () => (view.cancel || view.close)();
  stack.push(view);
  updateActionAvailability();
  return view;
}
addEventListener("keydown", (e) => {
  const top = stack.at(-1);
  if (e.key === "Escape" && top) { e.preventDefault(); (top.cancel || top.close)(); }
});
// ContextMenuStrip shown under a button: [{ text, disabled, onClick }]; a click elsewhere closes it.
function dropMenu(anchor, items) {
  const menu = el("div", "menu");
  const done = () => { menu.remove(); removeEventListener("mousedown", outside, true); removeEventListener("keydown", escape, true); };
  const outside = (e) => { if (!menu.contains(e.target)) done(); };
  const escape = (e) => { if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); done(); } };
  for (const item of items) {
    const row = el("div", item.disabled ? "off" : "", { text: item.text });
    if (!item.disabled) row.onclick = () => { done(); item.onClick(); };
    menu.append(row);
  }
  // Screen positions are scaled by the page's zoom (fitWindow); the menu's are not.
  const r = anchor.getBoundingClientRect();
  Object.assign(menu.style, { left: r.left / zoom + "px", top: r.bottom / zoom + "px" });
  document.body.append(menu);
  addEventListener("mousedown", outside, true);
  addEventListener("keydown", escape, true);
}
// MessageBox.Show: resolves "OK", "Yes" or "No".
function messageBox(text, title = "", buttons = ["OK"], labels = {}) {
  return new Promise((resolve) => {
    const view = openWindow(title, 0, 0);
    view.win.classList.add("msg");
    view.body.style.width = view.body.style.height = "";
    const bar = el("div", "bar");
    const names = { OK: "OK", Yes: "Yes", No: "No", ...labels };
    let answer = buttons.includes("No") ? "No" : "OK";
    for (const b of buttons) {
      const btn = el("button", "btn", { text: names[b], type: "button" });
      btn.onclick = () => { answer = b; view.close(); };
      bar.append(btn);
    }
    view.body.append(el("div", "txt", { text }), bar);
    view.onClose = () => resolve(answer);
    view.win.style.minWidth = "180px";
    view.win.style.left = Math.round((viewWidth() - view.win.offsetWidth) / 2) + "px";
    view.win.style.top = Math.round((viewHeight() - view.win.offsetHeight) / 2) + "px";
    bar.firstChild.focus();
  });
}

// Bỏ asks what is wrong (optional); null when closed without choosing Bỏ.
function askReason(title) {
  return new Promise((resolve) => {
    const view = openWindow(title, 0, 0);
    view.win.classList.add("msg");
    view.body.style.width = view.body.style.height = "";
    const box = el("textarea", "text", { placeholder: "Lỗi gì? Vd: sai màu sản phẩm, ảnh méo, chữ sai…" });
    Object.assign(box.style, { width: "360px", height: "84px", margin: "12px 12px 0", display: "block" });
    const bar = el("div", "bar");
    const skip = el("button", "btn", { text: "Bỏ", type: "button" }), cancel = el("button", "btn", { text: "Hủy", type: "button" });
    let answer = null;
    skip.onclick = () => { answer = box.value.trim(); view.close(); };
    cancel.onclick = () => view.close();
    bar.append(skip, cancel);
    view.body.append(box, bar);
    view.onClose = () => resolve(answer);
    view.win.style.left = Math.round((viewWidth() - view.win.offsetWidth) / 2) + "px";
    view.win.style.top = Math.round((viewHeight() - view.win.offsetHeight) / 2) + "px";
    box.focus();
  });
}

// ---------- main window ----------
const ui = { client: document.getElementById("client") };
const state = { rows: [], fallback: false, library: "drive", group: "Áo", drive: false, version: "", output: "", codex: false };
const run = { active: false, since: 0, total: 0, done: 0, index: 0, stages: new Map(), jobRows: [], stage: "", stopped: false, failure: false, started: 0, resultFolder: "", anim: 0 };

function buildMain() {
  const c = ui.client;
  // Header (Dock Top, 64).
  const header = at(el("div", "panel"), 0, 0, null, 64, { right: 0 });
  // Opened from the Tools Hub menu (?hub=<its port>, kept for reloads): "← Menu" goes back to it.
  const hub = new URLSearchParams(location.search).get("hub") || sessionStorage.getItem("hub");
  if (hub) sessionStorage.setItem("hub", hub);
  header.append(at(label("Product Review", ""), hub ? 122 : 20, 19, null, 26));
  header.firstChild.style.fontSize = "17.33px";
  if (hub) {
    ui.btnMenu = at(button("← Menu"), 20, 16, 90, 32);
    ui.btnMenu.onclick = () => { location.href = `http://127.0.0.1:${hub}/`; };
    header.append(ui.btnMenu);
  }
  ui.btnUpdate = at(button("Cập nhật"), null, 16, 100, 32, { right: 24, left: false });
  // Cấu hình: shared by every tool (hub/setup), left of Cập nhật as on the Tools Hub menu.
  ui.btnSetup = at(button("Cấu hình"), null, 16, 100, 32, { right: 132, left: false });
  // Tải về máy runs in the background (src/sync-source.ps1); its progress shows here, in the header, so work goes on.
  ui.syncLabel = at(label("", "muted"), 260, 14, null, 22, { right: 342 });
  ui.syncLabel.style.textAlign = "right";
  ui.syncBar = at(el("div", "progress"), null, 40, 200, 4, { right: 342, left: false });
  ui.syncBar.append(el("span"));
  ui.syncLabel.hidden = ui.syncBar.hidden = true;
  // Tải lại: this tool's server starts again on the files as they are now and the page loads afresh.
  ui.btnReload = at(button("Tải lại"), null, 16, 90, 32, { right: 240, left: false });
  header.append(ui.btnReload, ui.btnSetup, ui.btnUpdate, ui.syncLabel, ui.syncBar);

  // Link sản phẩm & ảnh (20,78 820x344, Top/Left/Right).
  const cardList = at(el("div", "card"), 20, 78, null, 344, { right: 264 });
  cardList.append(at(label("Link sản phẩm & ảnh"), 14, 10, null, 20));
  const editor = at(el("div", "panel"), 14, 36, null, 296, { right: 14 });
  ui.btnAdd = at(button("+ Thêm sản phẩm", true), 0, 0, 160, 34);
  ui.btnBulk = at(button("Nhập hàng loạt"), 172, 0, 150, 34);
  ui.btnClear = at(button("Xóa tất cả"), 334, 0, 120, 34);
  ui.flow = at(el("div", "flow"), 0, 44, null, null, { right: 0, bottom: 0 });
  Object.assign(ui.flow.style, { background: "#fff", border: "1px solid var(--border)", borderRadius: "10px", padding: "10px 10px 6px 10px" });
  editor.append(ui.btnAdd, ui.btnBulk, ui.btnClear, ui.flow);
  cardList.append(editor);

  // Thao tác (856,78 224x344, Top/Right).
  const cardActions = at(el("div", "card"), null, 78, 224, 344, { right: 24, left: false });
  cardActions.append(at(label("Thao tác"), 14, 10, null, 20));
  // In the order they are used: review the results, open them, then support. Cấu hình is in the header.
  const names = [["btnReview", "Duyệt & xuất file"], ["btnOut", "Mở kết quả"], ["btnLogs", "Gửi lỗi"], ["btnClearLog", "Xóa thông báo"]];
  names.forEach(([key, text], i) => { ui[key] = at(button(text), 14, 36 + i * 37, 196, 32); cardActions.append(ui[key]); });

  // Run row (20,434 1060x62).
  const cardRun = at(el("div", "card"), 20, 434, null, 62, { right: 24 });
  ui.btnRun = at(button("Bắt đầu", true), 14, 11, 160, 40);
  ui.btnStop = at(button("Dừng"), 186, 11, 100, 40);
  ui.btnStop.disabled = true;
  ui.lblStatus = at(label("", "muted"), 302, 18, 150, 26);
  ui.lblStatus.style.lineHeight = "26px";
  ui.lblThr = at(label("Luồng:", "muted"), null, 19, 56, 24, { right: 88, left: false });
  ui.numThr = at(numeric(1, 4, 2), null, 16, 64, 24, { right: 22, left: false });
  ui.lblThr.style.lineHeight = "24px";
  // Which AI does the work: Codex, or the sites in the tools' own Chrome (signed in from Cấu hình). Viết review covers
  // every text step; Tạo ảnh the photo. Remembered on this machine.
  const picker = (text, y, key, values, labels) => {
    const name = at(label(text, "muted"), null, y, 76, 22, { right: 316, left: false });
    name.style.lineHeight = "22px";
    const box = at(combo(), null, y, 150, 22, { right: 158, left: false });
    box.setItems(values, labels);
    try { box.value = localStorage.getItem(key) || values[0]; } catch {}
    if (!box.value) box.value = values[0];
    box.onchange = () => { try { localStorage.setItem(key, box.value); } catch {} updateUsage(); };
    return [name, box];
  };
  [ui.lblText, ui.cmbText] = picker("Viết review:", 6, "textBackend", ["codex", "gemini", "antigravity"], ["Codex", "Gemini web", "Antigravity CLI"]);
  [ui.lblBackend, ui.cmbBackend] = picker("Tạo ảnh:", 33, "imageBackend", ["codex", "flow"], ["Codex", "Google Flow"]);
  // Tokens this run has used (added up from each Codex call) and the quota left, refreshed in the background.
  // They shrink with the window (cut with …) so they never run under the pickers on the right.
  ui.lblTokens = at(label("", "muted"), 460, 11, null, 20, { right: 400 });
  ui.lblQuota = at(label("", "muted"), 460, 31, null, 20, { right: 400 });
  for (const l of [ui.lblTokens, ui.lblQuota]) Object.assign(l.style, { fontSize: "12px", lineHeight: "20px" });
  cardRun.append(ui.btnRun, ui.btnStop, ui.lblStatus, ui.lblTokens, ui.lblQuota, ui.lblText, ui.cmbText, ui.lblBackend, ui.cmbBackend, ui.lblThr, ui.numThr);

  // Tiến trình & thông báo (20,508 1060x282, all anchors).
  const cardLog = at(el("div", "card"), 20, 508, null, null, { right: 24, bottom: 10 });
  cardLog.append(at(label("Tiến trình & thông báo"), 14, 10, null, 20));
  ui.bar = at(el("div", "progress"), 14, 36, null, 8, { right: 14 });
  ui.bar.append(el("span"));
  ui.lblProgress = at(label("Thêm sản phẩm và ảnh đi kèm để bắt đầu."), 14, 50, null, 24, { right: 14 });
  ui.lblProgress.style.lineHeight = "24px";
  ui.txtLog = at(el("textarea", "text", { readOnly: true }), 14, 80, null, null, { right: 14, bottom: 12 });
  cardLog.append(ui.bar, ui.lblProgress, ui.txtLog);

  c.append(header, cardList, cardActions, cardRun, cardLog);
}

function appendLog(text) { if (text) { ui.txtLog.value += text + "\n"; ui.txtLog.scrollTop = ui.txtLog.scrollHeight; } }
function setStatus(text, color) { ui.lblStatus.textContent = text; ui.lblStatus.style.color = color || "var(--muted)"; }
function countUrls() { return new Set(state.rows.map((r) => r.url.trim()).filter(Boolean)).size; }
function updateStatus() { if (!run.active) setStatus(`Sẵn sàng • ${countUrls()} sản phẩm`); }
function setBar(value, max, marquee = false) {
  ui.bar.classList.toggle("marquee", marquee);
  ui.bar.firstChild.style.width = marquee ? "" : `${Math.min(100, (value / Math.max(1, max)) * 100)}%`;
}

// ----- queue rows (Add-ProductQueueRow / Update-ProductQueueRow) -----
// Link info from PowerShell: products[] (each with scenes[]) plus all scenes flattened.
function normInfo(info) {
  if (!info) return null;
  return { ...info, products: list(info.products).map((p) => ({ ...p, scenes: list(p.scenes) })), scenes: list(info.scenes) };
}
function rowStatus(row) {
  const products = row.info?.products || [], scenes = row.info?.scenes || [];
  const image = products.find((p) => p.ok)?.file || scenes.find((s) => s.ok)?.file || "";
  if (scenes.some((s) => !s.ok) || products.some((p) => p.file && !p.ok)) return { text: "Không đọc được ảnh, hãy gắn lại.", color: "var(--error)", image };
  if (products.some((p) => !p.scenes.length)) return { text: "● Có ảnh gốc chưa có review", color: "var(--warn)", image };
  if (scenes.length) return { text: products.length > 1 ? `● ${products.length} mẫu · ${scenes.length} ảnh` : scenes.length > 1 ? `● ${scenes.length} ảnh` : "● Đã có ảnh", color: "var(--ok)", image };
  return row.url.trim() ? { text: "● Chưa có ảnh", color: "var(--warn)", image: "" } : { text: "Chưa có link", color: "var(--muted)", image: "" };
}
// Each row's status label, so a run can update it without rebuilding the row (a rebuild reloads every thumbnail).
let statusOf = new WeakMap();
function renderRows() {
  statusOf = new WeakMap();
  const width = Math.max(700, ui.flow.clientWidth - 40);
  ui.flow.replaceChildren(...state.rows.map((row, i) => {
    const card = el("div", "qrow", { style: { width: width + "px" } });
    const st = row.stage ? { text: row.stage.text, color: row.stage.color } : rowStatus(row);
    const pic = at(picture(), width - 192, 8, 44, 44);
    pic.set(rowStatus(row).image);
    // Wide enough for the longest stage ("◔ Đang tạo ảnh, lượt gửi 1/3").
    const status = at(label(st.text), width - 430, 19, 230, 24);
    status.style.color = st.color;
    status.style.lineHeight = "24px";
    statusOf.set(row, status);
    const open = at(button("Xem / sửa"), width - 136, 12, 90, 34);
    const remove = at(button("×"), width - 40, 12, 32, 34);
    remove.title = "Xóa sản phẩm";
    // Shown short ("shop.com › product-name"); the full link on hover.
    const url = at(el("div", "text plain", { text: shortUrl(row.url) }), 52, 20, width - 487, 22);
    Object.assign(url.style, { lineHeight: "20px", textOverflow: "ellipsis" });
    url.title = row.url.trim();
    card.append(at(label("#" + (i + 1), "muted"), 10, 19, 40, 22), url, status, pic, open, remove);
    card.onclick = (e) => { if (!run.active && e.target !== remove) showProductDialog(row); };
    remove.onclick = (e) => { e.stopPropagation(); if (run.active) return; state.rows.splice(state.rows.indexOf(row), 1); renderRows(); updateStatus(); persist(); };
    // Drop images straight onto the row thumbnail.
    pic.addEventListener("dragover", (e) => e.preventDefault());
    pic.addEventListener("drop", async (e) => {
      e.preventDefault(); e.stopPropagation();
      try {
        const files = imageFiles(e.dataTransfer.files);
        if (!files.length) return;
        const root = await api("draftOpen");
        await api("draftAttach", { root, url: row.url.trim(), paths: await Promise.all(files.map(upload)) });
        row.info = normInfo(await api("draftSave", { root, url: row.url.trim(), others: [], group: state.group }));
        renderRows();
      } catch (err) { row.stage = { text: err.message, color: "var(--error)" }; renderRows(); row.stage = null; }
    });
    return card;
  }));
}

async function loadState() {
  Object.assign(state, await api("state"));
  state.rows = list(state.rows).map((info) => ({ url: info.url, info: normInfo(info) }));
  document.title = ("Product Review " + (state.version || "")).trim();
  renderRows();
  updateStatus();
}

// The list saves itself on every change; Bắt đầu checks that every link is ready.
function persist() { saveQueue(false).catch(() => {}); }
async function saveQueue(requireReady = false) {
  return api("queueSave", { urls: state.rows.map((r) => r.url), requireReady });
}

async function updateReviewButton() {
  const pending = run.resultFolder ? await api("pending", { batch: run.resultFolder }).catch(() => 0) : 0;
  ui.btnReview.textContent = pending > 0 ? `Duyệt & xuất file (${pending})` : "Duyệt & xuất file";
  ui.btnReview.classList.toggle("primary", pending > 0);
}

// ----- product dialog: one row per product image, its review images beside it -----
// Small thumbnails only; clicking one opens it large. Each pair becomes one generated image.
function showImagePreview(path, title) {
  const view = openWindow(title, 760, 560);
  const pic = at(picture(), 12, 12, 736, 490);
  pic.style.background = "var(--smoke)";
  pic.set(path);
  const close = at(button("Đóng"), 648, 514, 100, 32);
  close.onclick = view.close;
  view.body.append(pic, close);
  close.focus();
}

// Native macOS file dialog opened at a folder; returns the picked files' real paths.
async function chooseImages(folder, table = false) {
  const r = await fetch("/api/choose-images", { method: "POST", body: JSON.stringify({ folder, table }) }).then((x) => x.json()).catch(() => ({ paths: [] }));
  return list(r.paths);
}

// "Từ kho Drive": nothing loads until a danh mục is chosen, so the window opens at once. Thêm uses the picked
// images directly (downloading only those not on this machine yet); Tải về máy brings the chosen danh mục, or
// every danh mục, over in one go. Either way nothing is fetched twice.
function showDrivePicker() {
  return new Promise((resolve) => {
    const noLogin = "Chưa đăng nhập mật khẩu app. Mở Cấu hình để đăng nhập.";
    const view = openWindow("Chọn ảnh review từ kho Drive", 760, 540);
    // One toolbar row, 28px tall: danh mục, Mặc định and Tải về máy share its height and centre line.
    const groups = at(combo(), 20, 14, 220, 28);
    // Mặc định: the picker opens on this danh mục next time (and loads it at once).
    const isDefault = at(checkbox("Mặc định"), 250, 14, 86, 28);
    isDefault.input.disabled = true;
    const sync = at(button("Tải về máy"), 342, 14, 120, 28);
    sync.classList.add("has-chevron");
    const count = at(label("", "muted"), 474, 14, 266, 28);
    count.style.lineHeight = "28px";
    const note = at(label(state.drive ? "" : noLogin), 20, 494, 500, 24);
    note.style.color = "var(--error)";
    // Background loading shows on a thin bar along the top of the grid: running while the Drive listing loads,
    // then filling as the thumbnails arrive.
    const loadBar = at(el("div", "progress"), 20, 46, 720, 4);
    loadBar.append(el("span"));
    loadBar.hidden = true;
    const grid = at(el("div", "flow"), 20, 52, 720, 420);
    Object.assign(grid.style, { background: "#fff", border: "1px solid var(--border)", borderRadius: "10px", display: "flex", flexWrap: "wrap", alignContent: "flex-start", gap: "6px", padding: "6px" });
    const add = at(button("Thêm", true), 536, 490, 110, 32), cancel = at(button("Hủy"), 656, 490, 84, 32);
    add.disabled = true;
    sync.disabled = !state.drive;
    view.body.append(groups, isDefault, sync, count, loadBar, grid, note, add, cancel);
    let files = [], shown = 0, result = [], all = [], syncing = false, loads = 0, listing = false, summary = "";
    const picked = new Map();
    view.onClose = () => resolve(result);
    view.cancel = () => { if (!syncing) view.close(); };
    cancel.onclick = view.cancel;
    const busy = (on) => { syncing = on; sync.disabled = on || !state.drive || !all.length; groups.disabled = on; cancel.disabled = on; add.disabled = on || !picked.size; };
    // Thumbnails load top to bottom, six at a time, so a big danh mục never loads all at once.
    const thumbs = { queue: [], active: 0, round: 0, total: 0, done: 0 };
    const refreshCount = () => {
      const loading = thumbs.done < thumbs.total, percent = thumbs.total ? Math.round((thumbs.done / thumbs.total) * 100) : 0;
      loadBar.hidden = !groups.value || !(listing || loading);
      loadBar.classList.toggle("marquee", listing && !loading);
      loadBar.firstChild.style.width = listing && !loading ? "" : `${percent}%`;
      if (syncing) return;
      if (!groups.value) { count.textContent = "Chọn danh mục để xem ảnh."; add.disabled = true; return; }
      add.disabled = !picked.size;
      if (loading) { count.textContent = `${picked.size ? `Đã chọn ${picked.size} · ` : ""}Đang tải ảnh ${thumbs.done}/${thumbs.total} (${percent}%)`; return; }
      if (listing) { count.textContent = files.length ? `${files.length} ảnh có trên máy · đang tải danh sách Drive…` : "Đang tải danh sách…"; return; }
      if (summary) { count.textContent = summary; return; }
      const local = files.filter((f) => f.local).length;
      count.textContent = files.length ? `Đã chọn ${picked.size} / ${files.length} ảnh · ${local} ảnh có trên máy` : "Danh mục này chưa có ảnh.";
    };
    const pump = () => {
      while (thumbs.active < 6 && thumbs.queue.length) {
        const [img, src] = thumbs.queue.shift();
        const round = thumbs.round;
        thumbs.active++;
        img.onload = img.onerror = () => { if (round === thumbs.round) { thumbs.active--; thumbs.done++; refreshCount(); pump(); } };
        img.src = src;
      }
    };
    const clearGrid = () => { Object.assign(thumbs, { queue: [], active: 0, total: 0, done: 0 }); thumbs.round++; grid.replaceChildren(); shown = 0; };
    const showMore = () => {
      grid.querySelector(".more")?.remove();
      for (const f of files.slice(shown, shown + 120)) {
        const tile = el("div", "", { style: { width: "100px", height: "100px", padding: "3px", background: picked.has(f.name) ? "var(--accent)" : "var(--smoke)", cursor: "pointer", flex: "none" } });
        const img = el("img", "", { decoding: "async", style: { width: "100%", height: "100%", objectFit: "contain", display: "block" } });
        tile.append(img);
        thumbs.queue.push([img, f.local ? `/file?path=${encodeURIComponent(f.local)}` : f.url]);
        tile.onclick = () => {
          summary = "";
          if (picked.has(f.name)) { picked.delete(f.name); tile.style.background = "var(--smoke)"; }
          else { picked.set(f.name, f); tile.style.background = "var(--accent)"; }
          refreshCount();
        };
        grid.append(tile);
      }
      thumbs.total += Math.min(files.length, shown + 120) - shown;
      shown = Math.min(files.length, shown + 120);
      if (shown < files.length) {
        const more = el("button", "btn more", { text: "Xem thêm", type: "button", style: { position: "static", width: "100px", height: "100px" } });
        more.onclick = showMore;
        grid.append(more);
      }
      pump(); refreshCount();
    };
    // A danh mục shows its local copies at once; the Drive listing loads in the background and, when it brings
    // more (or the local copies are out of date), the grid is redrawn from it, keeping what was picked.
    const load = async () => {
      const token = ++loads;
      clearGrid(); picked.clear(); files = []; listing = false; summary = "";
      note.style.color = "var(--error)";
      note.textContent = state.drive ? "" : noLogin;
      if (!groups.value) return refreshCount();
      const group = groups.value;
      if (state.drive) {
        listing = true; refreshCount();
        files = list(await api("sourceIndexedFiles", { group }).catch(() => []));
        if (token !== loads) return;
        showMore(); refreshCount();
      }
      const next = await api("sourceFiles", { group }).catch(() => ({ Files: files, Error: "Không kết nối được Drive (mạng hoặc mật khẩu app). Đang hiện ảnh có trên máy." }));
      if (token !== loads) return;
      listing = false;
      note.style.color = "var(--error)";
      note.textContent = next.Error || "";
      const nextFiles = list(next.Files);
      if (nextFiles.length !== files.length || nextFiles.some((f) => !f.local) || !state.drive) {
        const keep = new Set(picked.keys());
        picked.clear();
        for (const f of nextFiles) if (keep.has(f.name)) picked.set(f.name, f);
        clearGrid(); files = nextFiles; showMore();
      }
      refreshCount();
    };
    // Tải về máy runs in the background of the main window (progress in its header); this window stays usable.
    const runSync = async (names) => {
      if (!names.length) return;
      note.style.color = "var(--muted)";
      note.textContent = (await startSync(names)) ? "Đang tải ngầm, xem tiến độ ở thanh trên cùng. Vẫn làm việc bình thường." : "Đang có một lượt tải về máy, đợi xong rồi bấm lại.";
    };
    sync.onclick = () => dropMenu(sync, [
      { text: "Danh mục đang chọn", disabled: !groups.value, onClick: () => runSync([groups.value]) },
      { text: `Tất cả danh mục (${all.length})`, onClick: () => runSync(all) },
    ]);
    let defaultGroup = "";
    const showDefault = () => { isDefault.input.disabled = !groups.value; isDefault.input.checked = !!groups.value && groups.value === defaultGroup; };
    groups.onchange = () => { showDefault(); load(); };
    isDefault.input.onchange = () => {
      defaultGroup = isDefault.input.checked ? groups.value : "";
      api("sourceDefaultSet", { group: defaultGroup }).catch(() => {});
    };
    add.onclick = async () => {
      const chosen = [...picked.values()];
      const missing = chosen.filter((f) => !f.local);
      busy(true); count.textContent = missing.length ? `Đang tải ${missing.length} ảnh đã chọn…` : "Đang thêm…";
      try {
        const fetched = missing.length ? list(await api("sourcePick", { group: groups.value, files: missing.map(({ name, md5, url }) => ({ name, md5, url })) })) : [];
        result = [...chosen.filter((f) => f.local).map((f) => f.local), ...fetched];
        state.group = groups.value;
        busy(false);
        view.close();
      } catch { count.textContent = "Chưa tải được ảnh đã chọn. Kiểm tra mạng rồi thử lại."; busy(false); }
    };
    Promise.all([api("groups", { local: false }), api("sourceDefault").catch(() => "")]).then(([g, saved]) => {
      all = list(g);
      defaultGroup = saved || "";
      groups.setItems(["", ...all], ["Chọn danh mục…", ...all]);
      groups.value = all.includes(defaultGroup) ? defaultGroup : "";
      showDefault();
      load();
      if (!all.length) { count.textContent = "Chưa có danh mục nào đang bật."; sync.disabled = true; }
    }).catch(() => { count.textContent = "Chưa tải được danh sách danh mục."; });
  });
}

async function showProductDialog(target = null) {
  let root;
  try { root = await api("draftOpen"); } catch (e) { return appendLog(e.message); }
  const view = openWindow("Ảnh sản phẩm gốc & ảnh review", 760, 430, { white: true });
  const b = view.body;
  let saved = false;
  view.onClose = () => { document.removeEventListener("paste", onPaste); if (!saved) api("draftDiscard", { root }).catch(() => {}); };
  const urlBox = at(el("input", "text", { value: target ? target.url : "" }), 20, 40, 720, 25);
  const rowsBox = at(el("div", "flow"), 20, 100, 720, 250);
  Object.assign(rowsBox.style, { background: "#fff", border: "1px solid var(--border)", borderRadius: "10px" });
  const status = at(label(""), 20, 358, 500, 26);
  status.style.lineHeight = "26px";
  const save = at(button("Lưu sản phẩm"), 516, 388, 120, 30);
  const cancel = at(button("Hủy"), 646, 388, 94, 30);
  b.append(
    at(label("Link sản phẩm"), 20, 16, null, 22), urlBox,
    at(label("Ảnh gốc", "muted"), 26, 76, 70, 22), at(label("Ảnh review của ảnh gốc đó", "muted"), 110, 76, 300, 22),
    rowsBox, status, save, cancel,
  );
  view.cancel = view.close;
  cancel.onclick = view.close;
  const fail = (e) => { status.textContent = e.message; status.style.color = "var(--error)"; };


  // Paste and drop go to the row last used; -1 means "a new product image".
  let products = [], active = -1;
  const attach = async (files, productIndex) => {
    files = imageFiles(files);
    if (!files.length) return;
    try { await attachPaths(await Promise.all(files.map(upload)), productIndex); } catch (e) { fail(e); }
  };
  const attachPaths = async (paths, productIndex) => {
    try {
      if (!paths.length) return;
      const role = productIndex < 0 ? "Product" : "Scene";
      const url = await api("draftAttach", { root, url: urlBox.value.trim(), paths, role, productIndex });
      if (url !== urlBox.value.trim()) urlBox.value = url;
      if (role === "Product") active = Number.MAX_SAFE_INTEGER;
      await refresh();
    } catch (e) { fail(e); }
  };
  const thumb = (path, ok, onRemove, title) => {
    const t = picture();
    Object.assign(t.style, { position: "relative", width: "56px", height: "56px", flex: "none", border: "1px solid var(--line)", background: "var(--smoke)", cursor: "pointer" });
    t.set(ok ? path : "");
    t.title = title;
    t.onclick = () => ok && showImagePreview(path, title);
    t.onRemove(onRemove);
    return t;
  };
  const addTile = (text, onPick) => {
    const tile = el("button", "btn", { type: "button", text });
    Object.assign(tile.style, { position: "static", width: "56px", height: "56px", flex: "none", fontSize: text === "+" ? "20px" : "12px", color: "var(--muted)", borderStyle: "dashed", padding: "0", whiteSpace: "normal" });
    tile.onclick = onPick;
    return tile;
  };
  const refresh = async () => {
    const url = urlBox.value.trim();
    try {
      const info = await api("draftInfo", { root, url });
      products = list(info.products).map((p) => ({ ...p, scenes: list(p.scenes) }));
    } catch { products = []; }
    if (active >= products.length) active = products.length - 1;
    const rows = products.map((p, i) => {
      // Product image, arrow, then its reviews; many reviews wrap onto more lines so the add tiles stay visible.
      const row = el("div", "", { style: { display: "flex", alignItems: "flex-start", gap: "6px", padding: "6px", borderBottom: "1px solid var(--line)" } });
      if (i === active) row.style.background = "var(--hover)";
      const product = p.file
        ? thumb(p.file, p.ok, async () => { await api("draftRemoveProduct", { root, url, productIndex: i }).catch(fail); refresh(); }, `Ảnh gốc #${i + 1}`)
        : el("div", "label muted", { text: "Ảnh từ link", style: { position: "static", width: "56px", whiteSpace: "normal", fontSize: "11px" } });
      const arrow = el("div", "label muted", { text: "→", style: { position: "static", width: "16px", height: "56px", lineHeight: "56px", textAlign: "center", flex: "none" } });
      product.style.flex = "none";
      const reviews = el("div", "", { style: { display: "flex", flexWrap: "wrap", gap: "6px", flex: "1", minWidth: "0" } });
      row.append(product, arrow, reviews);
      reviews.append(...p.scenes.map((s, k) => thumb(s.file, s.ok, async () => {
        await api("draftRemoveScene", { root, url, productIndex: i, index: k }).catch(fail); refresh();
      }, `Ảnh review ${k + 1} · ảnh gốc #${i + 1}`)), addTile("+ Máy", async () => { active = i; attachPaths(await chooseImages(await api("reviewFolder", { group: state.group }).catch(() => "")), i); }),
        addTile("+ Drive", async () => { active = i; attachPaths(await showDrivePicker(), i); }),
        addTile("Dán", () => { active = i; pasteButton(i); }));
      // The row under the pointer receives pasted images.
      const select = () => { if (active !== i) { active = i; for (const [n, r] of [...rowsBox.children].entries()) r.style.background = n === i ? "var(--hover)" : ""; } };
      row.addEventListener("click", select);
      row.addEventListener("mouseenter", select);
      row.addEventListener("dragover", (e) => e.preventDefault());
      row.addEventListener("drop", (e) => { e.preventDefault(); e.stopPropagation(); active = i; attach(e.dataTransfer.files, i); });
      return row;
    });
    const addRow = el("div", "", { style: { display: "flex", alignItems: "center", gap: "8px", padding: "6px" } });
    addRow.append(addTile("+", async () => attachPaths(await chooseImages(""), -1)), addTile("Dán", () => pasteButton(-1)), el("div", "label muted", { text: "Thêm ảnh gốc", style: { position: "static" } }));
    addRow.addEventListener("mouseenter", () => { active = -1; for (const r of rowsBox.children) r.style.background = ""; });
    addRow.addEventListener("dragover", (e) => e.preventDefault());
    addRow.addEventListener("drop", (e) => { e.preventDefault(); e.stopPropagation(); attach(e.dataTransfer.files, -1); });
    rowsBox.replaceChildren(...rows, addRow);
    const reviews = products.reduce((n, p) => n + p.scenes.length, 0);
    const missing = products.filter((p) => !p.scenes.length).length;
    if (!url) { status.textContent = "Chưa có link"; status.style.color = "var(--muted)"; }
    else if (!products.length) { status.textContent = "● Chưa có ảnh"; status.style.color = "var(--warn)"; }
    else if (missing) { status.textContent = `● ${missing} ảnh gốc chưa có ảnh review`; status.style.color = "var(--warn)"; }
    else { status.textContent = `● ${products.length} ảnh gốc · ${reviews} ảnh review → ${reviews} ảnh kết quả`; status.style.color = "var(--ok)"; }
  };
  // Clipboard: an image goes to the active row (or becomes a product image when none); text in the link box stays text.
  // Nút Dán: images from the clipboard (the browser asks once for clipboard access).
  const pasteButton = async (productIndex) => {
    const files = [];
    try {
      for (const item of await navigator.clipboard.read()) {
        const type = item.types.find((t) => /^image\/(png|jpeg)$/.test(t));
        if (type) files.push(new File([await item.getType(type)], type === "image/png" ? "clipboard.png" : "clipboard.jpg", { type }));
      }
    } catch {}
    if (!files.length) return fail(new Error("Clipboard chưa có ảnh."));
    attach(files, productIndex);
  };
  // Cmd/Ctrl+V anywhere while this popup is on top, even before anything in it has focus.
  const onPaste = (e) => {
    if (stack.at(-1) !== view) return;
    const files = imageFiles(e.clipboardData?.files || []);
    if (!files.length) return;
    e.preventDefault();
    attach(files, products.length && active >= 0 ? Math.min(active, products.length - 1) : -1);
  };
  document.addEventListener("paste", onPaste);
  rowsBox.addEventListener("dragover", (e) => e.preventDefault());
  rowsBox.addEventListener("drop", (e) => { e.preventDefault(); attach(e.dataTransfer.files, -1); });
  urlBox.oninput = () => { active = -1; refresh(); };
  save.onclick = async () => {
    try {
      const url = urlBox.value.trim();
      const others = state.rows.filter((r) => r !== target).map((r) => r.url.trim());
      const entry = normInfo(await api("draftSave", { root, url, others, group: state.group }));
      saved = true;
      if (target) Object.assign(target, { url, info: entry });
      else state.rows.push({ url, info: entry });
      view.close();
      renderRows();
      updateStatus();
      persist();
      if (!target) ui.flow.scrollTop = ui.flow.scrollHeight;
    } catch (e) { fail(e); }
  };
  await refresh();
  urlBox.focus();
}

// ----- Nhập hàng loạt (Show-ProductQueueBulkDialog): plain links join the list at once; a table (docs/import.md)
// runs src/import-batch.ps1 in the background, which downloads and attaches the images -----
const IMPORT_GUIDE = "https://hoangpham.is-a.dev/tools-hub/#nhap";
async function addLinks(urls) {
  const added = [];
  for (const url of urls) {
    const known = state.rows.find((r) => r.url.trim() === url);
    if (known) { added.push(known); continue; }
    const empty = state.rows.find((r) => !r.url.trim());
    if (empty) { empty.url = url; added.push(empty); } else { const row = { url, info: null }; state.rows.push(row); added.push(row); }
  }
  const infos = list(await api("rows", { urls: added.map((r) => r.url) }));
  added.forEach((r, i) => { r.info = normInfo(infos[i]); });
  renderRows();
  persist();
  updateStatus();
}
function showBulkDialog() {
  const view = openWindow("Nhập hàng loạt", 760, 480);
  const hint = at(label("Dán link (mỗi dòng một link), hoặc kéo thả thư mục product-import hay file nén của nó (hoặc bấm Chọn file… và chọn products.csv) để app gắn ảnh."), 16, 14, 728, 40);
  hint.style.whiteSpace = "normal";
  const guide = at(el("a", "label link", { text: "Xem chuẩn file nhập", href: IMPORT_GUIDE, target: "_blank" }), 16, 58, 200, 30);
  Object.assign(guide.style, { display: "flex", alignItems: "center" });
  const pick = at(button("Chọn file…"), 634, 58, 110, 30);
  const text = at(el("textarea", "text mono"), 16, 96, 728, 262);
  text.wrap = "off";
  const bar = at(el("div", "progress marquee"), 16, 368, 728, 6);
  bar.append(el("span"));
  bar.hidden = true;
  const status = at(label(""), 16, 380, 728, 48);
  status.style.whiteSpace = "pre-line";
  const save = at(button("Nhập", true), 520, 436, 110, 32);
  const cancel = at(button("Hủy"), 640, 436, 104, 32);
  view.body.append(hint, guide, pick, text, bar, status, save, cancel);
  let timer = null, folder = "";
  const fail = (message) => { status.style.color = "var(--error)"; status.textContent = message; };
  const busy = (on) => { text.readOnly = on; save.disabled = on; pick.disabled = on; bar.hidden = !on; };
  pick.onclick = async () => {
    try {
      const [path] = await chooseImages("", true);
      if (!path) return;
      if (/\.(zip|rar|7z)$/i.test(path)) {
        const r = await api("importArchive", { path });
        text.value = r.text; folder = r.folder;
      } else {
        text.value = await api("importFile", { path });
        folder = path.slice(0, path.lastIndexOf("/"));
      }
      status.style.color = ""; status.textContent = "";
    } catch (err) { fail(err.message); }
  };
  // Kéo thả the product-import folder: products.csv is read here, the images/ files are copied for the import.
  const entries = (dir) => new Promise((done) => { const all = [], r = dir.createReader(); const next = () => r.readEntries((b) => b.length ? (all.push(...b), next()) : done(all)); next(); });
  const fileOf = (entry) => new Promise((done, failed) => entry.file(done, failed));
  view.body.addEventListener("dragover", (e) => { e.preventDefault(); view.body.classList.add("dropping"); });
  view.body.addEventListener("dragleave", (e) => { if (!view.body.contains(e.relatedTarget)) view.body.classList.remove("dropping"); });
  view.body.addEventListener("drop", async (e) => {
    e.preventDefault(); view.body.classList.remove("dropping");
    if (save.disabled) return;
    const dropped = [...e.dataTransfer.items].map((i) => i.webkitGetAsEntry?.());
    const zip = dropped.find((x) => x?.isFile && /\.(zip|rar|7z)$/i.test(x.name));
    if (zip) {
      // A packed product-import folder (.zip like the sample, .rar, .7z): unpacked by the app, then read like the folder.
      try {
        status.style.color = ""; status.textContent = "Đang giải nén…";
        const up = await fetch(`/api/upload?import=${Date.now().toString(36)}&name=${encodeURIComponent(zip.name)}`, { method: "POST", body: await fileOf(zip) }).then((x) => x.json());
        if (!up.path) throw new Error(up.error || "Chưa nhận được file nén.");
        const r = await api("importArchive", { path: up.path });
        text.value = r.text; folder = r.folder;
        status.textContent = `Đã nhận ${zip.name}. Bấm Nhập.`;
      } catch (err) { fail(err.message); }
      return;
    }
    const root = dropped.find((x) => x?.isDirectory);
    if (!root) return fail("Kéo thư mục (có products.csv và images/) hoặc file nén (.zip, .rar, .7z) của nó vào đây.");
    try {
      const top = await entries(root);
      const csv = top.find((x) => x.isFile && /\.csv$/i.test(x.name));
      if (!csv) throw new Error("Thư mục chưa có products.csv.");
      const images = top.find((x) => x.isDirectory && x.name === "images");
      const files = images ? (await entries(images)).filter((x) => x.isFile && /\.(jpe?g|png)$/i.test(x.name)) : [];
      if (!files.length) throw new Error("Thư mục images/ chưa có ảnh JPG/PNG.");
      const id = Date.now().toString(36);
      status.style.color = ""; folder = "";
      for (let i = 0; i < files.length; i++) {
        status.textContent = `Đang chép ảnh ${i + 1}/${files.length}…`;
        const r = await fetch(`/api/upload?import=${id}&name=${encodeURIComponent(files[i].name)}`, { method: "POST", body: await fileOf(files[i]) }).then((x) => x.json());
        folder = r.folder;
      }
      text.value = await (await fileOf(csv)).text();
      status.textContent = `Đã nhận ${root.name}: ${files.length} ảnh. Bấm Nhập.`;
    } catch (err) { fail(err.message); }
  });
  const finish = async (s) => {
    clearInterval(timer); timer = null; busy(false); cancel.textContent = "Đóng";
    if (!s) return fail("Chưa nhập được. Thử lại hoặc bấm Gửi lỗi.");
    if (s.errors?.length) return fail(s.errors.slice(0, 3).join("\n"));
    await addLinks(list(s.links));
    const summary = `Đã nhập ${list(s.links).length} link, ${s.products} ảnh gốc, ${s.reviews} ảnh review.`;
    const failed = list(s.failed);
    if (!failed.length) { view.close(); return; }
    fail(`${summary} Lỗi ${failed.length} ảnh:\n` + failed.slice(0, 2).map((f) => `Dòng ${f.line}: ${f.reason}`).join("; "));
    text.value = ["# Ảnh chưa nhập được (sửa rồi nhập lại các dòng này):", ...failed.map((f) => `# Dòng ${f.line}: ${f.image} - ${f.reason}`)].join("\n");
  };
  save.onclick = async () => {
    status.style.color = ""; status.textContent = "";
    try {
      if (!text.value.trim()) throw new Error("Dán link hoặc bảng nhập trước.");
      const parsed = await api("importParse", { text: text.value, folder });
      if (list(parsed.errors).length) throw new Error(list(parsed.errors).slice(0, 3).join("\n"));
      if (!parsed.images) { await addLinks(list(parsed.links)); view.close(); return; }
      const r = await fetch("/api/import", { method: "POST", body: JSON.stringify({ text: text.value, folder }) });
      if (!r.ok) throw new Error((await r.json()).error);
      busy(true);
      bar.classList.add("marquee");
      status.textContent = "Đang gắn ảnh…";
      timer = setInterval(async () => {
        const { running, status: s } = await (await fetch("/api/import")).json();
        if (s?.total) { bar.classList.remove("marquee"); bar.firstChild.style.width = `${Math.round((100 * s.done) / s.total)}%`; status.textContent = `Đang gắn ảnh ${s.done}/${s.total}…`; }
        if (!running && timer) finish(s);
      }, 600);
    } catch (e) { fail(e.message); }
  };
  // Hủy while importing stops it; images already attached stay on their links.
  view.cancel = cancel.onclick = async () => {
    if (timer) { await fetch("/api/import", { method: "DELETE" }); clearInterval(timer); timer = null; }
    view.close();
  };
  text.focus();
}

// ----- Duyệt kết quả (New-BatchReviewDialog) -----
async function showReviewDialog() {
  const view = openWindow("Duyệt kết quả", 924, 721);
  const b = view.body;
  const batches = at(combo(), 12, 12, 600, 24);
  const hint = at(label("Mỗi dòng một đánh giá. Bấm ảnh để xem lớn; Giữ/Bỏ chỉ áp dụng cho dòng đó.", "muted"), 12, 46, 900, 22);
  const flow = at(el("div", "flow"), 12, 72, null, null, { right: 12, bottom: 69 });
  const status = at(label(""), 12, null, 560, 36, { bottom: 17, top: false });
  status.style.lineHeight = "36px";
  const exportBtn = at(button("Xuất file Loox", true), null, null, 180, 40, { right: 12, left: false, bottom: 17, top: false });
  exportBtn.disabled = true;
  b.append(batches, hint, flow, status, exportBtn);
  let items = [], batch = "";
  const refresh = () => {
    const done = items.filter((i) => i.decision).length, good = items.filter((i) => i.decision === "ok").length;
    status.textContent = `Đã duyệt ${done}/${items.length} đánh giá • Giữ ${good} • Bỏ ${done - good}`;
    exportBtn.disabled = !(items.length > 0 && done === items.length && good > 0);
  };
  const decideFor = (item, paint) => async (value) => {
    const next = item.decision === value ? "" : value;
    let reason = "";
    if (next === "bad") { reason = await askReason("Bỏ đánh giá"); if (reason === null) return; }
    await api("reviewDecide", { batch, id: item.id, decision: next, reason });
    item.decision = next;
    paint();
    refresh();
  };
  const load = async () => {
    batch = batches.value;
    items = batch ? list(await api("reviewItems", { batch })) : [];
    const width = Math.max(840, flow.clientWidth - 28);
    flow.replaceChildren(...items.map((item, n) => {
      const row = el("div", "rrow", { style: { width: width + "px" } });
      const thumb = at(picture(), 8, 7, 48, 48);
      thumb.style.background = "var(--smoke)";
      thumb.style.cursor = "pointer";
      thumb.set(item.image);
      const title = at(label(`#${n + 1} · ${item.handle}`), 68, 5, width - 240, 20);
      const bodyText = at(label(item.body, "muted"), 68, 28, width - 240, 24);
      const ok = at(button("Giữ"), width - 152, 17, 64, 28), bad = at(button("Bỏ"), width - 80, 17, 64, 28);
      const paint = () => {
        ok.classList.toggle("primary", item.decision === "ok");
        bad.classList.toggle("flat-error", item.decision === "bad");
        row.classList.toggle("ok", item.decision === "ok");
        row.classList.toggle("bad", item.decision === "bad");
      };
      const decide = decideFor(item, paint);
      ok.onclick = () => decide("ok");
      bad.onclick = () => decide("bad");
      thumb.onclick = () => showReviewPreview(item, decide);
      paint();
      row.append(thumb, title, bodyText, ok, bad);
      return row;
    }));
    refresh();
  };
  batches.onchange = load;
  // Export shows its progress on the button itself; no extra message windows.
  exportBtn.onclick = async () => {
    exportBtn.disabled = true; exportBtn.textContent = "Đang xuất…";
    try {
      await api("reviewExport", { batch });
      exportBtn.textContent = "✓ Đã xuất";
      const option = batches.selectedOptions[0];
      if (option && !option.textContent.endsWith("đã xuất")) option.textContent += "  • đã xuất";
      setTimeout(() => { exportBtn.textContent = "Xuất file Loox"; refresh(); }, 2000);
    } catch (e) { status.textContent = e.message; exportBtn.textContent = "Xuất file Loox"; refresh(); }
  };
  const all = list(await api("reviewBatches"));
  batches.setItems(all.map((x) => x.path), all.map((x) => x.label));
  if (all.some((x) => x.path === run.resultFolder)) batches.value = run.resultFolder;
  if (!all.length) status.textContent = "Chưa có lần chạy nào để duyệt. Lần chạy tạo ra ảnh sẽ hiện ở đây.";
  else await load();
  return new Promise((resolve) => { view.onClose = resolve; });
}

function showReviewPreview(item, decide) {
  const view = openWindow("Xem ảnh đánh giá", 1080, 720);
  const b = view.body;
  // Left: the product photo above the review photo the image was made from; right: the result.
  const original = at(label("Ảnh sản phẩm gốc"), 12, 12, 500, 24);
  const product = at(picture(), 12, 42, 522, 250);
  const sceneLabel = at(label("Ảnh review ban đầu"), 12, 296, 500, 22);
  const scene = at(picture(), 12, 322, 522, 250);
  const result = at(picture(), 546, 42, 522, 530);
  for (const p of [product, scene, result]) p.style.background = "var(--smoke)";
  product.set(item.product);
  scene.set(item.scene);
  result.set(item.image);
  if (!item.product) original.textContent = "Ảnh sản phẩm gốc · không có";
  if (!item.scene) sceneLabel.textContent = "Ảnh review ban đầu · không có";
  const body = at(el("textarea", "text", { readOnly: true, value: item.body }), 12, 584, 1056, 70);
  const state_ = at(label(""), 12, 674, 540, 28);
  // Giữ or Bỏ decides and closes the window, so there is no separate Đóng; Esc closes without deciding.
  const keep = at(button("Giữ đánh giá"), 796, 670, 130, 36), skip = at(button("Bỏ đánh giá"), 938, 670, 130, 36);
  state_.textContent = { ok: "Đang giữ đánh giá này", bad: "Đang bỏ đánh giá này khỏi CSV" }[item.decision] || "Chưa chọn giữ hoặc bỏ";
  keep.onclick = async () => { await decide("ok"); view.close(); };
  skip.onclick = async () => { await decide("bad"); view.close(); };
  b.append(original, at(label("Ảnh kết quả"), 548, 12, 500, 24), product, sceneLabel, scene, result, body, state_, keep, skip);
}

// ----- Cấu hình: the hub's page (hub/setup/page.html), shared with the menu; "← Quay lại" comes back here -----
function showSetupDialog() { location.href = `/setup?back=${encodeURIComponent(location.pathname + location.search)}`; }

// ----- Cập nhật (Show-UpdateDialog): check, then download and install with a running bar -----
function showUpdateDialog() {
  const view = openWindow("Cập nhật", 440, 168);
  const status = at(label(""), 20, 20, 400, 44);
  status.style.whiteSpace = "normal";
  const bar = at(el("div", "progress marquee"), 20, 72, 400, 10);
  bar.append(el("span"));
  const go = at(button("Cập nhật", true), 220, 112, 100, 32), close = at(button("Đóng"), 330, 112, 90, 32);
  go.hidden = true;
  close.onclick = () => { if (!close.disabled) view.close(); };
  view.cancel = close.onclick;
  view.body.append(status, bar, go, close);
  const current = state.version || "bản hiện tại";
  let next = "";
  const check = async () => {
    status.textContent = "Đang kiểm tra bản mới…";
    bar.hidden = false; go.hidden = true;
    try { next = await api("updateCheck"); }
    catch { bar.hidden = true; status.textContent = "Không kiểm tra được bản mới. Kiểm tra mạng rồi thử lại."; return; }
    bar.hidden = true;
    if (!next) { status.textContent = `Đang dùng bản mới nhất (${current}).`; return; }
    status.textContent = `Có phiên bản mới ${next} (đang dùng ${current}).`;
    go.hidden = false; go.focus();
  };
  // The server replaces the files, restarts on them, and the page reloads once it answers again.
  go.onclick = async () => {
    status.textContent = `Đang tải và cài phiên bản ${next}…`;
    bar.hidden = false; go.hidden = true; close.disabled = true;
    const r = await fetch("/api/update", { method: "POST" }).catch(() => null);
    if (!r || !r.ok) {
      bar.hidden = true; close.disabled = false; go.textContent = "Thử lại"; go.hidden = false;
      status.textContent = "Chưa cập nhật được. Kiểm tra mạng rồi thử lại.";
      return;
    }
    status.textContent = "Đã cập nhật. Đang mở lại app…";
    const wait = () => fetch("/api/rpc", { method: "POST", body: JSON.stringify({ cmd: "state", args: {} }) })
      .then((x) => (x.ok ? location.reload() : setTimeout(wait, 500))).catch(() => setTimeout(wait, 500));
    setTimeout(wait, 800);
  };
  check();
}

// ----- run (Start-GuiBatch, timer ticks) -----
const actionLocks = new Set();
function updateActionAvailability() {
  const busy = run.active || actionLocks.size > 0 || stack.length > 0;
  for (const b of [ui.btnRun, ui.btnSetup, ui.btnLogs, ui.btnReview, ui.btnOut, ui.btnUpdate, ui.btnClearLog, ui.btnAdd, ui.btnBulk, ui.btnClear]) b.disabled = busy;
  ui.btnStop.disabled = !run.active;
  ui.numThr.enabled = !busy;
  ui.cmbBackend.disabled = ui.cmbText.disabled = busy;
  ui.flow.style.pointerEvents = busy ? "none" : "";
}
function setActionBusy(reason, on) {
  if (on) actionLocks.add(reason); else actionLocks.delete(reason);
  updateActionAvailability();
}
function setRunning(on) {
  run.active = on;
  updateActionAvailability();
}
function updateRunDisplay() {
  if (!run.active) return;
  const elapsed = Math.floor((Date.now() - run.started) / 1000);
  const time = `${String(Math.floor(elapsed / 60)).padStart(2, "0")}:${String(elapsed % 60).padStart(2, "0")}`;
  let activity = [...run.stages].filter(([, v]) => !["Đã xong", "Chưa hoàn tất"].includes(v)).sort((a, b) => a[0] - b[0]).map(([k, v]) => `SP ${k}: ${v}`);
  if (run.stage === "Đang lưu kết quả" || !activity.length) activity = [run.stage];
  ui.lblProgress.textContent = `${run.done}/${run.total} ảnh đã xong  •  ${activity.join("  |  ")}  •  ${time}  •  ${run.ai}`;
  // Each job's live stage on its queue row (a link with several images runs several jobs).
  for (const [key, value] of run.stages) {
    const i = run.jobRows.length >= key ? run.jobRows[key - 1] - 1 : key - 1;
    const row = state.rows[i];
    if (!row) continue;
    const done = value === "Đã xong";
    row.stage = { text: done ? "✔ Đã xong" : `◔ ${value}`, color: done ? "var(--ok)" : "var(--accent)" };
  }
  // Only the status labels change during a run; a row drawn before the run started is rebuilt once.
  if (state.rows.some((row) => !statusOf.get(row)?.isConnected)) return renderRows();
  for (const row of state.rows) {
    const status = statusOf.get(row), st = row.stage || rowStatus(row);
    if (status.textContent !== st.text) status.textContent = st.text;
    status.style.color = st.color;
  }
}
const usage = { quota: "Hạn mức: đang lấy…", at: 0, reading: false };
const formatCount = (n) => Number(n).toLocaleString("vi-VN");
// Web AIs and Antigravity report no tokens: each finished call is counted instead ([AI-CALL]), and their limits are
// the Google account's own, shown on their sites. Codex's tokens and quota only show when Codex is used.
const CALL_NAMES = { gemini: ["Gemini web", "lượt"], antigravity: ["Antigravity", "lượt"], flow: ["Flow", "ảnh"] };
const LIMIT_NAMES = { gemini: "lượt Gemini", antigravity: "hạn mức Antigravity", flow: "credit Flow" };
function updateUsage() {
  if (!ui.lblTokens || !ui.cmbText) return;
  const t = run.tokens || { in: 0, cached: 0, out: 0 };
  const [text, image] = run.active ? [run.text, run.image] : [ui.cmbText.value, ui.cmbBackend.value];
  const usesCodex = text === "codex" || image === "codex";
  const parts = Object.entries(run.calls || {}).map(([k, n]) => `${(CALL_NAMES[k] || [k])[0]}: ${formatCount(n)} ${(CALL_NAMES[k] || [, "lượt"])[1]}`);
  if (t.in || t.out) parts.unshift(`Token: ${formatCount(t.in + t.out)} · vào ${formatCount(t.in)} · ra ${formatCount(t.out)}`);
  ui.lblTokens.textContent = parts.length ? parts.join(" · ") : usesCodex ? "Token: chưa chạy" : "Lượt AI: chưa chạy";
  const web = [...new Set([text, image])].filter((k) => LIMIT_NAMES[k]).map((k) => LIMIT_NAMES[k]);
  const webText = web.length ? `${web.join(", ")} theo tài khoản Google` : "";
  ui.lblQuota.textContent = !usesCodex ? `Hạn mức: ${webText}, xem trên trang của AI` : web.length ? `${usage.quota} · ${webText}` : usage.quota;
  // Cut with … in a narrow window: the whole line shows on hover.
  for (const l of [ui.lblTokens, ui.lblQuota]) l.title = l.textContent;
}
// Quota beside the run, kept current: read when the window opens, every minute, after each run and, while a run
// goes, after calls that used tokens.
async function refreshQuota() {
  if (usage.reading) return;
  usage.reading = true;
  const text = await api("quotaSummary").catch(() => "");
  Object.assign(usage, { reading: false, at: Date.now() });
  if (text) { usage.quota = text; updateUsage(); }
}

function receive(event) {
  switch (event.Kind) {
    case "Start": run.total = event.Total; break;
    case "Output": run.resultFolder = event.Path; break;
    case "Rows": run.jobRows = list(event.Rows); break;
    case "Item": run.index = event.Index; run.stages.set(event.Index, event.Stage); break;
    case "Stage": run.stages.set(event.Index, event.Stage); run.stage = event.Stage; break;
    case "Retry": run.stages.set(event.Index, event.Stage); break;
    case "Saving": run.stage = event.Stage; break;
    case "Completed": if (run.stages.get(event.Index) !== "Đã xong") run.done++; run.stages.set(event.Index, event.Stage); break;
    case "Failed": run.stages.set(event.Index, event.Stage); run.failure = true; break;
    case "Warning": run.failure = true; break;
    case "Call": run.calls[event.Backend] = (run.calls[event.Backend] || 0) + 1; updateUsage(); break;
    case "Tokens":
      run.tokens.in += event.TokensIn; run.tokens.cached += event.TokensCached; run.tokens.out += event.TokensOut; updateUsage();
      // Quota follows the run: re-read it after a call used tokens, at most every 15 seconds.
      if (!usage.reading && Date.now() - usage.at >= 15000) refreshQuota();
      break;
  }
  if (event.Text) appendLog(event.Text);
}
async function startBatch() {
  if (run.active) return;
  if (!state.drive) return appendLog("Nhập mật khẩu app trước khi chạy (Cấu hình).");
  try { await saveQueue(true); } catch (e) { return appendLog(e.message); }
  if (!countUrls()) return messageBox("Vui lòng thêm ít nhất một link sản phẩm.");
  if (!state.codex) return messageBox('Chưa có công cụ xử lý. Bấm "Cấu hình" để xem hướng dẫn.');
  ui.txtLog.value = "";
  Object.assign(run, { since: 0, total: countUrls(), done: 0, index: 0, stages: new Map(), jobRows: [], stage: "Đang chuẩn bị", stopped: false, failure: false, started: Date.now(), resultFolder: "", tokens: { in: 0, cached: 0, out: 0 }, calls: {} });
  updateUsage();
  for (const r of state.rows) r.stage = null;
  await updateReviewButton();
  // The AIs chosen are the only ones used: nothing falls back to Codex without asking (finish()).
  Object.assign(run, { text: ui.cmbText.value, image: ui.cmbBackend.value });
  // Shown on the progress line for the whole run: which AI writes, which one draws.
  run.ai = `Viết review: ${ui.cmbText.selectedOptions[0]?.text} · Tạo ảnh: ${ui.cmbBackend.selectedOptions[0]?.text}`;
  const r = await fetch("/api/run", { method: "POST", body: JSON.stringify({ threads: ui.numThr.value, backend: run.image, text: run.text }) });
  if (!r.ok) {
    const body = await r.json().catch(() => ({}));
    return appendLog("Chưa khởi động được lượt xử lý: " + (body.error || r.status));
  }
  setRunning(true);
  setStatus("Đang chạy", "var(--primary)");
  setBar(0, 1, true);
  updateRunDisplay();
  poll();
}
async function poll() {
  if (!run.active) return;
  try {
    const r = await (await fetch(`/api/run?since=${run.since}`)).json();
    for (const event of r.events) receive(event);
    run.since = r.next;
    if (r.resultFolder) run.resultFolder = r.resultFolder;
    updateRunDisplay();
    if (r.done && !r.running) return finish(r);
  } catch {}
  setTimeout(poll, 700);
}
async function finish(r) {
  setRunning(false);
  setBar(run.done, Math.max(1, run.total));
  for (const row of state.rows) row.stage = null;
  // Finished links leave the queue during the run; their images go too, so the list starts clean.
  await api("pruneMap").catch(() => {});
  await loadState();
  refreshQuota();
  const elapsed = Math.floor((Date.now() - run.started) / 1000);
  ui.lblProgress.textContent = `Đã xong ${run.done}/${run.total} ảnh • ${Math.floor(elapsed / 60)} phút ${elapsed % 60} giây • ${run.ai}`;
  if (r.stopped) { setStatus("Đã dừng", "var(--muted)"); appendLog("Đã dừng. Các link chưa hoàn tất được giữ lại."); }
  else if (r.exitCode === 0 && !run.failure) {
    setStatus("✔ Hoàn tất", "var(--ok)");
    appendLog("Xong. Bấm Duyệt & xuất file để duyệt từng ảnh; file Loox chỉ tạo khi duyệt xong.");
  } else {
    setStatus("! Cần thử lại", "var(--warn)");
    appendLog("Một số sản phẩm chưa hoàn tất. Bạn có thể bấm Bắt đầu để thử lại các link còn lại, hoặc Duyệt & xuất file với các ảnh đã xong.");
    appendLog("Nếu lỗi lặp lại, bấm Gửi lỗi để admin kiểm tra.");
  }
  await updateReviewButton();
  // Another AI was chosen and some links failed: Codex is the steady one, but only on the user's yes, and only for
  // this retry (the choices shown go back to theirs next time).
  const others = [run.text !== "codex" && ui.cmbText.selectedOptions[0]?.text, run.image !== "codex" && ui.cmbBackend.selectedOptions[0]?.text].filter(Boolean);
  if (!r.stopped && (r.exitCode !== 0 || run.failure) && others.length && countUrls()) {
    const answer = await messageBox(`Một số sản phẩm chưa xong với ${others.join(" và ")}. Chạy lại các link còn lại bằng Codex?`, "Chạy lại bằng Codex", ["Yes", "No"], { Yes: "Chạy bằng Codex", No: "Không" });
    if (answer === "Yes") {
      if (run.text !== "codex") ui.cmbText.value = "codex";
      if (run.image !== "codex") ui.cmbBackend.value = "codex";
      startBatch();
    }
  }
}
// Running animation only in the status label.
setInterval(() => { if (run.active && !run.stopped) { run.anim = (run.anim + 1) % 3; setStatus("Đang chạy " + [".", "..", "..."][run.anim], "var(--accent)"); } }, 350);

// ---------- wiring ----------
function wire() {
  ui.btnAdd.onclick = () => showProductDialog();
  ui.btnBulk.onclick = showBulkDialog;
  ui.btnClear.onclick = () => { if (run.active) return; state.rows = []; renderRows(); updateStatus(); persist(); };
  // Gửi lỗi: src/support-report.mjs runs in the background; each step shows on the button and in the log.
  ui.btnLogs.onclick = async () => {
    const rejected = await api("rejectedCount").catch(() => 0);
    const question = "Gửi lỗi cho admin?\n\n" + (rejected ? `Gồm các lỗi từ lần gửi trước và ${rejected} đánh giá đã Bỏ (kèm lý do).` : "Gồm các lỗi từ lần gửi trước.") + " Không gửi ảnh hay mật khẩu.";
    if ((await messageBox(question, "Gửi lỗi", ["Yes", "No"])) !== "Yes") return;
    setActionBusy("report", true); ui.btnLogs.textContent = "Đang gửi lỗi…";
    const reset = () => setTimeout(() => { ui.btnLogs.textContent = "Gửi lỗi"; setActionBusy("report", false); }, 2500);
    if (!(await fetch("/api/send-errors", { method: "POST" }).then((r) => r.ok).catch(() => false))) { appendLog("Chưa gửi lỗi được, thử lại sau."); return reset(); }
    let shown = "";
    const timer = setInterval(async () => {
      const { running, last } = await fetch("/api/send-errors").then((r) => r.json()).catch(() => ({ running: true, last: "" }));
      const [kind, a = "", b = ""] = last.split("|");
      if (kind === "step" && a !== shown) { shown = a; appendLog(a); }
      if (running) return;
      clearInterval(timer);
      if (kind === "sent") { ui.btnLogs.textContent = "✓ Đã gửi"; appendLog(`Đã gửi lỗi: ${a}${Number(b) ? ` (kèm ${b} đánh giá đã Bỏ)` : ""}`); }
      else if (kind === "saved") { ui.btnLogs.textContent = "Gửi lỗi"; appendLog(`Chưa gửi được (${b || "không rõ lý do"}); file lỗi ở: ${a}`); api("revealPath", { path: a }); }
      else { ui.btnLogs.textContent = "Gửi lỗi"; appendLog(kind === "error" ? `Chưa tạo được báo cáo AI: ${a}` : "Tiến trình dừng không trả kết quả; xem log gửi lỗi."); }
      reset();
    }, 700);
  };
  ui.btnClearLog.onclick = () => { ui.txtLog.value = ""; };
  ui.btnOut.onclick = () => api("openPath", { path: run.resultFolder || state.output });
  ui.btnReview.onclick = async () => { if (!run.active) { await showReviewDialog(); updateReviewButton(); } };
  ui.btnSetup.onclick = showSetupDialog;
  ui.btnUpdate.onclick = () => (run.active ? messageBox("Đang xử lý sản phẩm. Chờ chạy xong rồi cập nhật.", "Cập nhật") : showUpdateDialog());

  ui.btnRun.onclick = () => startBatch();
  ui.btnReload.onclick = async () => {
    if (run.active) return messageBox("Đang chạy. Dừng hoặc chờ xong rồi tải lại.");
    ui.btnReload.disabled = true;
    ui.btnReload.textContent = "Đang tải…";
    const r = await fetch("/api/reload", { method: "POST" }).catch(() => null);
    if (!r || !r.ok) return location.reload();
    const wait = () => fetch("/api/rpc", { method: "POST", body: JSON.stringify({ cmd: "state", args: {} }) })
      .then((x) => (x.ok ? location.reload() : setTimeout(wait, 400))).catch(() => setTimeout(wait, 400));
    setTimeout(wait, 900);
  };
  ui.btnStop.onclick = async () => { if (run.active) { run.stopped = true; await fetch("/api/stop", { method: "POST" }); setStatus("Đang dừng...", "var(--accent)"); } };
  addEventListener("beforeunload", (e) => { if (run.active) { e.preventDefault(); e.returnValue = ""; } });
  addEventListener("resize", () => renderRows());
}

// A newer release shows on the button, green with its version, without updating anything: checked a few
// seconds after the window opens and every 6 hours.
async function checkUpdate() {
  const next = await api("updateCheck").catch(() => null);
  if (next === null) return;
  ui.btnUpdate.textContent = next ? `Cập nhật ${next}` : "Cập nhật";
  ui.btnUpdate.style.width = next ? "150px" : "100px";
  ui.btnUpdate.classList.toggle("primary", !!next);
  placeSync();
}

// Cấu hình sits 8px left of the update button and the sync line ends 12px before it, however wide the button is.
function placeSync() {
  ui.btnSetup.style.right = `${24 + ui.btnUpdate.offsetWidth + 8}px`;
  const right = `${24 + ui.btnUpdate.offsetWidth + 8 + ui.btnSetup.offsetWidth + 12}px`;
  ui.syncLabel.style.right = ui.syncBar.style.right = right;
}
const syncView = { timer: 0, hide: 0 };
// Starts Tải về máy for these danh mục; false when one is already running.
async function startSync(names) {
  const r = await fetch("/api/sync", { method: "POST", body: JSON.stringify({ groups: names }) }).catch(() => null);
  if (!r || !r.ok) return false;
  setActionBusy("sync", true);
  clearTimeout(syncView.hide);
  Object.assign(ui.syncLabel.style, { color: "" });
  ui.syncLabel.textContent = "⟳ Đang tải về máy…"; ui.syncLabel.hidden = false;
  ui.syncBar.firstChild.style.width = "0%"; ui.syncBar.hidden = false;
  pollSync();
  return true;
}
async function pollSync() {
  clearTimeout(syncView.timer);
  const r = await fetch("/api/sync").then((response) => response.json()).catch(() => null);
  if (!r) { syncView.timer = setTimeout(pollSync, 1500); return; }
  const s = r.status;
  setActionBusy("sync", !!r.running);
  if (r.running) {
    if (s && !s.finished) {
      const where = s.groups.length > 1 ? `${s.group} (${s.index}/${s.groups.length})` : s.group;
      ui.syncLabel.textContent = `⟳ Đang tải về máy: ${where} · ${formatCount(s.done)}/${formatCount(s.missing)} ảnh`;
      ui.syncBar.firstChild.style.width = `${s.missing ? Math.round((100 * s.done) / s.missing) : 0}%`;
    }
    ui.syncLabel.hidden = ui.syncBar.hidden = false;
    syncView.timer = setTimeout(pollSync, 700);
    return;
  }
  if (ui.syncLabel.hidden || !s) return;
  ui.syncBar.hidden = true;
  const ok = s.groups.length - s.failed.length, failed = list(s.failed);
  ui.syncLabel.textContent = ok
    ? `✓ Đã tải về máy ${s.groups.length > 1 ? `${ok} danh mục` : s.group}: ${formatCount(s.total)} ảnh (vừa tải ${formatCount(s.downloaded)})${failed.length ? ` · chưa tải được: ${failed.join(", ")}` : ""}`
    : `Chưa tải được về máy: ${failed.join(", ")}. Kiểm tra mạng và mật khẩu app.`;
  ui.syncLabel.style.color = failed.length ? "var(--error)" : "var(--ok)";
  syncView.hide = setTimeout(() => { ui.syncLabel.hidden = true; }, 12000);
}

buildMain();
wire();
loadState().catch((e) => appendLog(e.message));
setTimeout(checkUpdate, 3000);
placeSync();
fetch("/api/sync").then((r) => r.json()).then((r) => { if (r.running) { ui.syncLabel.hidden = false; pollSync(); } }).catch(() => {});
updateUsage();
setTimeout(refreshQuota, 2000);
setInterval(refreshQuota, 60 * 1000);
setInterval(checkUpdate, 6 * 3600 * 1000);
