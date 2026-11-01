// Local bridge: the PowerShell workflow POSTs a job over HTTP, the extension receives it over WebSocket.
// Listens on 127.0.0.1 only; nothing is exposed to the network.
import { createServer } from "node:http";
import { appendFileSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { WebSocketServer } from "ws";

export const PORT = Number(process.env.BRIDGE_PORT || 8765);
const MIME = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp" };

// The Google account chosen on Cấu hình for Flow and Gemini (<hub>/workspace/config/google-account.json); "" is Google's
// default, the first one signed in.
const hubConfig = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "workspace", "config", "google-account.json");
const chosenGoogleAccount = () => { try { return String(JSON.parse(readFileSync(hubConfig, "utf8")).email || ""); } catch { return ""; } };

// When this file was last changed, as the running bridge loaded it: after an update the app sees an older one and
// restarts it (POST /quit; browser-bridge.ps1).
const code = Math.floor(statSync(fileURLToPath(import.meta.url)).mtimeMs);

export function createBridge({ fetchImpl = fetch, googleAccount = chosenGoogleAccount, quit = () => process.exit(0) } = {}) {
  let extension = null, extensionVersion = "";
  const pending = new Map();

  const server = createServer(async (req, res) => {
    const send = (status, body) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8" }); res.end(JSON.stringify(body)); };
    try {
      if (req.method === "GET" && req.url === "/status") return send(200, { extension: !!extension, extensionVersion: extension ? extensionVersion : "", code });
      if (req.method === "POST" && req.url === "/quit") { send(200, { ok: true }); return setTimeout(quit, 100); }
      if (req.method === "POST" && req.url === "/reload") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        extension.send(JSON.stringify({ type: "reload" }));
        return send(200, { ok: true });
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
      const id = randomUUID();
      const timeoutSec = Number(job.timeoutSec || 600);
      const result = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error("timeout")); }, (timeoutSec + 60) * 1000);
        pending.set(id, { resolve, timer });
        const account = job.platform === "chatgpt" ? "" : googleAccount();
        extension.send(JSON.stringify({ type: "generate", id, platform: job.platform, prompt: job.prompt, images, timeoutSec, account }));
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
      if (message.type === "progress") console.log(`[${message.id.slice(0, 8)}] ${message.stage}`);
      if (message.type === "result" && pending.has(message.id)) {
        const { resolve, timer } = pending.get(message.id);
        clearTimeout(timer);
        pending.delete(message.id);
        resolve(message);
      }
    });
    socket.on("close", () => { if (extension === socket) extension = null; });
  });
  return server;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("server.mjs")) {
  // Why a bridge stopped mid-run, kept across restarts: <tool>/workspace/logs/bridge-exit.log.
  const exitLog = join(dirname(fileURLToPath(import.meta.url)), "..", "workspace", "logs", "bridge-exit.log");
  const note = (text) => { try { mkdirSync(dirname(exitLog), { recursive: true }); appendFileSync(exitLog, `${new Date().toISOString()} pid ${process.pid} ${text}\n`); } catch {} };
  // Started by a run, its output is that run's pipe, closed once the run ends: a later line must not stop it (EPIPE).
  for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});
  process.on("uncaughtException", (error) => { note(`crash: ${error?.stack || error}`); process.exit(1); });
  process.on("unhandledRejection", (error) => note(`unhandled rejection: ${error?.stack || error}`));
  for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) process.on(signal, () => { note(`stopped by ${signal}`); process.exit(0); });
  createBridge().listen(PORT, "127.0.0.1", () => console.log(`Bridge ready on http://127.0.0.1:${PORT}`));
}
