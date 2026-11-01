// The app's window (src/mac/ui) served on localhost, on macOS and Windows alike, running the tool's PowerShell code.
// Application calls go to one long-lived PowerShell (rpc.ps1); a run is run-images.ps1.
import { createServer } from "node:http";
import { spawn, execFile } from "node:child_process";
import { createInterface } from "node:readline";
import { writeFile, mkdir, copyFile, rm, stat, appendFile, readFile } from "node:fs/promises";
import { createReadStream, existsSync, mkdirSync, openSync, renameSync, statSync, appendFileSync } from "node:fs";
import { join, dirname, extname, resolve, sep, basename } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { randomUUID, createHash } from "node:crypto";
import { createConfigApi } from "../../../../hub/setup/config-api.mjs";
import { PWSH, toolEnv, psFile, psCommand, killMatching, killTree, appWindow, chooseFiles } from "../../../../hub/platform.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..", "..");
// Tools Hub root: this tool is apps/<id>/ inside it (hub/update.ps1 updates the whole hub).
const hubRoot = resolve(root, "..", "..");
// Each install gets its own port (from its folder), so two copies on one Mac never share data.
const BASE_PORT = Number(process.env.PR_PORT || 47000 + (parseInt(createHash("sha1").update(resolve(here, "..", "..")).digest("hex").slice(0, 6), 16) % 1000));
let PORT = BASE_PORT;
const workspace = join(root, "workspace");
const logs = join(workspace, "logs");
const uploads = join(workspace, "temp", "mac-uploads");
const configApi = createConfigApi({ hubRoot, pwsh: PWSH, env: toolEnv });
// Errors from the window, this server and PowerShell go to workspace/logs (app-errors.log as Write-AppError
// writes it, mac-rpc.err.log), past 1 MB rolled over to *.old.log; Gửi lỗi sends them.
mkdirSync(logs, { recursive: true });
function logFile(name) {
  const file = join(logs, name);
  try { if (statSync(file).size > 1024 * 1024) renameSync(file, file.replace(/\.log$/, ".old.log")); } catch {}
  return file;
}
function logError(where, text) {
  try { appendFileSync(logFile("app-errors.log"), `[${new Date().toISOString()}] ${where}\n  ${String(text).trim().replace(/\n/g, "\n  ")}\n\n`); } catch {}
}
process.on("uncaughtException", (e) => { logError("Máy chủ Mac", e.stack || e); process.exit(1); });
process.on("unhandledRejection", (e) => logError("Máy chủ Mac", e?.stack || e));

const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".ico": "image/x-icon" };

// ----- PowerShell application calls -----
let rpcProc = null;
const waiting = new Map();
function startRpc() {
  rpcProc = spawn(PWSH, psFile(join(here, "rpc.ps1")), { cwd: root, env: toolEnv, windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
  createInterface({ input: rpcProc.stdout }).on("line", (line) => {
    if (!line.startsWith("@@RPC ")) return;
    const answer = JSON.parse(line.slice(6));
    const job = waiting.get(answer.id);
    if (!job) return;
    waiting.delete(answer.id);
    answer.ok ? job.resolve(answer.result) : job.reject(new Error(answer.error));
  });
  rpcProc.stderr.on("data", (d) => { try { appendFileSync(logFile("mac-rpc.err.log"), d); } catch {} });
  rpcProc.on("exit", () => {
    for (const job of waiting.values()) job.reject(new Error("PowerShell đã dừng."));
    waiting.clear();
    rpcProc = null;
  });
}
function rpc(cmd, args = {}) {
  if (!rpcProc) startRpc();
  const id = randomUUID();
  return new Promise((resolve, reject) => {
    waiting.set(id, { resolve, reject });
    rpcProc.stdin.write(JSON.stringify({ id, cmd, args }) + "\n");
  });
}

// ----- Batch run (src/run-images.ps1) -----
const run = { proc: null, events: [], index: 0, stopped: false, exitCode: null, resultFolder: "", logFile: "", errFile: "", done: false };
async function receive(line) {
  const event = await rpc("event", { line, index: run.index }).catch(() => null);
  if (!event) return;
  if (event.Kind === "Item") run.index = event.Index;
  if (event.Kind === "Output") run.resultFolder = event.Path;
  run.events.push(event);
}
async function startRun({ threads = 1, backend = "codex", text = "codex" }) {
  if (run.proc) throw new Error("Đang chạy.");
  await mkdir(logs, { recursive: true });
  const stamp = Date.now();
  Object.assign(run, { events: [], index: 0, stopped: false, exitCode: null, resultFolder: "", done: false,
    logFile: join(logs, `image-batch-mac-${stamp}.log`), errFile: join(logs, `image-batch-mac-${stamp}.err.log`) });
  const args = ["-ThrottleLimit", String(threads)];
  // Tạo ảnh: Codex, or Google Flow in the tools' own Chrome (bridge/ + hub/extension/).
  if (["flow", "chatgpt"].includes(backend)) args.push("-ImageBackend", backend);
  // Viết review: Codex, Gemini web in the same Chrome, or the Antigravity CLI, for every text step.
  if (["gemini", "antigravity"].includes(text)) args.push("-TextBackend", text);
  const map = join(workspace, "reference-inputs", "references.json");
  if (existsSync(map)) args.push("-ReferenceMapFile", map);
  // Own process group (macOS), so Dừng stops codex and every other child too.
  const proc = spawn(PWSH, psFile(join(root, "src", "run-images.ps1"), args), { cwd: root, env: toolEnv, detached: process.platform !== "win32", windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  run.proc = proc;
  let chain = Promise.resolve();
  for (const [stream, file] of [[proc.stdout, run.logFile], [proc.stderr, run.errFile]]) {
    createInterface({ input: stream }).on("line", (line) => {
      chain = chain.then(() => appendFile(file, line + "\n")).then(() => receive(line));
    });
  }
  proc.on("exit", (code) => {
    chain = chain.then(async () => {
      run.exitCode = code;
      // Keep the full run log inside its batch, as the Windows app does.
      if (run.resultFolder && existsSync(run.resultFolder)) {
        const batchLogs = join(run.resultFolder, "logs");
        await mkdir(batchLogs, { recursive: true });
        for (const [from, name] of [[run.logFile, "run.log"], [run.errFile, "run.err.log"]]) {
          if (existsSync(from) && (await stat(from)).size) await copyFile(from, join(batchLogs, name));
          await rm(from, { force: true });
        }
      }
      run.proc = null;
      run.done = true;
    });
  });
}
function stopRun() {
  if (!run.proc) return;
  run.stopped = true;
  killTree(run.proc);
}

// ----- Tải về máy in the background (src/sync-source.ps1, as on Windows); the window polls its status file -----
const sync = { proc: null, statusFile: join(logs, "sync-status-mac.json") };
async function startSync(groups) {
  if (sync.proc) return false;
  await rm(sync.statusFile, { force: true });
  const out = openSync(logFile("mac-sync.log"), "a");
  sync.proc = spawn(PWSH, psFile(join(root, "src", "sync-source.ps1"), ["-Group", groups.join("|"), "-StatusFile", sync.statusFile]), { cwd: root, env: toolEnv, windowsHide: true, stdio: ["ignore", out, out] });
  sync.proc.on("exit", () => { sync.proc = null; });
  return true;
}
async function syncState() {
  const status = await readFile(sync.statusFile, "utf8").then(JSON.parse).catch(() => null);
  return { running: !!sync.proc, status };
}

// ----- Nhập hàng loạt in the background (src/import-batch.ps1, as on Windows); the dialog polls its status file -----
const imports = { proc: null, statusFile: join(logs, "import-status-mac.json"), inputFile: join(logs, "import-input-mac.csv") };
async function startImport(text, folder) {
  if (imports.proc) return false;
  await rm(imports.statusFile, { force: true });
  await writeFile(imports.inputFile, text, "utf8");
  const out = openSync(logFile("mac-import.log"), "a");
  imports.proc = spawn(PWSH, psFile(join(root, "src", "import-batch.ps1"), ["-File", imports.inputFile, "-Folder", folder, "-StatusFile", imports.statusFile]), { cwd: root, env: toolEnv, windowsHide: true, stdio: ["ignore", out, out] });
  imports.proc.on("exit", () => { imports.proc = null; rm(imports.inputFile, { force: true }).catch(() => {}); });
  return true;
}

// ----- Gửi lỗi: src/support-report.mjs in its own process (Codex may take 2 minutes); its output lines are the progress -----
const errorsSend = { proc: null, outFile: join(logs, "send-errors-mac.out") };
async function startSendErrors() {
  if (errorsSend.proc) return false;
  await rm(errorsSend.outFile, { force: true });
  const out = openSync(errorsSend.outFile, "a");
  errorsSend.proc = spawn(process.execPath, [join(root, "src", "support-report.mjs")], { cwd: root, env: toolEnv, windowsHide: true, stdio: ["ignore", out, out] });
  errorsSend.proc.on("error", (error) => { appendFileSync(errorsSend.outFile, `error|${error.message.replace(/[\r\n|]/g, " ")}\n`); errorsSend.proc = null; });
  errorsSend.proc.on("close", () => { errorsSend.proc = null; });
  return true;
}

// ----- HTTP -----
const allowedFile = (p) => {
  const full = resolve(p);
  return [root + sep, resolve(tmpdir()) + sep].some((base) => full.startsWith(base)) && TYPES[extname(full).toLowerCase()]?.startsWith("image/");
};
const body = async (req) => { const chunks = []; for await (const c of req) chunks.push(c); return Buffer.concat(chunks); };
const send = (res, status, data) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }); res.end(JSON.stringify(data)); };

async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  const path = url.pathname;
  if (path === "/api/root") return send(res, 200, { root, service: "product-review", protocol: 1, pid: process.pid });
  // Errors in the window (app.js), kept like the Windows window's.
  if (path === "/api/client-error" && req.method === "POST") {
    const { message = "", stack = "" } = JSON.parse((await body(req)).toString("utf8") || "{}");
    logError("Giao diện Mac", [message, stack].filter(Boolean).join("\n").slice(0, 4000));
    return send(res, 200, { ok: true });
  }
  // Menu bar star: Mở cửa sổ / Thoát.
  if (path === "/api/open" && req.method === "POST") { openWindow(); return send(res, 200, { ok: true }); }
  if (path === "/api/quit" && req.method === "POST") {
    send(res, 200, { ok: true });
    stopRun();
    sync.proc?.kill();
    rpcProc?.kill();
    setTimeout(() => process.exit(0), 200);
    return;
  }
  if (path === "/api/rpc" && req.method === "POST") {
    const { cmd, args } = JSON.parse((await body(req)).toString("utf8"));
    try { return send(res, 200, { result: await rpc(cmd, args) }); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/upload" && req.method === "POST") {
    // Pasted, dropped or picked images become local files the PowerShell code can snapshot.
    const name = (url.searchParams.get("name") || "image.png").replace(/[^\w.-]/g, "_");
    const ext = extname(name).toLowerCase();
    if (![".png", ".jpg", ".jpeg"].includes(ext) && !([".zip", ".rar", ".7z"].includes(ext) && url.searchParams.get("import"))) return send(res, 400, { error: "Chọn ảnh PNG hoặc JPEG." });
    // import=<id>: an image of a dropped import folder, kept by its own name in <uploads>/import-<id>/images.
    const id = (url.searchParams.get("import") || "").replace(/[^\w]/g, "");
    const dir = id ? join(uploads, `import-${id}`, "images") : uploads;
    await mkdir(dir, { recursive: true });
    const file = join(dir, id ? basename(url.searchParams.get("name") || "") : `${randomUUID().replace(/-/g, "")}${ext}`);
    await writeFile(file, await body(req));
    return send(res, 200, { path: file, folder: id ? dirname(dir) : "" });
  }
  if (path === "/api/sync" && req.method === "POST") {
    const { groups = [] } = JSON.parse((await body(req)).toString("utf8") || "{}");
    const names = groups.map(String).filter((g) => /^[\p{L}\p{N}][\p{L}\p{N} -]{0,59}$/u.test(g));
    if (!names.length) return send(res, 400, { error: "Chưa chọn danh mục." });
    return (await startSync(names)) ? send(res, 200, { ok: true }) : send(res, 409, { error: "Đang có một lượt tải về máy." });
  }
  if (path === "/api/sync" && req.method === "GET") return send(res, 200, await syncState());
  if (path === "/api/import" && req.method === "POST") {
    const { text = "", folder = "" } = JSON.parse((await body(req)).toString("utf8") || "{}");
    return (await startImport(String(text), String(folder))) ? send(res, 200, { ok: true }) : send(res, 409, { error: "Đang có một lượt nhập." });
  }
  if (path === "/api/import" && req.method === "GET") {
    const status = await readFile(imports.statusFile, "utf8").then(JSON.parse).catch(() => null);
    return send(res, 200, { running: !!imports.proc, status });
  }
  if (path === "/api/send-errors" && req.method === "POST") return (await startSendErrors()) ? send(res, 200, { ok: true }) : send(res, 409, { error: "Đang gửi lỗi." });
  if (path === "/api/send-errors" && req.method === "GET") {
    const lines = (await readFile(errorsSend.outFile, "utf8").catch(() => "")).split("\n").map((l) => l.trim()).filter((l) => /^(step|sent|saved|error)\|/.test(l));
    return send(res, 200, { running: !!errorsSend.proc, last: lines.at(-1) || "" });
  }
  if (path === "/api/import" && req.method === "DELETE") { try { imports.proc?.kill("SIGKILL"); } catch {} return send(res, 200, { ok: true }); }
  if (path === "/api/run" && req.method === "POST") {
    try { await startRun(JSON.parse((await body(req)).toString("utf8") || "{}")); return send(res, 200, { ok: true }); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/run" && req.method === "GET") {
    const since = Number(url.searchParams.get("since") || 0);
    return send(res, 200, { running: !!run.proc, done: run.done, exitCode: run.exitCode, stopped: run.stopped, resultFolder: run.resultFolder, events: run.events.slice(since), next: run.events.length });
  }
  if (path === "/api/stop" && req.method === "POST") { stopRun(); return send(res, 200, { ok: true }); }
  // Cấu hình is the hub's, shared by every tool (hub/setup/config-api.mjs).
  if (await configApi(req, res, path)) return;
  if (path === "/api/choose-images" && req.method === "POST") {
    // The system file dialog: opens the app's own folder and returns real paths (no copy through the browser).
    // table: a CSV or ZIP / RAR / 7Z archive for Nhập hàng loạt instead of images.
    const { folder = "", table = false } = JSON.parse((await body(req)).toString("utf8") || "{}");
    chooseFiles({ folder, table }, (paths) => send(res, 200, { paths }));
    return;
  }
  if (path === "/api/reload" && req.method === "POST") {
    // Tải lại: a fresh server on the files as they are now; the page reloads once it answers again. Not mid-run.
    if (run.proc) return send(res, 409, { error: "Đang chạy. Dừng hoặc chờ xong rồi tải lại." });
    send(res, 200, { ok: true });
    setTimeout(() => {
      const out = openSync(logFile("mac-server.log"), "a");
      server.close();
      spawn(process.execPath, [join(here, "server.mjs"), "--no-open"], { cwd: root, detached: true, windowsHide: true, stdio: ["ignore", out, out], env: { ...process.env, PR_WAIT_PORT: "1" } }).unref();
      rpcProc?.kill();
      setTimeout(() => process.exit(0), 300);
    }, 300);
    return;
  }
  if (path === "/api/update" && req.method === "POST") {
    // Update the files, then start a fresh server on the new code; the page reloads itself.
    execFile(PWSH, psCommand(`. '${join(hubRoot, "hub", "update.ps1").replace(/'/g, "''")}' -NoRun; Update-App '${hubRoot.replace(/'/g, "''")}'`), { cwd: hubRoot, env: toolEnv, timeout: 300000, windowsHide: true }, (err) => {
      if (err) return send(res, 500, { error: err.message });
      send(res, 200, { ok: true });
      setTimeout(() => {
        const out = openSync(logFile("mac-server.log"), "a");
        spawn(process.execPath, [join(here, "server.mjs"), "--no-open"], { cwd: root, detached: true, windowsHide: true, stdio: ["ignore", out, out], env: { ...process.env, PR_WAIT_PORT: "1" } }).unref();
        rpcProc?.kill();
        // The Tools Hub menu runs on the old files too: restart it, without a window of its own.
        const picker = join(hubRoot, "hub", "picker.mjs");
        if (existsSync(picker)) {
          killMatching(picker, () => spawn(process.execPath, [picker], { cwd: hubRoot, detached: true, windowsHide: true, stdio: "ignore", env: { ...process.env, HUB_NO_WINDOW: "1", HUB_WAIT_PORT: "1" } }).unref());
        }
        setTimeout(() => process.exit(0), 300);
      }, 300);
    });
    return;
  }
  if (path === "/file") {
    const file = url.searchParams.get("path") || "";
    if (!allowedFile(file) || !existsSync(file)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { "content-type": TYPES[extname(file).toLowerCase()], "cache-control": "no-store" });
    return createReadStream(file).pipe(res);
  }
  const rel = path === "/" ? "index.html" : path.slice(1);
  const file = resolve(here, "ui", rel);
  if (!file.startsWith(resolve(here, "ui") + sep) || !existsSync(file)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": TYPES[extname(file).toLowerCase()] || "application/octet-stream", "cache-control": "no-store" });
  createReadStream(file).pipe(res);
}

// A star in the macOS menu bar while the app runs (src/mac/menubar.js); it goes away with the server.
let menuBar = null;
function startMenuBar() {
  if (process.platform !== "darwin" || process.env.PR_NO_MENUBAR) return;
  menuBar = spawn("osascript", ["-l", "JavaScript", join(here, "menubar.js")], { env: { ...process.env, PR_PORT: String(PORT) }, stdio: "ignore" });
  menuBar.on("error", () => { menuBar = null; });
}
process.on("exit", () => { try { menuBar?.kill(); } catch {} });

// Its own window on macOS (hub/platform.mjs); on Windows the launcher's app window shows it.
const openWindow = () => appWindow(`http://127.0.0.1:${PORT}/`);

const server = createServer((req, res) => handle(req, res).catch((e) => send(res, 500, { error: e.message })));
function listen(attempt = 0) {
  server.once("error", (e) => {
    // Already running (or the old server is still closing after an update).
    if (e.code === "EADDRINUSE" && process.env.PR_WAIT_PORT && attempt < 50) return setTimeout(() => listen(attempt + 1), 200);
    if (e.code === "EADDRINUSE") {
      // Already running for this folder: just show its window. Another program on the port: try the next one.
      return fetch(`http://127.0.0.1:${PORT}/api/root`).then((r) => r.json()).then((body) => {
        if (body.root !== root) throw new Error("other");
        if (!process.argv.includes("--no-open")) openWindow();
        process.exit(0);
      }).catch(() => {
        if (PORT - BASE_PORT >= 20) throw e;
        PORT++;
        listen(attempt);
      });
    }
    throw e;
  });
  server.listen(PORT, "127.0.0.1", () => { startMenuBar(); if (!process.argv.includes("--no-open")) openWindow(); });
}
startRpc();
listen();
