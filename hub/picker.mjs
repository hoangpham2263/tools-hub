// Tools Hub menu (the launcher runs it when there is more than one tool): one app window lists apps/*/tool.json
// with each tool's icon, and a tool opens in that same window. The window is a Chrome app window on macOS and
// hub/launch.ps1's WebView2 window on Windows (HUB_NO_WINDOW). Web tools are served from here;
// a tool with its own server ("mac", e.g. Product Review) is started and the window moves to it. Each tool shows a
// "← Menu" button back here (?hub=<port>). One menu per install: a second start just opens a window on it.
import { createServer } from "node:http";
import { spawn, execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, existsSync, openSync, mkdirSync, statSync } from "node:fs";
import { basename, dirname, join, resolve, extname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createConfigApi } from "./setup/config-api.mjs";
import { PWSH, toolEnv, psCommand, killMatching, appWindow } from "./platform.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const portFor = (dir, base) => base + (parseInt(createHash("sha1").update(dir).digest("hex").slice(0, 6), 16) % 1000);
// HUB_PICKER_PORT (tests, the Windows launcher hub/launch.ps1): a fixed port and no window.
const PORT = Number(process.env.HUB_PICKER_PORT) || portFor(root, 46000);
const tools = readdirSync(join(root, "apps"), { withFileTypes: true })
  .filter((d) => d.isDirectory() && existsSync(join(root, "apps", d.name, "tool.json")))
  .map((d) => ({ ...JSON.parse(readFileSync(join(root, "apps", d.name, "tool.json"), "utf8")), dir: join(root, "apps", d.name) }))
  .sort((a, b) => (a.order ?? 99) - (b.order ?? 99) || a.dir.localeCompare(b.dir));
// The installed version, as Get-InstalledVersion reads it (workspace/version.txt, or the last tag in a Git checkout);
// every page the menu serves shows it in its window title (hub.js).
const version = (() => {
  try { return readFileSync(join(root, "workspace", "version.txt"), "utf8").trim(); }
  catch { try { return execFileSync("git", ["-C", root, "describe", "--tags", "--abbrev=0"], { stdio: ["ignore", "pipe", "ignore"] }).toString().trim(); } catch { return ""; } }
})();
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// tool.json: "platforms" [{ name, color }] it works with, "features" a few short lines, "status": "dev" while a tool
// does not work yet (badge Đang phát triển; it still opens, for working on it).
const card = (t) => `<span class="top"><img src="/icon/${esc(t.id)}" alt=""><span><span class="name">${esc(t.name)}${t.status === "dev" ? ' <span class="dev">Đang phát triển</span>' : ""}</span>`
  + `<span class="plat">${(t.platforms || []).map((p) => `<span style="--c:${esc(p.color || "#888")}"><i></i>${esc(p.name)}</span>`).join("")}</span></span></span>`
  + `<ul>${(t.features || []).map((f) => `<li>${esc(f)}</li>`).join("")}</ul>`;
const page = () => `<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(`Tools Hub ${version}`.trim())}</title><link rel="icon" href="/hub/icon.svg">
<script>(() => { try { const s = localStorage.getItem("themeMode"); if (s ? s === "dark" : matchMedia("(prefers-color-scheme: dark)").matches) document.documentElement.classList.add("dark"); } catch (_) {} })();</script>
<link rel="stylesheet" href="/setup/ui/fonts/fonts.css"><link rel="stylesheet" href="/setup/ui/vendor/basecoat/basecoat.min.css"><link rel="stylesheet" href="/setup/ui/ui.css">
<style>
/* Tools in a 3-column grid: icon, name and the platforms it works with, then what it does. */
.wrap{max-width:1120px;margin:0 auto;padding:20px 24px 24px;display:flex;flex-direction:column;gap:16px;min-height:100vh}.wrap>main{flex:1;display:flex;flex-direction:column;gap:16px}
.top{display:flex;align-items:center;gap:8px}.top h1{margin-right:auto;padding-left:4px}
.tools{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.tools form{margin:0;display:flex}
.tools button{position:relative;display:flex;flex-direction:column;align-items:stretch;width:100%;min-height:190px;padding:16px;text-align:left;font:inherit;color:inherit;background:var(--card);border:1px solid var(--border);border-radius:var(--radius-xl,14px)}
.tools button:hover{border-color:var(--state-border);background:var(--state-fill)}
.tools .top{display:flex;gap:12px;align-items:center}.tools img{width:48px;height:48px;flex:none}
.tools .name{display:block;font-size:1rem;line-height:1.3}
.tools .dev{display:inline-block;margin-left:6px;padding:1px 7px;border:1px solid var(--border);border-radius:9999px;font-size:11px;color:var(--muted-foreground);vertical-align:2px}
.tools .is-dev button{opacity:.75}.tools .is-dev button:hover{opacity:1}
.tools .plat{display:flex;flex-wrap:wrap;gap:2px 8px;margin-top:3px;font-size:.75rem;color:var(--muted-foreground)}.tools .plat span{display:inline-flex;align-items:center;gap:4px;white-space:nowrap}
.tools .plat i{width:7px;height:7px;border-radius:50%;background:var(--c)}
.tools ul{list-style:none;margin:14px 0 0;padding:12px 0 0;border-top:1px solid var(--border);font-size:.8125rem;line-height:1.75}
.tools li{position:relative;padding-left:20px}.tools li::before{content:"✓";position:absolute;left:2px;color:var(--primary)}
@media (max-width:900px){.tools{grid-template-columns:repeat(2,minmax(0,1fr))}}
footer{text-align:center;font-size:.75rem}</style><script src="/hub/hub.js" defer></script></head>
<body><div class="wrap"><main><header class="top"><h1>Tools Hub</h1></header><div class="setup-status" id="setupStatus" role="status"></div><section class="card"><header><h2>Công cụ</h2></header><section><div class="tools">
${tools.map((t) => `<form method="post" action="/open/${esc(t.id)}"${t.status === "dev" ? ' class="is-dev"' : ""}><button type="submit" title="${esc(t.description)}">${card(t)}</button></form>`).join("")}
</div></section></section></main><footer class="muted">© ${new Date().getFullYear()} Tools Hub</footer></div></body></html>`;

// A tool with its own server: its address when it is running, else "".
async function findServer(tool) {
  const base = portFor(tool.dir, 47000);
  for (let port = base; port <= base + 20; port++) {
    const body = await fetch(`http://127.0.0.1:${port}/api/root`).then((r) => r.json()).catch(() => null);
    if (body?.root === tool.dir) return `http://127.0.0.1:${port}/`;
  }
  return "";
}
// Start it without a window of its own (or find it running) and return its address.
async function startServer(tool) {
  const find = () => findServer(tool);
  let url = await find();
  if (url) return url;
  const logs = join(root, "workspace", basename(tool.dir), "logs");
  mkdirSync(logs, { recursive: true });
  const out = openSync(join(logs, "mac-server.log"), "a");
  spawn(process.execPath, [join(tool.dir, tool.mac), "--no-open"], { cwd: tool.dir, detached: true, windowsHide: true, stdio: ["ignore", out, out] }).unref();
  for (let i = 0; i < 60 && !url; i++) { await new Promise((r) => setTimeout(r, 250)); url = await find(); }
  return url;
}

const ASSETS = ["icon.svg", "hub.js"];
const q = (p) => p.replace(/'/g, "''");
const configApi = createConfigApi({ hubRoot: root, pwsh: PWSH, env: toolEnv });
const pwsh = (command) => new Promise((done, fail) => execFile(PWSH, psCommand(command), { cwd: root, timeout: 300000, windowsHide: true }, (err, out) => (err ? fail(err) : done(String(out).trim()))));
// The tools' servers, stopped before an update and when the Windows app window closes.
const stopServers = () => Promise.all(tools.filter((t) => t.mac).map((t) => new Promise((done) => killMatching(join(t.dir, t.mac), done))));

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json" };
function sendFile(res, file) {
  if (!existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream", "cache-control": "no-store" });
  res.end(readFileSync(file));
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const parts = url.pathname.split("/").map(decodeURIComponent);
  if (url.pathname === "/") { res.writeHead(200, { "content-type": TYPES[".html"] }); return res.end(page()); }
  if (url.pathname === "/api/root") { res.writeHead(200, { "content-type": TYPES[".json"], "cache-control": "no-store" }); return res.end(JSON.stringify({ root, hub: true, version, service: "tools-hub-picker", protocol: 1, pid: process.pid })); }
  // Shared files: /hub/<name>, or /hub/assets/<name> as web tools link them (../../../hub/assets/<name>).
  if (parts[1] === "hub") return ASSETS.includes(parts.at(-1)) ? sendFile(res, join(here, "assets", parts.at(-1))) : (res.writeHead(404), res.end());
  if (await configApi(req, res, url.pathname)) return;
  if (url.pathname === "/api/update-check") {
    const out = await pwsh(`. '${q(join(here, "update.ps1"))}' -NoRun; [pscustomobject]@{ current = (Get-InstalledVersion '${q(root)}'); next = (Get-AppUpdate '${q(root)}') } | ConvertTo-Json -Compress`).catch(() => "");
    res.writeHead(out ? 200 : 502, { "content-type": TYPES[".json"] });
    return res.end(out || "{}");
  }
  if (url.pathname === "/api/update" && req.method === "POST") {
    // Install, stop the tools' servers still on the old files, then start a fresh menu on the new ones.
    const ok = await pwsh(`. '${q(join(here, "update.ps1"))}' -NoRun; Update-App '${q(root)}'`).then(() => true, () => false);
    res.writeHead(ok ? 200 : 500, { "content-type": TYPES[".json"] });
    res.end(JSON.stringify({ ok }));
    if (!ok) return;
    stopServers();
    return setTimeout(() => {
      server.close();
      spawn(process.execPath, [join(here, "picker.mjs")], { cwd: root, detached: true, windowsHide: true, stdio: "ignore", env: { ...process.env, HUB_NO_WINDOW: "1", HUB_WAIT_PORT: "1" } }).unref();
      process.exit(0);
    }, 300);
  }
  if (url.pathname === "/api/reload" && req.method === "POST") {
    // Tải lại: a fresh menu on the files as they are now (the page reloads once it answers again). Tool servers keep
    // running; each tool's own Tải lại restarts it.
    res.writeHead(200, { "content-type": TYPES[".json"] });
    res.end(JSON.stringify({ ok: true }));
    return setTimeout(() => {
      server.close();
      spawn(process.execPath, [join(here, "picker.mjs")], { cwd: root, detached: true, windowsHide: true, stdio: "ignore", env: { ...process.env, HUB_NO_WINDOW: "1", HUB_WAIT_PORT: "1" } }).unref();
      process.exit(0);
    }, 300);
  }
  if (url.pathname === "/api/quit" && req.method === "POST") {
    // The Windows app window closed: the tools' servers stop their runs and quit, then this menu.
    res.writeHead(200, { "content-type": TYPES[".json"] });
    res.end("{}");
    await Promise.all(tools.filter((t) => t.mac).map((t) => findServer(t).then((u) => u && fetch(`${u}api/quit`, { method: "POST" })).catch(() => {})));
    return setTimeout(() => process.exit(0), 300);
  }
  const tool = tools.find((t) => t.id === parts[2]);
  if (tool && parts[1] === "icon") return sendFile(res, join(tool.dir, tool.icon || "icon.svg"));
  if (tool && parts[1] === "apps") {
    const file = resolve(tool.dir, ...parts.slice(3));
    return file.startsWith(tool.dir + sep) ? sendFile(res, file) : (res.writeHead(404), res.end());
  }
  if (tool && parts[1] === "open" && req.method === "POST") {
    const target = tool.web ? `/apps/${encodeURIComponent(tool.id)}/${tool.web}?hub=${PORT}` : await startServer(tool).then((u) => (u ? `${u}?hub=${PORT}` : ""));
    if (!target) { res.writeHead(500, { "content-type": TYPES[".html"] }); return res.end(`<meta charset="utf-8"><link rel="stylesheet" href="/setup/ui/vendor/basecoat/basecoat.min.css"><link rel="stylesheet" href="/setup/ui/ui.css"><main class="page stack"><header><h1>Không mở được ${esc(tool.name)}</h1></header><a class="btn" href="/">← Menu</a></main>`); }
    res.writeHead(303, { location: target });
    return res.end();
  }
  res.writeHead(404); res.end();
});
function listen(attempt = 0) {
  server.once("error", (e) => {
    if (e.code !== "EADDRINUSE") throw e;
    // Restarting after an update: wait for the old menu to let go of the port.
    if (process.env.HUB_WAIT_PORT && attempt < 50) return setTimeout(() => listen(attempt + 1), 200);
    // Already running for this install: just show its window.
    fetch(`http://127.0.0.1:${PORT}/api/root`).then((r) => r.json()).then((b) => { if (b.root === root) appWindow(`http://127.0.0.1:${PORT}/`); process.exit(0); }, () => process.exit(1));
  });
  server.listen(PORT, "127.0.0.1", () => process.env.HUB_PICKER_PORT || process.env.HUB_NO_WINDOW || appWindow(`http://127.0.0.1:${PORT}/`));
}
listen();
