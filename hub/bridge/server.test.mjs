import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { createBridge } from "./server.mjs";

async function start(fetchImpl, googleAccount = () => "") {
  const server = createBridge({ fetchImpl, googleAccount });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, base: `http://127.0.0.1:${server.address().port}`, ws: `ws://127.0.0.1:${server.address().port}` };
}

async function fakeExtension(url, answer) {
  const socket = new WebSocket(url, { origin: "chrome-extension://test" });
  socket.on("message", (data) => {
    const job = JSON.parse(data);
    socket.send(JSON.stringify({ type: "result", id: job.id, ...answer(job) }));
  });
  await new Promise((resolve) => socket.on("open", resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
  return socket;
}

test("forwards a job with reference images and writes the returned image", async () => {
  const { server, base, ws } = await start();
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  await writeFile(join(dir, "ref.png"), Buffer.from([1, 2, 3]));
  let received;
  const socket = await fakeExtension(ws, (job) => { received = job; return { ok: true, data: Buffer.from("PNGDATA").toString("base64") }; });
  const output = join(dir, "out.png");
  const response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "chatgpt", prompt: "p", images: [join(dir, "ref.png")], output }) });
  assert.equal(response.status, 200);
  assert.equal(received.images.length, 1);
  assert.equal(received.images[0].mime, "image/png");
  assert.equal((await readFile(output)).toString(), "PNGDATA");
  socket.close(); server.close();
});

test("downloads signed URLs returned by Flow", async () => {
  const { server, base, ws } = await start(async (url) => ({ ok: url === "https://flow-content.google/image/x?Signature=s", arrayBuffer: async () => Buffer.from("FLOW") }));
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const socket = await fakeExtension(ws, () => ({ ok: true, url: "https://flow-content.google/image/x?Signature=s" }));
  const output = join(dir, "out.png");
  const response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "flow", prompt: "p", output }) });
  assert.equal(response.status, 200);
  assert.equal((await readFile(output)).toString(), "FLOW");
  socket.close(); server.close();
});

test("Flow and Gemini jobs carry the Google account chosen on Cấu hình; ChatGPT jobs do not", async () => {
  const { server, base, ws } = await start(undefined, () => "second@gmail.com");
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const seen = {};
  const socket = await fakeExtension(ws, (job) => { seen[job.platform] = job.account; return job.platform === "gemini" ? { ok: true, text: "t" } : { ok: true, data: Buffer.from("x").toString("base64") }; });
  for (const platform of ["gemini", "chatgpt"]) {
    const response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform, prompt: "p", output: join(dir, `${platform}.out`) }) });
    assert.equal(response.status, 200);
  }
  assert.equal(seen.gemini, "second@gmail.com");
  assert.equal(seen.chatgpt, "");
  socket.close(); server.close();
});

test("reports extension errors and rejects non-extension sockets", async () => {
  const { server, base, ws } = await start();
  const page = new WebSocket(ws, { origin: "https://evil.example" });
  await new Promise((resolve) => page.on("close", resolve));
  let response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "chatgpt", prompt: "p", output: "/tmp/x.png" }) });
  assert.equal(response.status, 503);
  const socket = await fakeExtension(ws, () => ({ ok: false, error: "ChatGPT chưa đăng nhập." }));
  response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "chatgpt", prompt: "p", output: "/tmp/x.png" }) });
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /đăng nhập/);
  socket.close(); server.close();
});
