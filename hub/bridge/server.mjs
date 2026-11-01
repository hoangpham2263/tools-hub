// Local bridge, shared by every tool: a tool POSTs a job over HTTP, the Tools Hub extension (hub/extension, in the
// user's own Chrome) receives it over WebSocket. ensure.mjs starts it and waits for the extension.
// Jobs go to the extension one at a time, from every tool and thread: a site only works while its tab is shown. A job
// waits its turn at most queueMs; its own time (timeoutSec) starts when it is sent.
// Listens on 127.0.0.1 only; nothing is exposed to the network.
import { createServer } from "node:http";
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { WebSocketServer } from "ws";

export const PORT = Number(process.env.BRIDGE_PORT || 8765);
const MIME = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp" };

// The Google account chosen on Cấu hình for Flow and Gemini (<hub>/workspace/config/google-account.json); "" is Google's
// default, the first one signed in.
const hubConfig = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "config", "google-account.json");
const chosenGoogleAccount = () => { try { return String(JSON.parse(readFileSync(hubConfig, "utf8")).email || ""); } catch { return ""; } };

// When this file was last changed, as the running bridge loaded it: after an update the app sees an older one and
// restarts it (POST /quit; ensure.mjs).
const code = Math.floor(statSync(fileURLToPath(import.meta.url)).mtimeMs);

// What the extension reports while it works, with the time: <hub>/workspace/logs/bridge.log (started again once over
// 1 MB), as the bridge runs detached with no output of its own.
const logFile = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "logs", "bridge.log");
function log(line) {
  try {
    mkdirSync(dirname(logFile), { recursive: true });
    const text = `${new Date().toISOString()} ${line}\n`;
    if (existsSync(logFile) && statSync(logFile).size > 1 << 20) writeFileSync(logFile, text); else appendFileSync(logFile, text);
  } catch {}
}

export function createBridge({ fetchImpl = fetch, googleAccount = chosenGoogleAccount, quit = () => process.exit(0), queueMs = 30 * 60000 } = {}) {
  let extension = null, extensionVersion = "";
  const pending = new Map();
  // Jobs waiting to be sent, and whether one is with the extension now.
  const waiting = [];
  let running = false;
  const jobs = () => waiting.length + (running ? 1 : 0);
  function next() {
    if (running || !waiting.length) return;
    const item = waiting.shift();
    clearTimeout(item.timer);
    running = true;
    item.run().then(item.resolve, item.reject).finally(() => { running = false; next(); });
  }
  const inTurn = (run) => new Promise((resolve, reject) => {
    const item = { run, resolve, reject };
    item.timer = setTimeout(() => { waiting.splice(waiting.indexOf(item), 1); reject(new Error("queue")); }, queueMs);
    waiting.push(item);
    next();
  });
  // One message to the extension and its answer ({ type: "result", id, ok, ... }).
  const ask = (message, ms) => new Promise((resolve, reject) => {
    const id = randomUUID();
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("timeout")); }, ms);
    timer.unref?.();
    pending.set(id, { resolve, timer });
    extension.send(JSON.stringify({ ...message, id }));
  });

  const server = createServer(async (req, res) => {
    const send = (status, body) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8" }); res.end(JSON.stringify(body)); };
    try {
      if (req.method === "GET" && req.url === "/status") return send(200, { extension: !!extension, extensionVersion: extension ? extensionVersion : "", code, pid: process.pid, jobs: jobs() });
      if (req.method === "POST" && req.url === "/quit") { send(200, { ok: true }); return setTimeout(quit, 100); }
      if (req.method === "POST" && req.url === "/reload") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        extension.send(JSON.stringify({ type: "reload" }));
        return send(200, { ok: true });
      }
      // Who is signed in to Google (Flow, Gemini) and ChatGPT in that Chrome, read by the extension: Cấu hình.
      if (req.method === "GET" && req.url === "/logins") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        const result = await ask({ type: "logins" }, 20000);
        return send(result.ok ? 200 : 502, result.ok ? { google: !!result.google, accounts: result.accounts || [], chatgpt: !!result.chatgpt } : { error: result.error });
      }
      // A page the tools open (Cấu hình: sign-in pages, Flow, Gemini), shown in the Tools Hub tab group: POST { url }.
      if (req.method === "POST" && req.url === "/open") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        let raw = "";
        for await (const chunk of req) raw += chunk;
        const url = String(JSON.parse(raw || "{}").url || "");
        if (!/^(https:\/\/|chrome:\/\/extensions)/.test(url)) return send(400, { error: "url must be https:// or chrome://extensions" });
        const result = await ask({ type: "open", url }, 15000);
        return send(result.ok ? 200 : 502, result.ok ? { ok: true } : { error: result.error });
      }
      // A run starts: the Tools Hub group's tabs are closed, so the run has only its own. Not while another tool's job
      // waits or runs (skipped: busy).
      if (req.method === "POST" && req.url === "/session") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        if (jobs()) return send(200, { ok: true, skipped: "busy" });
        const result = await ask({ type: "session" }, 15000);
        log(`session: ${result.ok ? `closed ${result.closed} tabs` : `error: ${result.error}`}`);
        return send(result.ok ? 200 : 502, result.ok ? { ok: true, closed: result.closed } : { error: result.error });
      }
      if (req.method !== "POST" || req.url !== "/generate") return send(404, { error: "not found" });
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const job = JSON.parse(raw);
      if (!["chatgpt", "flow", "gemini"].includes(job.platform)) return send(400, { error: "platform must be chatgpt, flow or gemini" });
      if (!job.prompt || !job.output) return send(400, { error: "prompt and output are required" });
      if (!extension) return send(503, { error: "Extension chưa kết nối. Mở Chrome có cài extension Tools Hub." });
      const images = await Promise.all((job.images || []).map(async (path, index) => ({
        name: `ref-${index + 1}${extname(path).toLowerCase()}`,
        mime: MIME[extname(path).toLowerCase()] || "application/octet-stream",
        data: (await readFile(path)).toString("base64"),
      })));
      const timeoutSec = Number(job.timeoutSec || 600);
      const account = job.platform === "chatgpt" ? "" : googleAccount();
      if (jobs()) log(`${job.platform} job waits for ${jobs()} before it`);
      const result = await inTurn(() => {
        if (!extension) return Promise.resolve({ ok: false, error: "Extension chưa kết nối. Mở Chrome có cài extension Tools Hub." });
        log(`${job.platform} job sent`);
        return ask({ type: "generate", platform: job.platform, prompt: job.prompt, images, timeoutSec, account }, (timeoutSec + 60) * 1000);
      });
      if (!result.ok) return send(502, { error: result.error });
      // Text replies (Gemini) are written as UTF-8 text.
      if (typeof result.text === "string") {
        await writeFile(job.output, result.text, "utf8");
        return send(200, { ok: true, output: job.output, chars: result.text.length, source: result.source || "" });
      }
      let bytes;
      if (result.data) bytes = Buffer.from(result.data, "base64");
      else {
        const response = await fetchImpl(result.url);
        if (!response.ok) return send(502, { error: `download ${response.status}` });
        bytes = Buffer.from(await response.arrayBuffer());
      }
      await writeFile(job.output, bytes);
      return send(200, { ok: true, output: job.output, bytes: bytes.length, source: result.source || "" });
    } catch (error) {
      if (error.message === "queue") return send(504, { error: `Hết thời gian chờ đến lượt (${Math.round(queueMs / 60000)} phút): các việc trước vẫn đang chạy trong Chrome.` });
      return send(error.message === "timeout" ? 504 : 500, { error: String(error.message || error) });
    }
  });

  const sockets = new WebSocketServer({ server });
  sockets.on("connection", (socket, req) => {
    // Only the Chrome extension may attach; web pages cannot spoof this origin.
    if (!String(req.headers.origin || "").startsWith("chrome-extension://")) return socket.close();
    extension = socket;
    socket.on("message", (data) => {
      let message;
      try { message = JSON.parse(data); } catch { return; }
      if (message.type === "hello") extensionVersion = String(message.version || "");
      if (message.type === "progress") log(`[${String(message.id).slice(0, 8)}] ${message.stage}`);
      if (message.type === "result" && pending.has(message.id)) {
        const { resolve, timer } = pending.get(message.id);
        clearTimeout(timer);
        pending.delete(message.id);
        if (message.type === "result" && !message.ok) log(`[${message.id.slice(0, 8)}] error: ${message.error}`);
        resolve(message);
      }
    });
    socket.on("close", () => { if (extension === socket) extension = null; });
  });
  return server;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("server.mjs")) {
  // Why a bridge stopped mid-run, kept across restarts: <hub>/workspace/logs/bridge-exit.log.
  const exitLog = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "logs", "bridge-exit.log");
  const note = (text) => { try { mkdirSync(dirname(exitLog), { recursive: true }); appendFileSync(exitLog, `${new Date().toISOString()} pid ${process.pid} ${text}\n`); } catch {} };
  // Started by an older run, its output can be that run's pipe, closed once the run ends: a later line must not stop it (EPIPE).
  for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});
  process.on("uncaughtException", (error) => { note(`crash: ${error?.stack || error}`); process.exit(1); });
  process.on("unhandledRejection", (error) => note(`unhandled rejection: ${error?.stack || error}`));
  for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) process.on(signal, () => { note(`stopped by ${signal}`); process.exit(0); });
  createBridge().listen(PORT, "127.0.0.1", () => console.log(`Bridge ready on http://127.0.0.1:${PORT}`));
}
