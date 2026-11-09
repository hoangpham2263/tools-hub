// Tools Hub API — Product Review's routes: stores generated images in a private Google Drive folder and serves
// them through stable public links for the review CSV. Same pattern as memories-api:
// refresh token in KV, drive.file scope, admin password header for writes.
import { handleReview, reviewFile } from "./video-editing.js";

const ORIGINS = ["https://hoangpham.is-a.dev", "http://localhost:8000", "http://127.0.0.1:8000"];
const SCOPE = "openid email https://www.googleapis.com/auth/drive.file";
const OWNER_EMAILS = ["quochoang.idx@gmail.com", "hoangpham2263@gmail.com"];
// Drive layout: "Tools Hub/" holds one folder per tool. "Tools Hub/Product Review/" holds "Ảnh đã tạo/<run>/",
// "Nguồn ảnh/<group>/" and "Logs/"; "Tools Hub/Content MXH/Ảnh đã tạo/<run>/<product>/" holds that tool's results; "Tools Hub/Grok Video Prompt/Video mẫu/<6s|10s|15s>/<prompt code>.mp4" holds
// one sample video per prompt.
const HUB_FOLDER = "Tools Hub";
const FOLDER_NAME = "Product Review";
const OLD_FOLDER_NAME = "Product Image Batch";
const RUNS_FOLDER = "Ảnh đã tạo";
const LIST_KEY = "images";
const STATUSES = ["awaiting_review", "accepted", "rejected"];

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8", ...headers } });

function cors(req) {
  const origin = req.headers.get("origin") || "";
  return {
    "access-control-allow-origin": ORIGINS.includes(origin) ? origin : ORIGINS[0],
    "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    "access-control-allow-headers": "content-type, x-admin-key",
    vary: "origin",
  };
}

export function sameKey(a = "", b = "") {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
const isAdmin = (req, env) => !!env.ADMIN_PASSWORD && sameKey(req.headers.get("x-admin-key") || "", env.ADMIN_PASSWORD);
// Two passwords: ADMIN_PASSWORD signs in to the management page; APP_PASSWORD is typed into the desktop
// app and only reaches what the app needs, so sharing the app never exposes the management page.
// A temporary key (made on the API page, hub_tmp_…) lets an AI add images to the library until it expires.
const keyRole = async (req, env) => {
  if (isAdmin(req, env)) return "admin";
  const key = req.headers.get("x-admin-key") || "";
  if (env.APP_PASSWORD && sameKey(key, env.APP_PASSWORD)) return "app";
  if (isTempKey(key)) {
    const hash = await sha256(key);
    if ((await readTempKeys(env)).some((k) => k.hash === hash)) return "upload";
  }
  return "";
};
const TEMP_PREFIX = "hub_tmp_";
// Keys made before the rename (prb_tmp_…) keep working until they expire.
const isTempKey = (key) => key.startsWith(TEMP_PREFIX) || key.startsWith("prb_tmp_");
const TEMP_HOURS = [1, 24, 168];
async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
// Temporary keys reach only the image library: list danh mục and images, create a danh mục, add images.
export function uploadAllowed(method, path) {
  return (method === "GET" || method === "POST") && /^\/api\/sources(\/[^/]+)?$/.test(path);
}
// Live temporary keys, kept in one KV entry: the hash checks a key, the key itself is kept so the admin can copy it
// again from the API page. One entry rather than KV list, which
// can lag about a minute: a cancelled key leaves the list and stops working right away.
async function readTempKeys(env) {
  return ((await env.STORE.get("tmpkeys", "json")) || []).filter((k) => k.exp > Date.now());
}
// Admin only: make a key (shown once), list the live ones, cancel one or all.
async function handleTempKeys(req, env, id) {
  const live = await readTempKeys(env);
  if (req.method === "POST" && !id) {
    const hours = Number((await req.json().catch(() => ({}))).hours) || 24;
    if (!TEMP_HOURS.includes(hours)) return json({ error: "Thời hạn chỉ là 1 giờ, 24 giờ hoặc 7 ngày." }, 400);
    const key = TEMP_PREFIX + [...crypto.getRandomValues(new Uint8Array(20))].map((b) => b.toString(16).padStart(2, "0")).join("");
    const hash = await sha256(key), exp = Date.now() + hours * 3600_000;
    await env.STORE.put("tmpkeys", JSON.stringify([...live, { hash, key, exp, createdAt: new Date().toISOString(), hint: key.slice(-4) }]));
    return json({ key, id: hash.slice(0, 16), expiresAt: new Date(exp).toISOString() }, 201);
  }
  if (req.method === "GET" && !id) {
    return json({ keys: live.map((k) => ({ id: k.hash.slice(0, 16), key: k.key || "", hint: k.hint, createdAt: k.createdAt, expiresAt: new Date(k.exp).toISOString() })) }, 200, { "cache-control": "no-store" });
  }
  if (req.method === "DELETE") {
    const kept = live.filter((k) => id && k.hash.slice(0, 16) !== id);
    await env.STORE.put("tmpkeys", JSON.stringify(kept));
    return json({ ok: true, removed: live.length - kept.length });
  }
  return json({ error: "Not found" }, 404);
}
export function appAllowed(method, path) {
  return (method === "GET" && path === "/api/app-check")
    || (method === "POST" && path === "/api/images")
    || (method === "POST" && path === "/api/tool-files")
    || (method === "GET" && /^\/api\/sources(\/[^/]+)?$/.test(path))
    || (method === "POST" && path === "/api/logs")
    // Review Video: người quay dùng mật khẩu app để tạo sản phẩm, up source, tải kết quả
    || /^\/api\/(review|video-editing-tools)(\/|$)/.test(path);
}

// Batch ids and file names come from the local app; keep them to safe characters.
export const cleanName = (value, fallback) => String(value || "").replace(/[^\w.-]/g, "_").replace(/^\.+/, "").slice(0, 120) || fallback;

// Results of a tool kept as Product Review keeps its images: "Tools Hub/<tool>/Ảnh đã tạo/<same folders as on the machine>/<file>". Only listed tools, and only
// file types a result holds, so the app password cannot be used to fill the Drive with anything else.
export const TOOL_FILE_TOOLS = ["Content MXH"];
export const TOOL_FILE_TYPES = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".txt": "text/plain; charset=utf-8", ".json": "application/json" };
export const cleanSegment = (value) => String(value || "").normalize("NFC").replace(/[\/:*?"<>|\u0000-\u001f]/g, "_").trim().replace(/^\.+/, "").slice(0, 120);
export function toolFilePath(value) {
  const parts = String(value || "").split("/").map(cleanSegment);
  if (parts.length < 1 || parts.length > 8 || parts.some((p) => !p)) return null;
  const name = parts[parts.length - 1], mime = TOOL_FILE_TYPES[name.slice(name.lastIndexOf(".")).toLowerCase()];
  return mime ? { folders: parts.slice(0, -1), name, mime } : null;
}

// ---------- Google Drive ----------
async function accessToken(env) {
  const cached = await env.STORE.get("access_token", "json");
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;
  const refresh = await env.STORE.get("refresh_token");
  if (!refresh) throw new Error("Chưa kết nối Google Drive.");
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET, refresh_token: refresh, grant_type: "refresh_token" }),
  });
  const t = await r.json();
  if (!t.access_token) throw new Error("Google từ chối làm mới phiên: " + (t.error || r.status));
  await env.STORE.put("access_token", JSON.stringify({ token: t.access_token, exp: Date.now() + t.expires_in * 1000 }));
  return t.access_token;
}

async function drive(env, path, init = {}) {
  const token = await accessToken(env);
  const r = await fetch(`https://www.googleapis.com${path}`, { ...init, headers: { ...(init.headers || {}), authorization: `Bearer ${token}` } });
  if (!r.ok && r.status !== 204) throw new Error(`Drive ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r;
}

const FOLDER_MIME = "application/vnd.google-apps.folder";
async function createFolder(env, name, parent) {
  const r = await drive(env, "/drive/v3/files?fields=id", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name, mimeType: FOLDER_MIME, ...(parent ? { parents: [parent] } : {}) }),
  });
  return (await r.json()).id;
}

async function folder(env, name, parent) {
  const key = `folder:${parent || "root"}:${name}`;
  const saved = await env.STORE.get(key);
  if (saved) return saved;
  const id = await createFolder(env, name, parent);
  await env.STORE.put(key, id);
  return id;
}

// The app's top folder. It was "Product Image Batch" with run folders directly inside; the same folder is
// renamed (ids and links stay), and organizeRuns() moves the old run folders into "Ảnh đã tạo".
// Later it was "Product Review Batch" at the top of the Drive; it moves into "Tools Hub" as "Product Review", the
// same folder again, so every image link stays.
async function appRoot(env) {
  const saved = await env.STORE.get("folder:app-root");
  if (saved && (await env.STORE.get("folder:hub-layout"))) return saved;
  const hub = await folder(env, HUB_FOLDER);
  let id = saved || (await env.STORE.get(`folder:root:${OLD_FOLDER_NAME}`));
  if (id) {
    const { parents = [] } = await (await drive(env, `/drive/v3/files/${id}?fields=parents`)).json();
    const move = parents.includes(hub) ? "" : `&addParents=${hub}&removeParents=${parents.join(",")}`;
    await drive(env, `/drive/v3/files/${id}?fields=id${move}`, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: FOLDER_NAME }) });
  } else {
    id = await folder(env, FOLDER_NAME, hub);
  }
  await env.STORE.put("folder:app-root", id);
  await env.STORE.put("folder:hub-layout", "1");
  return id;
}
const runsRoot = async (env) => folder(env, RUNS_FOLDER, await appRoot(env));

// Moves run folders still sitting in the top folder into "Ảnh đã tạo", a few per call so a call stays within
// the Worker's request limits; the management page repeats it until nothing is left.
async function organizeRuns(env) {
  if (await env.STORE.get("organized:runs")) return { moved: 0, remaining: 0 };
  const root = await appRoot(env), runs = await runsRoot(env);
  const keep = new Set([RUNS_FOLDER, SOURCE_FOLDER, LOGS_FOLDER]);
  const left = (await listChildren(env, root, `mimeType = '${FOLDER_MIME}'`)).filter((f) => !keep.has(f.name));
  const batch = left.slice(0, 15);
  for (const f of batch) {
    await drive(env, `/drive/v3/files/${f.id}?addParents=${runs}&removeParents=${root}&fields=id`, { method: "PATCH", headers: { "content-type": "application/json" }, body: "{}" });
    await env.STORE.delete(`folder:${root}:${f.name}`);
    await env.STORE.put(`folder:${runs}:${f.name}`, f.id);
  }
  const remaining = left.length - batch.length;
  if (!remaining) await env.STORE.put("organized:runs", "1");
  return { moved: batch.length, remaining };
}

// drive.file scope: this lists only files the Worker created, never the rest of the Drive.
async function listChildren(env, parent, extra = "") {
  const files = [];
  let pageToken = "";
  do {
    const q = new URLSearchParams({
      q: `'${parent}' in parents and trashed = false${extra ? ` and ${extra}` : ""}`,
      fields: "nextPageToken, files(id, name, mimeType, size, md5Checksum, createdTime)", pageSize: "1000",
      ...(pageToken ? { pageToken } : {}),
    });
    const page = await (await drive(env, `/drive/v3/files?${q}`)).json();
    files.push(...(page.files || []));
    pageToken = page.nextPageToken;
  } while (pageToken);
  return files;
}

async function uploadFile(env, name, mime, bytes, parent) {
  const boundary = "pib" + crypto.randomUUID();
  const head = `--${boundary}\r\ncontent-type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify({ name, parents: [parent] })}\r\n--${boundary}\r\ncontent-type: ${mime}\r\n\r\n`;
  const r = await drive(env, "/upload/drive/v3/files?uploadType=multipart&fields=id", {
    method: "POST",
    headers: { "content-type": `multipart/related; boundary=${boundary}` },
    body: new Blob([head, bytes, `\r\n--${boundary}--`]),
  });
  return (await r.json()).id;
}

// One KV key per image (img:<id>, item copied into metadata for listing), so parallel
// uploads never overwrite each other. LIST_KEY is the older single-array format, still read.
const readLegacy = async (env) => (await env.STORE.get(LIST_KEY, "json")) || [];
const writeLegacy = (env, list) => env.STORE.put(LIST_KEY, JSON.stringify(list));
const putItem = (env, item) => env.STORE.put(`img:${item.id}`, JSON.stringify(item), { metadata: item });
async function getItem(env, id) {
  return (await env.STORE.get(`img:${id}`, "json")) || (await readLegacy(env)).find((i) => i.id === id) || null;
}
async function readList(env) {
  const items = [];
  let cursor;
  do {
    const page = await env.STORE.list({ prefix: "img:", cursor });
    for (const key of page.keys) items.push(key.metadata || (await env.STORE.get(key.name, "json")));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  const seen = new Set(items.map((i) => i.id));
  return [...items, ...(await readLegacy(env)).filter((i) => !seen.has(i.id))].sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}
async function removeItem(env, id) {
  await env.STORE.delete(`img:${id}`);
  const legacy = await readLegacy(env);
  if (legacy.some((i) => i.id === id)) await writeLegacy(env, legacy.filter((i) => i.id !== id));
}
const publicUrl = (origin, item) => `${origin}/img/${item.id}.png`;

// ---------- Source library ----------
// Sample photos for the app live in "<FOLDER_NAME>/Nguồn ảnh/<group>/". Drive is the only index:
// the app downloads one group at a time and compares md5 to fetch only new or changed files.
const SOURCE_FOLDER = "Nguồn ảnh";
const GROUP_RE = /^[\p{L}\p{N}][\p{L}\p{N} -]{0,59}$/u;
const SOURCE_TYPES = ["image/jpeg", "image/png", "image/webp"];
const quote = (value) => value.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
export const cleanFileName = (value) => String(value || "").replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_").replace(/^\.+/, "").slice(0, 120);
const sourceRoot = async (env) => folder(env, SOURCE_FOLDER, await appRoot(env));
const sourceUrl = (origin, file) => `${origin}/src/${file.id}`;
async function groupFolder(env, name) {
  const found = await listChildren(env, await sourceRoot(env), `mimeType = '${FOLDER_MIME}' and name = '${quote(name)}'`);
  return found[0]?.id || null;
}
const sourceFile = (origin, f) => ({ id: f.id, name: f.name, size: Number(f.size || 0), md5: f.md5Checksum, createdAt: f.createdTime, url: sourceUrl(origin, f) });
// Groups the desktop app sees. The admin switches each one on or off on the management page; a new
// group stays hidden until switched on, so the library can grow a group at a time.
const ENABLED_KEY = "source_enabled";
const DEFAULT_ENABLED = ["Áo", "Nội thất"];
const nfc = (value) => String(value).normalize("NFC");
const readEnabled = async (env) => new Set(((await env.STORE.get(ENABLED_KEY, "json")) || DEFAULT_ENABLED).map(nfc));
const writeEnabled = (env, set) => env.STORE.put(ENABLED_KEY, JSON.stringify([...set].sort((a, b) => a.localeCompare(b, "vi"))));

// ---------- Support logs ----------
// "Gửi lỗi" in the app uploads one error file (.md; older apps a .zip) here; the management page lists and downloads them.
const LOGS_FOLDER = "Logs";
const logType = (name) => (/\.zip$/i.test(String(name)) ? "application/zip" : "text/markdown; charset=utf-8");
const logsRoot = async (env) => folder(env, LOGS_FOLDER, await appRoot(env));
async function handleLogs(req, env, url, id) {
  const root = await logsRoot(env);
  if (!id && req.method === "GET") {
    const files = await listChildren(env, root);
    return json({ logs: files.map((f) => ({ id: f.id, name: f.name, size: Number(f.size || 0), createdAt: f.createdTime })).sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))) }, 200, { "cache-control": "no-store" });
  }
  if (!id && req.method === "POST") {
    const bytes = await req.arrayBuffer();
    if (!bytes.byteLength || bytes.byteLength > 50 * 1024 * 1024) return json({ error: "File log rỗng hoặc quá 50MB." }, 400);
    const asked = cleanFileName(url.searchParams.get("name")) || `loi-${Date.now()}.md`;
    const name = /\.(md|zip)$/i.test(asked) ? asked : `${asked}.md`;
    const fileId = await uploadFile(env, name, logType(name), bytes, root);
    return json({ id: fileId, name }, 201);
  }
  if (!id || !/^[\w-]+$/.test(id)) return json({ error: "Not found" }, 404);
  const meta = await (await drive(env, `/drive/v3/files/${id}?fields=parents,name`)).json();
  if (!(meta.parents || []).includes(root)) return json({ error: "Không tìm thấy log." }, 404);
  if (req.method === "DELETE") {
    await drive(env, `/drive/v3/files/${id}`, { method: "DELETE" });
    return json({ ok: true });
  }
  if (req.method === "GET") {
    const r = await drive(env, `/drive/v3/files/${id}?alt=media`);
    return new Response(r.body, { headers: { "content-type": logType(meta.name), "content-disposition": `attachment; filename="${String(meta.name).replace(/"/g, "")}"`, "cache-control": "no-store" } });
  }
  return json({ error: "Not found" }, 404);
}

async function handleSources(req, env, url, parts, role) {
  const [rawGroup, fileId] = parts;
  const enabled = await readEnabled(env);
  if (!rawGroup) {
    if (req.method === "GET") {
      let folders = await listChildren(env, await sourceRoot(env), `mimeType = '${FOLDER_MIME}'`);
      if (role === "app") folders = folders.filter((f) => enabled.has(nfc(f.name)));
      const groups = await Promise.all(folders.map(async (f) => ({ name: f.name, count: (await listChildren(env, f.id, `mimeType != '${FOLDER_MIME}'`)).length, enabled: enabled.has(nfc(f.name)) })));
      return json({ groups: groups.sort((a, b) => a.name.localeCompare(b.name, "vi")) }, 200, { "cache-control": "no-store" });
    }
    if (req.method === "POST") {
      const name = String((await req.json().catch(() => ({}))).name || "").trim();
      if (!GROUP_RE.test(name)) return json({ error: "Tên nhóm chỉ gồm chữ, số, dấu cách hoặc gạch ngang." }, 400);
      if (await groupFolder(env, name)) return json({ error: "Nhóm đã có." }, 409);
      await createFolder(env, name, await sourceRoot(env));
      return json({ name, count: 0 }, 201);
    }
    return json({ error: "Not found" }, 404);
  }
  const group = nfc(decodeURIComponent(rawGroup));
  if (!GROUP_RE.test(group)) return json({ error: "Tên nhóm không hợp lệ." }, 400);
  if (role === "app" && !enabled.has(nfc(group))) return json({ error: "Không tìm thấy nhóm." }, 404);
  const parent = await groupFolder(env, group);
  if (!parent) return json({ error: "Không tìm thấy nhóm." }, 404);

  if (fileId) {
    if (req.method !== "DELETE" || !/^[\w-]+$/.test(fileId)) return json({ error: "Not found" }, 404);
    const meta = await (await drive(env, `/drive/v3/files/${fileId}?fields=parents`)).json();
    if (!(meta.parents || []).includes(parent)) return json({ error: "Ảnh không thuộc nhóm này." }, 404);
    await drive(env, `/drive/v3/files/${fileId}`, { method: "DELETE" });
    return json({ ok: true });
  }
  if (req.method === "GET") {
    const files = await listChildren(env, parent, `mimeType != '${FOLDER_MIME}'`);
    return json({ group, files: files.map((f) => sourceFile(url.origin, f)).sort((a, b) => a.name.localeCompare(b.name)) }, 200, { "cache-control": "no-store" });
  }
  if (req.method === "PATCH") {
    const on = (await req.json().catch(() => ({}))).enabled;
    if (typeof on !== "boolean") return json({ error: "Thiếu trạng thái bật/tắt." }, 400);
    if (on) enabled.add(nfc(group)); else enabled.delete(nfc(group));
    await writeEnabled(env, enabled);
    return json({ name: group, enabled: on });
  }
  if (req.method === "DELETE") {
    if ((await listChildren(env, parent)).length) return json({ error: "Xoá hết ảnh trong nhóm trước." }, 400);
    await drive(env, `/drive/v3/files/${parent}`, { method: "DELETE" });
    if (enabled.delete(nfc(group))) await writeEnabled(env, enabled);
    return json({ ok: true });
  }
  if (req.method === "POST") {
    // The image is the request body, or with ?url= fetched here from that link (handy for scripts and AI agents).
    let mime, bytes, from = url.searchParams.get("url") || "";
    if (from) {
      if (!/^https?:\/\//i.test(from)) return json({ error: "Link ảnh phải bắt đầu bằng http:// hoặc https://." }, 400);
      const r = await fetch(from, { redirect: "follow", headers: { "user-agent": "Mozilla/5.0 (tools-hub)" } }).catch(() => null);
      if (!r || !r.ok) return json({ error: `Không tải được ảnh từ link${r ? ` (HTTP ${r.status})` : ""}.` }, 400);
      mime = (r.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
      bytes = await r.arrayBuffer();
    } else {
      mime = (req.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
      bytes = await req.arrayBuffer();
    }
    if (!SOURCE_TYPES.includes(mime)) return json({ error: "Chỉ nhận ảnh JPG, PNG hoặc WebP." }, 400);
    if (!bytes.byteLength || bytes.byteLength > 25 * 1024 * 1024) return json({ error: "Ảnh rỗng hoặc quá 25MB." }, 400);
    // The app matches files by name, so a repeated name gets a numbered suffix instead of a duplicate.
    const fromName = from ? decodeURIComponent(new URL(from).pathname.split("/").pop() || "") : "";
    let name = cleanFileName(url.searchParams.get("name")) || cleanFileName(fromName) || `anh-${Date.now()}`;
    const extOf = { "image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp" }[mime];
    if (!/\.(jpe?g|png|webp)$/i.test(name)) name += extOf;
    const taken = new Set((await listChildren(env, parent, `mimeType != '${FOLDER_MIME}'`)).map((f) => f.name));
    const dot = name.lastIndexOf(".");
    const [stem, ext] = dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ""];
    for (let n = 2; taken.has(name); n++) name = `${stem}-${n}${ext}`;
    const id = await uploadFile(env, name, mime, bytes, parent);
    return json(sourceFile(url.origin, { id, name, size: bytes.byteLength, createdTime: new Date().toISOString() }), 201);
  }
  return json({ error: "Not found" }, 404);
}

// ---------- Grok Video Prompt: sample videos ----------
// One sample video per prompt, by the prompt's code. The index (code -> Drive file) is one KV entry, read by the
// tool's page without a password; the admin uploads with PUT /api/grok-videos/<seconds>/<code>.
const GROK_FOLDER = "Grok Video Prompt";
const GROK_VIDEOS_FOLDER = "Video mẫu";
const GROK_KEY = "grok:videos";
const GROK_SECONDS = ["6", "10", "15"];
const VIDEO_TYPES = ["video/mp4", "video/webm", "video/quicktime"];
const readGrokVideos = async (env) => (await env.STORE.get(GROK_KEY, "json")) || {};
const grokVideoUrl = (origin, v) => `${origin}/grok/video/${v.fileId}`;
export const grokCode = (value) => (/^[\w-]{1,120}$/.test(String(value || "")) ? String(value) : "");

async function handleGrokVideos(req, env, url, seconds, code) {
  if (!GROK_SECONDS.includes(seconds) || !grokCode(code)) return json({ error: "Thời lượng hoặc mã prompt không hợp lệ." }, 400);
  const videos = await readGrokVideos(env);
  const old = videos[code];
  if (req.method === "PUT") {
    const mime = (req.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
    if (!VIDEO_TYPES.includes(mime)) return json({ error: "Chỉ nhận video MP4, WebM hoặc MOV." }, 400);
    const bytes = await req.arrayBuffer();
    if (!bytes.byteLength || bytes.byteLength > 90 * 1024 * 1024) return json({ error: "Video rỗng hoặc quá 90MB." }, 400);
    const tool = await folder(env, GROK_FOLDER, await folder(env, HUB_FOLDER));
    const parent = await folder(env, `${seconds}s`, await folder(env, GROK_VIDEOS_FOLDER, tool));
    const ext = { "video/mp4": ".mp4", "video/webm": ".webm", "video/quicktime": ".mov" }[mime];
    const fileId = await uploadFile(env, code + ext, mime, bytes, parent);
    videos[code] = { fileId, seconds, mime, size: bytes.byteLength, updatedAt: new Date().toISOString() };
    await env.STORE.put(GROK_KEY, JSON.stringify(videos));
    if (old) await drive(env, `/drive/v3/files/${old.fileId}`, { method: "DELETE" }).catch(() => {});
    return json({ code, ...videos[code], url: grokVideoUrl(url.origin, videos[code]) }, 201);
  }
  if (req.method === "DELETE") {
    if (!old) return json({ error: "Prompt này chưa có video mẫu." }, 404);
    delete videos[code];
    await env.STORE.put(GROK_KEY, JSON.stringify(videos));
    await drive(env, `/drive/v3/files/${old.fileId}`, { method: "DELETE" }).catch(() => {});
    return json({ ok: true });
  }
  return json({ error: "Not found" }, 404);
}

// ---------- Routes ----------
async function handle(req, env, ctx) {
  const url = new URL(req.url);
  const path = url.pathname;

  if (path === "/oauth/start") {
    if (!sameKey(url.searchParams.get("key") || "", env.ADMIN_PASSWORD || "")) return new Response("Sai mật khẩu.", { status: 401 });
    const q = new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID, redirect_uri: `${url.origin}/oauth/callback`, response_type: "code",
      scope: SCOPE, access_type: "offline", prompt: "consent select_account",
    });
    return Response.redirect(`https://accounts.google.com/o/oauth2/v2/auth?${q}`, 302);
  }

  if (path === "/oauth/callback") {
    const code = url.searchParams.get("code");
    if (!code) return new Response("Thiếu mã xác thực.", { status: 400 });
    const r = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ code, client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET, redirect_uri: `${url.origin}/oauth/callback`, grant_type: "authorization_code" }),
    });
    const t = await r.json();
    const page = (msg, status = 200) => new Response(`<meta charset=utf-8><p style='font:16px system-ui;padding:24px'>${msg}</p>`, { status, headers: { "content-type": "text/html; charset=utf-8" } });
    const claims = t.id_token ? JSON.parse(atob(t.id_token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))) : {};
    if (!OWNER_EMAILS.includes(claims.email)) return page(`Tài khoản ${claims.email || "này"} không có quyền.`, 403);
    if (!t.refresh_token) return page("Google không trả quyền truy cập lâu dài, thử lại.", 400);
    await env.STORE.put("refresh_token", t.refresh_token);
    await env.STORE.put("access_token", JSON.stringify({ token: t.access_token, exp: Date.now() + t.expires_in * 1000 }));
    await env.STORE.put("drive_email", claims.email);
    return page(`Đã kết nối Google Drive (${claims.email}). Bạn có thể đóng tab này.`);
  }

  // Public image link used in the CSV; cached at the edge.
  const img = path.match(/^\/img\/([\w-]+)\.png$/);
  if (img && req.method === "GET") {
    const cache = caches.default;
    const hit = await cache.match(req);
    if (hit) return hit;
    const item = await getItem(env, img[1]);
    if (!item || item.status === "rejected") return new Response("Không tìm thấy ảnh.", { status: 404 });
    const r = await drive(env, `/drive/v3/files/${item.fileId}?alt=media`);
    const res = new Response(r.body, { headers: { "content-type": "image/png", "cache-control": "public, max-age=86400" } });
    ctx.waitUntil(cache.put(req, res.clone()));
    return res;
  }

  // Public source photo link for thumbnails on the management page; ids are unguessable Drive ids.
  const src = path.match(/^\/src\/([\w-]+)$/);
  if (src && req.method === "GET") {
    const cache = caches.default;
    const hit = await cache.match(req);
    if (hit) return hit;
    const r = await drive(env, `/drive/v3/files/${src[1]}?alt=media`);
    const type = r.headers.get("content-type") || "";
    if (!type.startsWith("image/")) return new Response("Không tìm thấy ảnh.", { status: 404 });
    const res = new Response(r.body, { headers: { "content-type": type, "cache-control": "public, max-age=86400" } });
    ctx.waitUntil(cache.put(req, res.clone()));
    return res;
  }

  // Grok Video Prompt's sample videos, public: the list by prompt code, and each video (cached at the edge, so the
  // browser's range requests for seeking are answered from the cache after the first play).
  if (path === "/grok/videos" && req.method === "GET") {
    const videos = await readGrokVideos(env);
    const list = Object.fromEntries(Object.entries(videos).map(([code, v]) => [code, { seconds: v.seconds, url: grokVideoUrl(url.origin, v), updatedAt: v.updatedAt }]));
    return json({ videos: list }, 200, { "cache-control": "no-store" });
  }
  const video = path.match(/^\/grok\/video\/([\w-]+)$/);
  if (video && req.method === "GET") {
    const cache = caches.default;
    const hit = await cache.match(req);
    if (hit) return hit;
    const known = Object.values(await readGrokVideos(env)).find((v) => v.fileId === video[1]);
    if (!known) return new Response("Không tìm thấy video.", { status: 404 });
    const r = await drive(env, `/drive/v3/files/${known.fileId}?alt=media`);
    const res = new Response(r.body, { headers: { "content-type": known.mime, "content-length": String(known.size), "accept-ranges": "bytes", "cache-control": "public, max-age=604800" } });
    ctx.waitUntil(cache.put(new Request(url.toString()), res.clone()));
    return res;
  }

  // Review Video: phát/tải file bằng link ký có hạn (thẻ <video> không gửi được header mật khẩu)
  const rvFile = path.match(/^\/(?:review|video-editing-tools)\/file\/([\w-]+)$/);
  if (rvFile && req.method === "GET") return reviewFile(req, env, url, rvFile[1], { drive, ctx });

  // Review Video mở công khai (không cần mật khẩu) theo yêu cầu; xoá chỉ đưa vào thùng rác Drive.
  const review = path.match(/^\/api\/(?:review|video-editing-tools)(?:\/([\w-]+)(?:\/(upload|files)(?:\/([\w-]+))?)?)?$/);
  if (review) return handleReview(req, env, url, [review[1], review[2], review[3]], { drive, folder, json });

  if (path === "/api/status" && req.method === "GET") {
    return json({ connected: !!(await env.STORE.get("refresh_token")), email: isAdmin(req, env) ? await env.STORE.get("drive_email") : undefined });
  }

  // ----- signed in below: admin for everything, app password for the app's own calls -----
  if (!path.startsWith("/api/")) return new Response("Not found", { status: 404 });
  const role = await keyRole(req, env);
  if (!role) return json({ error: isTempKey(req.headers.get("x-admin-key") || "") ? "Mã tạm sai hoặc đã hết hạn." : "Sai mật khẩu." }, 401);
  if (role === "app" && !appAllowed(req.method, path)) return json({ error: "Mật khẩu app không dùng được cho trang quản lý." }, 403);
  if (role === "upload" && !uploadAllowed(req.method, path)) return json({ error: "Mã tạm chỉ dùng để xem và thêm ảnh vào kho." }, 403);

  const temp = path.match(/^\/api\/temp-keys(?:\/(\w+))?$/);
  if (temp) return handleTempKeys(req, env, temp[1]);
  if (path === "/api/app-check" && req.method === "GET") return json({ ok: true, role });

  if (path === "/api/images" && req.method === "GET") {
    const list = await readList(env);
    return json(list.map((i) => ({ ...i, url: publicUrl(url.origin, i) })), 200, { "cache-control": "no-store" });
  }

  // Upload one PNG: POST /api/images?batch=<batch id>&name=<item id>.png&product=<handle>
  if (path === "/api/images" && req.method === "POST") {
    const bytes = await req.arrayBuffer();
    if (!bytes.byteLength || bytes.byteLength > 25 * 1024 * 1024) return json({ error: "Ảnh rỗng hoặc quá 25MB." }, 400);
    const batch = cleanName(url.searchParams.get("batch"), "batch");
    const name = cleanName(url.searchParams.get("name"), "image.png");
    const fileId = await uploadFile(env, name, "image/png", bytes, await folder(env, batch, await runsRoot(env)));
    const item = {
      id: crypto.randomUUID().replace(/-/g, ""), fileId, batch, name,
      product: String(url.searchParams.get("product") || "").slice(0, 200),
      size: bytes.byteLength, status: "awaiting_review", createdAt: new Date().toISOString(),
    };
    await putItem(env, item);
    return json({ ...item, url: publicUrl(url.origin, item) }, 201);
  }

  // Upload one result file: POST /api/tool-files?tool=Content MXH&path=<run>/<product>/<file>; the same path again replaces it.
  if (path === "/api/tool-files" && req.method === "POST") {
    const tool = String(url.searchParams.get("tool") || "");
    const target = toolFilePath(url.searchParams.get("path"));
    if (!TOOL_FILE_TOOLS.includes(tool) || !target) return json({ error: "Tool hoặc đường dẫn file không hợp lệ." }, 400);
    const bytes = await req.arrayBuffer();
    if (!bytes.byteLength || bytes.byteLength > 25 * 1024 * 1024) return json({ error: "File rỗng hoặc quá 25MB." }, 400);
    let parent = await folder(env, RUNS_FOLDER, await folder(env, tool, await folder(env, HUB_FOLDER)));
    for (const name of target.folders) parent = await folder(env, name, parent);
    const key = `toolfile:${parent}:${target.name}`;
    const old = await env.STORE.get(key);
    const fileId = await uploadFile(env, target.name, target.mime, bytes, parent);
    await env.STORE.put(key, fileId);
    if (old) await drive(env, `/drive/v3/files/${old}`, { method: "DELETE" }).catch(() => {});
    return json({ fileId, path: [tool, RUNS_FOLDER, ...target.folders, target.name].join("/") }, 201);
  }

  if (path === "/api/organize" && req.method === "POST") return json(await organizeRuns(env));

  const logs = path.match(/^\/api\/logs(?:\/([^/]+))?$/);
  if (logs) return handleLogs(req, env, url, logs[1]);

  const grok = path.match(/^\/api\/grok-videos\/(\w+)\/([^/]+)$/);
  if (grok) return role === "admin" ? handleGrokVideos(req, env, url, grok[1], grok[2]) : json({ error: "Chỉ admin được tải video mẫu." }, 403);

  const sources = path.match(/^\/api\/sources(?:\/([^/]+)(?:\/([^/]+))?)?$/);
  if (sources) return handleSources(req, env, url, [sources[1], sources[2]], role);

  const one = path.match(/^\/api\/images\/(\w+)$/);
  if (one && (req.method === "PATCH" || req.method === "DELETE")) {
    const item = await getItem(env, one[1]);
    if (!item) return json({ error: "Không tìm thấy ảnh." }, 404);
    if (req.method === "DELETE") {
      await drive(env, `/drive/v3/files/${item.fileId}`, { method: "DELETE" });
      await removeItem(env, item.id);
      return json({ ok: true });
    }
    const { status } = await req.json();
    if (!STATUSES.includes(status)) return json({ error: "Trạng thái không hợp lệ." }, 400);
    const updated = { ...item, status, reviewedAt: new Date().toISOString() };
    await removeItem(env, item.id);
    await putItem(env, updated);
    ctx.waitUntil(caches.default.delete(new Request(publicUrl(url.origin, updated))));
    return json({ ...updated, url: publicUrl(url.origin, updated) });
  }

  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(req, env, ctx) {
    if (req.method === "OPTIONS") return new Response(null, { headers: cors(req) });
    let res;
    try {
      res = await handle(req, env, ctx);
    } catch (e) {
      res = json({ error: e.message || "Lỗi máy chủ." }, 500);
    }
    const h = new Headers(res.headers);
    for (const [k, v] of Object.entries(cors(req))) h.set(k, v);
    if (new URL(req.url).pathname.startsWith("/grok/")) h.set("access-control-allow-origin", "*");
    return new Response(res.body, { status: res.status, headers: h });
  },
};
