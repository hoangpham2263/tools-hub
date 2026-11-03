// Content MXH's window (ui/) served on localhost, on macOS and Windows alike, and the run it starts (src/run-content.ps1).
// The Tools Hub menu starts this file (tool.json "mac") with --no-open and finds it by /api/root; each install gets its
// own port from its folder, as Product Review does. The run prints @@EVENT lines; they become the events the window polls.
import { createServer } from "node:http";
import { spawn, execFile } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdir, writeFile, appendFile, readFile, readdir, rm, stat } from "node:fs/promises";
import { createReadStream, existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmdirSync, statSync, renameSync, appendFileSync } from "node:fs";
import { join, dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID, createHash } from "node:crypto";
import { createConfigApi } from "../../../hub/setup/config-api.mjs";
import { PWSH, toolEnv, psFile, psCommand, killTree, appWindow, openFolder } from "../../../hub/platform.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const hubRoot = resolve(root, "..", "..");
const toolPort = (() => { try { return Number(JSON.parse(readFileSync(join(root, "tool.json"), "utf8").replace(/^\uFEFF/, "")).port) || 0; } catch { return 0; } })();
const BASE_PORT = Number(process.env.FC_PORT || toolPort || 47000 + (parseInt(createHash("sha1").update(root).digest("hex").slice(0, 6), 16) % 1000));
let PORT = BASE_PORT;
// One workspace folder for every tool: <hub>/workspace/fb-content/ (Git ignores that single folder). A tool outside an install (a copy in
// a temp folder) keeps its own workspace/. What an older install kept in apps/fb-content/workspace/ moves here, entry by entry.
const installed = existsSync(join(hubRoot, "hub", "update.ps1"));
const oldWorkspace = join(root, "workspace");
const workspace = installed ? join(hubRoot, "workspace", "fb-content") : oldWorkspace;
if (installed && existsSync(oldWorkspace)) {
  mkdirSync(workspace, { recursive: true });
  for (const name of readdirSync(oldWorkspace)) {
    const target = join(workspace, name);
    if (existsSync(target)) continue;
    try { renameSync(join(oldWorkspace, name), target); } catch (e) { console.error(`Not moved to the common workspace: ${name} (${e.code})`); }
  }
  try { rmdirSync(oldWorkspace); } catch {}
}
const logs = join(workspace, "logs");
const uploads = join(workspace, "temp", "uploads");
const configApi = createConfigApi({ hubRoot, pwsh: PWSH, env: toolEnv });
mkdirSync(logs, { recursive: true });

const logFile = (name) => {
  const file = join(logs, name);
  try { if (statSync(file).size > 1024 * 1024) renameSync(file, file.replace(/\.log$/, ".old.log")); } catch {}
  return file;
};
const logError = (where, text) => {
  try { appendFileSync(logFile("app-errors.log"), `[${new Date().toISOString()}] ${where}\n  ${String(text).trim().replace(/\n/g, "\n  ")}\n\n`); } catch {}
};
process.on("uncaughtException", (e) => { logError("Máy chủ Content MXH", e.stack || e); process.exit(1); });
process.on("unhandledRejection", (e) => logError("Máy chủ Content MXH", e?.stack || e));

const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".woff2": "font/woff2" };
const IMAGE_EXT = [".png", ".jpg", ".jpeg", ".webp"];
const HUB_ASSETS = ["icon.svg", "hub.js"];

// Which AIs the window offers. The run checks the choice again against the hub's registry (Test-ContentJob).
const CHOICES = {
  image: [{ id: "codex", name: "Codex CLI" }],
  text: [{ id: "gemini", name: "Gemini web" }, { id: "codex", name: "Codex CLI" }, { id: "antigravity", name: "Antigravity CLI" }],
};

const readJson = async (file) => JSON.parse((await readFile(file, "utf8")).replace(/^﻿/, ""));
async function pageData() {
  const data = join(root, "data");
  const brandsDir = join(data, "brands");
  const brands = [];
  for (const dir of await readdir(brandsDir).catch(() => [])) {
    const pack = await readJson(join(brandsDir, dir, "brand.json")).catch(() => null);
    if (pack) brands.push({ id: pack.id, name: pack.name, aliases: pack.aliases || [], hashtags: pack.hashtags || [], watermark: pack.watermark ? { ...pack.watermark, url: `/brand/${pack.id}/${pack.watermark.file}` } : null });
  }
  const library = await readJson(join(root, "data", "angles.json"));
  return {
    platforms: (await readJson(join(data, "platforms.json"))).platforms,
    tones: (await readJson(join(data, "tones.json"))).tones,
    // The prompt text of each angle stays on the server; the window needs only what it shows.
    angles: library.angles.map(({ text, ...angle }) => angle),
    angleGroups: library.groups,
    angleSets: library.sets,
    angleDefault: library.default,
    choices: CHOICES,
    brands,
  };
}

// ----- The run -----
const run = { proc: null, events: [], stopped: false, exitCode: null, done: false, folder: "", logFile: "" };
function receive(line) {
  if (!line.startsWith("@@EVENT ")) return;
  try {
    const event = JSON.parse(line.slice(8));
    if (event.kind === "start") run.folder = event.folder;
    run.events.push(event);
  } catch {}
}
async function startRun(job) {
  if (run.proc) throw new Error("Đang chạy.");
  if (!Array.isArray(job?.products) || !job.products.length) throw new Error("Chưa có sản phẩm.");
  await mkdir(join(workspace, "temp"), { recursive: true });
  const stamp = Date.now();
  const jobFile = join(workspace, "temp", `job-${stamp}.json`);
  await writeFile(jobFile, JSON.stringify(job), "utf8");
  Object.assign(run, { events: [], stopped: false, exitCode: null, done: false, folder: "", logFile: join(logs, `run-${stamp}.log`) });
  // Own process group (macOS), so Dừng stops the AI processes it started too.
  const proc = spawn(PWSH, psFile(join(root, "src", "run-content.ps1"), ["-JobFile", jobFile]), { cwd: root, env: toolEnv, detached: process.platform !== "win32", windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  run.proc = proc;
  let tail = "";
  let chain = Promise.resolve();
  for (const stream of [proc.stdout, proc.stderr]) {
    createInterface({ input: stream }).on("line", (line) => {
      if (stream === proc.stderr) tail = (tail + "\n" + line).slice(-1500);
      chain = chain.then(() => appendFile(run.logFile, line + "\n")).then(() => receive(line));
    });
  }
  proc.on("error", (e) => { run.events.push({ kind: "fatal", message: e.message }); });
  proc.on("exit", (code) => {
    chain = chain.then(() => {
      run.exitCode = code;
      // A run that stopped before it said anything (a bad job, a missing module) leaves its reason in stderr.
      // Its first line is the message; the rest is PowerShell's trace, which stays in the run log.
      if (code && !run.events.some((e) => e.kind === "done") && !run.stopped) run.events.push({ kind: "fatal", message: tail.trim().split("\n")[0].trim().slice(0, 300) || `PowerShell thoát với mã ${code}.` });
      run.proc = null;
      run.done = true;
    });
  });
}
const stopRun = () => { if (run.proc) { run.stopped = true; killTree(run.proc); } };

// ----- Results of the runs on this machine: <workspace>/output/<stamp>/<STT>-<name>/ -----
const output = join(workspace, "output");
const RUN_ID = /^\d{4}-\d{2}-\d{2}_\d{2}h\d{2}m\d{2}s$/;
const dirBytes = async (dir) => {
  let total = 0;
  for (const entry of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
    const full = join(dir, entry.name);
    total += entry.isDirectory() ? await dirBytes(full) : (await stat(full).catch(() => ({ size: 0 }))).size;
  }
  return total;
};
// What a run left, read from its folders (results.json keeps absolute paths of the machine it ran on, which move with the install).
async function listRuns() {
  const runs = [];
  for (const id of (await readdir(output).catch(() => [])).filter((n) => RUN_ID.test(n)).sort().reverse()) {
    const dir = join(output, id);
    const products = [];
    for (const name of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
      if (!name.isDirectory()) continue;
      const folder = join(dir, name.name);
      const files = await readdir(folder).catch(() => []);
      const snapshot = await readJson(join(folder, "snapshot.json")).catch(() => null);
      // The marked copy (-logo.png) is the one to post; the plain image stays beside it.
      const pictures = files.filter((f) => /^anh-.*\.png$/.test(f) && !f.endsWith("-logo.png"));
      products.push({
        folder: name.name,
        name: snapshot?.product || name.name.replace(/^\d+-/, ""),
        images: pictures.map((f) => { const logo = f.replace(/\.png$/, "-logo.png"); return { file: join(folder, files.includes(logo) ? logo : f), label: f.replace(/^anh-/, "").replace(/\.png$/, "") }; }),
        posts: files.filter((f) => /^bai-.*\.txt$/.test(f)).map((f) => f.replace(/^bai-/, "").replace(/\.txt$/, "")),
      });
    }
    runs.push({ id, folder: dir, bytes: await dirBytes(dir), products, running: run.proc ? run.folder === dir : false });
  }
  return { folder: output, bytes: runs.reduce((n, r) => n + r.bytes, 0), runs };
}

// ----- HTTP -----
// The Tools Hub site (https://hoangpham.is-a.dev/tools-hub/) asks every tool's fixed port whether the app runs, to open it:
// only this answer, only for that origin (the browser's own "loopback" permission still applies).
const SITE_ORIGIN = "https://hoangpham.is-a.dev";
const rootHeaders = (req) => (req.headers.origin === SITE_ORIGIN ? { "access-control-allow-origin": SITE_ORIGIN, "vary": "Origin" } : {});
const send = (res, status, data, headers = {}) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers }); res.end(JSON.stringify(data)); };
const body = async (req, limit = 60 * 1024 * 1024) => {
  const chunks = []; let size = 0;
  for await (const c of req) { size += c.length; if (size > limit) throw new Error("Tệp quá lớn."); chunks.push(c); }
  return Buffer.concat(chunks);
};
const sendFile = (res, file) => {
  if (!existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": TYPES[extname(file).toLowerCase()] || "application/octet-stream", "cache-control": "no-store" });
  createReadStream(file).pipe(res);
};
// Only images this tool wrote (its uploads and results) are served back to the window.
const allowedImage = (p) => { const full = resolve(p); return full.startsWith(workspace + sep) && IMAGE_EXT.includes(extname(full).toLowerCase()); };
const version = () => { try { return readFileSync(join(hubRoot, "workspace", "version.txt"), "utf8").trim(); } catch { return ""; } };
const q = (p) => p.replace(/'/g, "''");
const pwshOut = (command, timeout) => new Promise((done, fail) => execFile(PWSH, psCommand(command), { cwd: hubRoot, env: toolEnv, timeout, windowsHide: true }, (err, out) => (err ? fail(err) : done(String(out).trim()))));

function restart() {
  const out = openSync(logFile("server.log"), "a");
  spawn(process.execPath, [join(here, "server.mjs"), "--no-open"], { cwd: root, detached: true, windowsHide: true, stdio: ["ignore", out, out], env: { ...process.env, FC_WAIT_PORT: "1" } }).unref();
  setTimeout(() => process.exit(0), 300);
}

async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  const path = url.pathname;
  if (path === "/api/root") return send(res, 200, { root, service: "fb-content", protocol: 1, version: version(), pid: process.pid }, rootHeaders(req));
  if (path === "/api/data") return send(res, 200, await pageData());
  if (path === "/api/client-error" && req.method === "POST") {
    const { message = "", stack = "" } = JSON.parse((await body(req)).toString("utf8") || "{}");
    logError("Giao diện Content MXH", [message, stack].filter(Boolean).join("\n").slice(0, 4000));
    return send(res, 200, { ok: true });
  }
  if (path === "/api/upload" && req.method === "POST") {
    // A picked or dropped photo becomes a file the run reads (the window cannot hand PowerShell a browser blob).
    const name = (url.searchParams.get("name") || "image.png").replace(/[^\w.-]/g, "_");
    const ext = extname(name).toLowerCase();
    if (!IMAGE_EXT.includes(ext)) return send(res, 400, { error: "Chọn ảnh PNG, JPEG hoặc WebP." });
    await mkdir(uploads, { recursive: true });
    const file = join(uploads, `${randomUUID().replace(/-/g, "")}${ext}`);
    await writeFile(file, await body(req));
    return send(res, 200, { path: file });
  }
  if (path === "/api/run" && req.method === "POST") {
    try { await startRun(JSON.parse((await body(req)).toString("utf8") || "{}")); return send(res, 200, { ok: true }); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/run" && req.method === "GET") {
    const since = Number(url.searchParams.get("since") || 0);
    return send(res, 200, { running: !!run.proc, done: run.done, exitCode: run.exitCode, stopped: run.stopped, folder: run.folder, events: run.events.slice(since), next: run.events.length });
  }
  if (path === "/api/stop" && req.method === "POST") { stopRun(); return send(res, 200, { ok: true }); }
  if (path === "/api/runs" && req.method === "GET") return send(res, 200, await listRuns());
  // Explorer or Finder on a folder of the results: the output folder, a run or a product of it, nothing else.
  if (path === "/api/open" && req.method === "POST") {
    const { path: target = "" } = JSON.parse((await body(req)).toString("utf8") || "{}");
    const full = resolve(String(target) || output);
    if (full !== resolve(output) && !full.startsWith(resolve(output) + sep)) return send(res, 400, { error: "Chỉ mở được thư mục kết quả." });
    await mkdir(full, { recursive: true });
    openFolder(full);
    return send(res, 200, { ok: true });
  }
  // Old runs are removed by the window's cleanup: only run folders by their id, never the one that is running.
  if (path === "/api/runs/delete" && req.method === "POST") {
    const { ids = [] } = JSON.parse((await body(req)).toString("utf8") || "{}");
    const removed = [], kept = [];
    for (const id of [].concat(ids)) {
      const dir = join(output, String(id));
      if (!RUN_ID.test(String(id)) || !existsSync(dir) || (run.proc && run.folder === dir)) { kept.push(id); continue; }
      try { await rm(dir, { recursive: true, force: true }); removed.push(id); } catch { kept.push(id); }
    }
    return send(res, 200, { removed, kept });
  }
  if (path === "/file") {
    const file = url.searchParams.get("path") || "";
    return allowedImage(file) ? sendFile(res, resolve(file)) : (res.writeHead(404), res.end());
  }
  // The hub's own buttons (Cập nhật, Cấu hình, Tải lại) work against this server too, as on the menu.
  if (await configApi(req, res, path)) return;
  if (path === "/api/update-check") {
    const out = await pwshOut(`. '${q(join(hubRoot, "hub", "update.ps1"))}' -NoRun; [pscustomobject]@{ current = (Get-InstalledVersion '${q(hubRoot)}'); next = (Get-AppUpdate '${q(hubRoot)}') } | ConvertTo-Json -Compress`, 60000).catch(() => "");
    res.writeHead(out ? 200 : 502, { "content-type": TYPES[".json"] });
    return res.end(out || "{}");
  }
  if (path === "/api/update" && req.method === "POST") {
    if (run.proc) return send(res, 409, { error: "Đang chạy. Dừng hoặc chờ xong rồi cập nhật." });
    const ok = await pwshOut(`. '${q(join(hubRoot, "hub", "update.ps1"))}' -NoRun; Update-App '${q(hubRoot)}'`, 300000).then(() => true, () => false);
    send(res, ok ? 200 : 500, { ok });
    if (ok) setTimeout(() => { server.close(); restart(); }, 300);
    return;
  }
  if (path === "/api/reload" && req.method === "POST") {
    if (run.proc) return send(res, 409, { error: "Đang chạy. Dừng hoặc chờ xong rồi tải lại." });
    send(res, 200, { ok: true });
    setTimeout(() => { server.close(); restart(); }, 300);
    return;
  }
  if (path === "/api/quit" && req.method === "POST") { send(res, 200, { ok: true }); stopRun(); setTimeout(() => process.exit(0), 200); return; }
  if (path === "/icon.svg") return sendFile(res, join(root, "icon.svg"));
  // A brand's watermark file, for the preview next to the brand choice.
  const brandFile = /^\/brand\/([\w-]+)\/(watermark\.png)$/.exec(path);
  if (brandFile) return sendFile(res, join(root, "data", "brands", brandFile[1], brandFile[2]));
  const uiAsset = /^\/hub\/assets\/ui\/([\w./-]+\.(?:css|js|woff2))$/.exec(path);
  if (uiAsset) {
    const base = resolve(hubRoot, "hub", "assets", "ui");
    const file = resolve(base, uiAsset[1]);
    return file.startsWith(base + sep) ? sendFile(res, file) : (res.writeHead(404), res.end());
  }
  const hubAsset = /^\/hub\/assets\/([\w.-]+)$/.exec(path);
  if (hubAsset) return HUB_ASSETS.includes(hubAsset[1]) ? sendFile(res, join(hubRoot, "hub", "assets", hubAsset[1])) : (res.writeHead(404), res.end());
  const rel = path === "/" ? "index.html" : path.slice(1);
  const file = resolve(root, "ui", rel);
  if (!file.startsWith(resolve(root, "ui") + sep)) { res.writeHead(404); return res.end(); }
  return sendFile(res, file);
}

const server = createServer((req, res) => handle(req, res).catch((e) => send(res, 500, { error: e.message })));
function listen(attempt = 0) {
  server.once("error", (e) => {
    // The old server is still closing after an update or a reload.
    if (e.code === "EADDRINUSE" && process.env.FC_WAIT_PORT && attempt < 50) return setTimeout(() => listen(attempt + 1), 200);
    if (e.code === "EADDRINUSE") {
      // Already running for this folder: just show it. Another program on the port: try the next one.
      return fetch(`http://127.0.0.1:${PORT}/api/root`).then((r) => r.json()).then((info) => {
        if (info.root !== root) throw new Error("other");
        if (!process.argv.includes("--no-open")) appWindow(`http://127.0.0.1:${PORT}/`);
        process.exit(0);
      }).catch(() => {
        if (PORT - BASE_PORT >= 20) throw e;
        PORT++;
        listen(attempt);
      });
    }
    throw e;
  });
  server.listen(PORT, "127.0.0.1", () => { if (!process.argv.includes("--no-open")) appWindow(`http://127.0.0.1:${PORT}/`); });
}
listen();
