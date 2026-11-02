import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { cleanName } from "./index.js";

// In-memory KV, edge cache and Google endpoints.
function setup() {
  const kv = new Map([["refresh_token", "r"]]);
  const meta = new Map();
  const env = {
    ADMIN_PASSWORD: "secret", APP_PASSWORD: "app-pass", GOOGLE_CLIENT_ID: "id", GOOGLE_CLIENT_SECRET: "s",
    STORE: {
      get: async (k, type) => (kv.has(k) ? (type === "json" ? JSON.parse(kv.get(k)) : kv.get(k)) : null),
      put: async (k, v, opts) => { kv.set(k, v); if (opts?.metadata) meta.set(k, opts.metadata); },
      delete: async (k) => { kv.delete(k); meta.delete(k); },
      list: async ({ prefix }) => ({ keys: [...kv.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name, metadata: meta.get(name) })), list_complete: true }),
    },
  };
  const files = new Map();
  // Drive metadata for list queries: id -> { name, parents, folder, mime }.
  const nodes = new Map();
  globalThis.caches = { default: { match: async () => null, put: async () => {}, delete: async () => {} } };
  globalThis.fetch = async (url, init = {}) => {
    url = String(url);
    if (url.includes("oauth2.googleapis.com/token")) return Response.json({ access_token: "a", expires_in: 3600 });
    if (url.includes("/drive/v3/files?fields=id")) {
      const meta = JSON.parse(init.body);
      const id = `folder-${nodes.size}`;
      nodes.set(id, { name: meta.name, parents: meta.parents || [], folder: true });
      return Response.json({ id });
    }
    if (url.includes("/drive/v3/files?q=")) {
      const q = new URL(url).searchParams.get("q");
      const parent = q.match(/^'([^']+)' in parents/)[1];
      const name = q.match(/name = '((?:[^'\\]|\\.)*)'/)?.[1];
      const list = [...nodes].filter(([, n]) => n.parents.includes(parent) && (!name || n.name === name) &&
        (!q.includes("mimeType = ") || n.folder) && (!q.includes("mimeType != ") || !n.folder));
      return Response.json({ files: list.map(([id, n]) => ({ id, name: n.name, mimeType: n.mime, size: "1", md5Checksum: "m" + id })) });
    }
    const metaOnly = url.match(/files\/([\w-]+)\?fields=parents/);
    if (metaOnly) return Response.json({ name: nodes.get(metaOnly[1])?.name, parents: nodes.get(metaOnly[1])?.parents || [] });
    if (url.includes("/upload/drive/v3/files")) {
      // Keep only the media part of the multipart/related body, as Drive does.
      const body = new Uint8Array(await new Response(init.body).arrayBuffer());
      const text = new TextDecoder("latin1").decode(body);
      const start = text.indexOf("\r\n\r\n", text.indexOf("content-type:", text.indexOf("--", 2))) + 4;
      const end = text.lastIndexOf("\r\n--");
      const id = `file-${files.size}`;
      const meta = JSON.parse(text.slice(text.indexOf("{"), text.indexOf("}") + 1));
      const mime = text.slice(start - 4).length && text.match(/content-type: (image\/\w+)/)?.[1];
      files.set(id, body.slice(start, end));
      nodes.set(id, { name: meta.name, parents: meta.parents, mime });
      return Response.json({ id });
    }
    if (url.startsWith("https://img.test/")) return url.endsWith(".txt") ? new Response("x", { headers: { "content-type": "text/plain" } }) : new Response("remote", { headers: { "content-type": "image/jpeg" } });
    const media = url.match(/files\/([\w-]+)\?alt=media/);
    if (media) return new Response(files.get(media[1]), { headers: { "content-type": nodes.get(media[1])?.mime || "image/png" } });
    if (init.method === "PATCH" && url.includes("/drive/v3/files/")) {
      const u = new URL(url), id = u.pathname.split("/").pop(), node = nodes.get(id);
      const body = JSON.parse(init.body || "{}");
      if (body.name) node.name = body.name;
      const add = u.searchParams.get("addParents"), remove = u.searchParams.get("removeParents");
      if (add) node.parents = [...node.parents.filter((p) => p !== remove), add];
      return Response.json({ id });
    }
    if (init.method === "DELETE") { const id = url.split("/files/")[1]; files.delete(id); nodes.delete(id); return new Response(null, { status: 204 }); }
    throw new Error(`unexpected ${url}`);
  };
  const ctx = { waitUntil: () => {} };
  env.__nodes = nodes; env.__kv = kv;
  const call = (path, init = {}) => worker.fetch(new Request(`https://api.test${path}`, init), env, ctx);
  return { call, files, kv , env };
}

test("upload stores the image in Drive and serves it from a public link", async () => {
  const { call } = setup();
  const png = new Uint8Array([137, 80, 78, 71]);
  const created = await call("/api/images?batch=2026-10-27_x&name=001-tee.png&product=tee", { method: "POST", headers: { "x-admin-key": "secret" }, body: png });
  assert.equal(created.status, 201);
  const item = await created.json();
  assert.match(item.url, /^https:\/\/api\.test\/img\/\w+\.png$/);
  const image = await call(new URL(item.url).pathname);
  assert.equal(image.status, 200);
  assert.deepEqual(new Uint8Array(await image.arrayBuffer()), png);
});

test("writes need the admin key; review status and delete work", async () => {
  const { call, files } = setup();
  assert.equal((await call("/api/images", { method: "POST", body: "x" })).status, 401);
  assert.equal((await call("/api/images")).status, 401);
  const item = await (await call("/api/images?batch=b&name=a.png", { method: "POST", headers: { "x-admin-key": "secret" }, body: "x" })).json();
  const patched = await call(`/api/images/${item.id}`, { method: "PATCH", headers: { "x-admin-key": "secret", "content-type": "application/json" }, body: JSON.stringify({ status: "rejected" }) });
  assert.equal((await patched.json()).status, "rejected");
  assert.equal((await call(new URL(item.url).pathname)).status, 404, "rejected images are not served");
  await call(`/api/images/${item.id}`, { method: "DELETE", headers: { "x-admin-key": "secret" } });
  assert.equal(files.size, 0);
  assert.deepEqual(await (await call("/api/images", { headers: { "x-admin-key": "secret" } })).json(), []);
});

test("names from the local app are reduced to safe characters", () => {
  assert.equal(cleanName("../../etc/passwd", "x"), "_.._etc_passwd");
  assert.equal(cleanName("", "fallback.png"), "fallback.png");
});

test("wrong passwords never lock an address; existing lock records do not block valid login", async () => {
  const { call, kv } = setup();
  const ip = "192.0.2.1";
  kv.set(`fail:${ip}`, "5");
  const headers = { "cf-connecting-ip": ip };
  for (let n = 0; n < 8; n++) {
    const denied = await call("/api/images", { headers: { ...headers, "x-admin-key": "wrong" } });
    assert.equal(denied.status, 401);
    assert.equal((await denied.json()).error, "Sai mật khẩu.");
  }
  assert.equal((await call("/api/images", { headers: { ...headers, "x-admin-key": "secret" } })).status, 200);
  assert.equal((await call("/oauth/start?key=wrong", { headers })).status, 401);
  assert.equal((await call("/oauth/start?key=secret", { headers })).status, 302);
  assert.equal(kv.get(`fail:${ip}`), "5", "login no longer reads or updates old lock records");
});

test("parallel uploads all stay listed and served; old single-list items still work", async () => {
  const { call, kv } = setup();
  kv.set("images", JSON.stringify([{ id: "old1", fileId: "file-old", batch: "b", name: "o.png", status: "awaiting_review", createdAt: "2020-01-01T00:00:00Z" }]));
  const admin = { "x-admin-key": "secret" };
  const made = await Promise.all([1, 2, 3, 4, 5].map((n) => call(`/api/images?batch=b&name=${n}.png`, { method: "POST", headers: admin, body: String(n) }).then((r) => r.json())));
  const list = await (await call("/api/images", { headers: admin })).json();
  assert.equal(list.length, 6);
  for (const item of made) assert.equal((await call(new URL(item.url).pathname)).status, 200);
  const patched = await call("/api/images/old1", { method: "PATCH", headers: { ...admin, "content-type": "application/json" }, body: JSON.stringify({ status: "accepted" }) });
  const body = await patched.json();
  assert.equal(body.status, "accepted", JSON.stringify(body));
  assert.equal((await (await call("/api/images", { headers: admin })).json()).length, 6);
});

test("source groups are Drive folders: create, upload, list, rename duplicates, delete", async () => {
  const { call } = setup();
  const admin = { "x-admin-key": "secret" };
  assert.equal((await call("/api/sources")).status, 401);
  assert.equal((await call("/api/sources", { method: "POST", headers: admin, body: JSON.stringify({ name: "../x" }) })).status, 400);
  assert.equal((await call("/api/sources", { method: "POST", headers: admin, body: JSON.stringify({ name: "Áo" }) })).status, 201);
  assert.equal((await call("/api/sources", { method: "POST", headers: admin, body: JSON.stringify({ name: "Áo" }) })).status, 409);
  const group = `/api/sources/${encodeURIComponent("Áo")}`;
  assert.equal((await call(`${group}?name=a.txt`, { method: "POST", headers: { ...admin, "content-type": "text/plain" }, body: "x" })).status, 400);
  const first = await (await call(`${group}?name=tee.jpg`, { method: "POST", headers: { ...admin, "content-type": "image/jpeg" }, body: "one" })).json();
  const second = await (await call(`${group}?name=tee.jpg`, { method: "POST", headers: { ...admin, "content-type": "image/jpeg" }, body: "two" })).json();
  assert.equal(second.name, "tee-2.jpg");
  const listed = await (await call(group, { headers: admin })).json();
  assert.deepEqual(listed.files.map((f) => f.name), ["tee-2.jpg", "tee.jpg"]);
  assert.ok(listed.files.every((f) => f.md5));
  const groups = await (await call("/api/sources", { headers: admin })).json();
  assert.deepEqual(groups.groups, [{ name: "Áo", count: 2, enabled: true }]);
  const image = await call(new URL(first.url).pathname);
  assert.equal(image.headers.get("content-type"), "image/jpeg");
  assert.equal(await image.text(), "one");
  assert.equal((await call(group, { method: "DELETE", headers: admin })).status, 400, "a group with photos is not deleted");
  for (const f of listed.files) assert.equal((await call(`${group}/${f.id}`, { method: "DELETE", headers: admin })).status, 200);
  assert.equal((await call(group, { method: "DELETE", headers: admin })).status, 200);
  assert.deepEqual((await (await call("/api/sources", { headers: admin })).json()).groups, []);
});

test("the app sees only switched-on groups; Áo and Nội thất start on", async () => {
  const { call } = setup();
  const app = { "x-admin-key": "app-pass" }, admin = { "x-admin-key": "secret" };
  for (const name of ["Áo", "Nội thất", "Mũ"]) await call("/api/sources", { method: "POST", headers: admin, body: JSON.stringify({ name }) });
  const names = async (headers) => (await (await call("/api/sources", { headers })).json()).groups.map((g) => g.name);
  assert.deepEqual(await names(admin), ["Áo", "Mũ", "Nội thất"]);
  assert.deepEqual(await names(app), ["Áo", "Nội thất"]);
  // A macOS folder name arrives decomposed (NFD); it is still the same group.
  assert.equal((await call(`/api/sources/${encodeURIComponent("Nội thất".normalize("NFD"))}`, { headers: app })).status, 200);
  const mu = `/api/sources/${encodeURIComponent("Mũ")}`;
  assert.equal((await call(mu, { headers: app })).status, 404, "a hidden group is not listed to the app");
  assert.equal((await call(mu, { method: "PATCH", headers: app, body: JSON.stringify({ enabled: true }) })).status, 403);
  assert.equal((await call(mu, { method: "PATCH", headers: admin, body: "{}" })).status, 400);
  assert.equal((await call(mu, { method: "PATCH", headers: admin, body: JSON.stringify({ enabled: true }) })).status, 200);
  assert.equal((await call(`/api/sources/${encodeURIComponent("Áo")}`, { method: "PATCH", headers: admin, body: JSON.stringify({ enabled: false }) })).status, 200);
  assert.deepEqual(await names(app), ["Mũ", "Nội thất"]);
  assert.equal((await call(mu, { headers: app })).status, 200);
});

test("an image can be added to a group straight from a link", async () => {
  const { call } = setup();
  const admin = { "x-admin-key": "secret" };
  await call("/api/sources", { method: "POST", headers: admin, body: JSON.stringify({ name: "Áo" }) });
  const group = `/api/sources/${encodeURIComponent("Áo")}`;
  const added = await (await call(`${group}?url=${encodeURIComponent("https://img.test/shop/polo%20blue.jpeg?w=800")}`, { method: "POST", headers: admin })).json();
  assert.equal(added.name, "polo blue.jpeg");
  assert.equal(await (await call(new URL(added.url).pathname)).text(), "remote");
  assert.equal((await call(`${group}?url=${encodeURIComponent("https://img.test/a.txt")}`, { method: "POST", headers: admin })).status, 400, "not an image");
  assert.equal((await call(`${group}?url=ftp://x`, { method: "POST", headers: admin })).status, 400);
  assert.equal((await call(`${group}?url=${encodeURIComponent("https://img.test/b.jpg")}`, { method: "POST", headers: { "x-admin-key": "app-pass" } })).status, 403, "the app password cannot add photos");
});

test("the old Product Image Batch folder is renamed and its run folders move into Ảnh đã tạo", async () => {
  const { call, env } = setup();
  const admin = { "x-admin-key": "secret" };
  const nodes = env.__nodes, kv = env.__kv;
  // The layout before: runs straight inside "Product Image Batch", next to "Nguồn ảnh".
  nodes.set("old-root", { name: "Product Image Batch", parents: [], folder: true });
  kv.set("folder:root:Product Image Batch", "old-root");
  for (let i = 0; i < 20; i++) { nodes.set(`run-${i}`, { name: `2026-10-${i}_run`, parents: ["old-root"], folder: true }); kv.set(`folder:old-root:2026-10-${i}_run`, `run-${i}`); }
  nodes.set("src", { name: "Nguồn ảnh", parents: ["old-root"], folder: true }); kv.set("folder:old-root:Nguồn ảnh", "src");
  const first = await (await call("/api/organize", { method: "POST", headers: admin })).json();
  assert.deepEqual(first, { moved: 15, remaining: 5 });
  assert.equal(nodes.get("old-root").name, "Product Review");
  assert.equal(nodes.get(nodes.get("old-root").parents[0]).name, "Tools Hub", "the tool folder sits in Tools Hub");
  assert.deepEqual(await (await call("/api/organize", { method: "POST", headers: admin })).json(), { moved: 5, remaining: 0 });
  assert.deepEqual(await (await call("/api/organize", { method: "POST", headers: admin })).json(), { moved: 0, remaining: 0 });
  const runs = [...nodes].find(([, n]) => n.name === "Ảnh đã tạo")[0];
  assert.equal(nodes.get("run-3").parents[0], runs);
  assert.equal(nodes.get("src").parents[0], "old-root", "Nguồn ảnh stays at the top");
  // A new image of an existing run goes into that moved folder; a new run gets its folder under Ảnh đã tạo.
  await call("/api/images?batch=2026-10-3_run&name=a.png", { method: "POST", headers: admin, body: "png" });
  await call("/api/images?batch=new_run&name=b.png", { method: "POST", headers: admin, body: "png" });
  const parentOf = (name) => [...nodes.values()].find((n) => n.name === name).parents[0];
  assert.equal(parentOf("a.png"), "run-3");
  assert.equal(nodes.get(parentOf("b.png")).parents[0], runs);
  assert.equal((await call("/api/organize", { method: "POST", headers: { "x-admin-key": "app-pass" } })).status, 403);
});

test("support logs: upload a zip, list it, download it, delete it", async () => {
  const { call } = setup();
  const admin = { "x-admin-key": "secret" };
  assert.equal((await call("/api/logs")).status, 401);
  const zip = new Uint8Array([80, 75, 3, 4, 1, 2]);
  const created = await (await call("/api/logs?name=2026-10-28_v1.0.9_mac.zip", { method: "POST", headers: admin, body: zip })).json();
  const md = await (await call("/api/logs?name=2026-10-30_v1.0.45_mac.md", { method: "POST", headers: admin, body: "# Lỗi" })).json();
  assert.equal(md.name, "2026-10-30_v1.0.45_mac.md");
  assert.match((await call(`/api/logs/${md.id}`, { headers: admin })).headers.get("content-type"), /text\/markdown/);
  await call(`/api/logs/${md.id}`, { method: "DELETE", headers: admin });
  const listed = await (await call("/api/logs", { headers: admin })).json();
  assert.deepEqual(listed.logs.map((l) => l.name), ["2026-10-28_v1.0.9_mac.zip"]);
  const file = await call(`/api/logs/${created.id}`, { headers: admin });
  assert.equal(file.headers.get("content-type"), "application/zip");
  assert.equal((await call(`/api/logs/${created.id}`, { method: "DELETE", headers: admin })).status, 200);
  assert.deepEqual((await (await call("/api/logs", { headers: admin })).json()).logs, []);
});

test("the app password reaches only the app's calls; the admin password reaches everything", async () => {
  const { call } = setup();
  const app = { "x-admin-key": "app-pass" }, admin = { "x-admin-key": "secret" };
  assert.equal((await call("/api/app-check", { headers: app })).status, 200);
  assert.equal((await call("/api/images?batch=b&name=a.png", { method: "POST", headers: app, body: "x" })).status, 201);
  assert.equal((await call("/api/logs?name=a.zip", { method: "POST", headers: app, body: "zip" })).status, 201);
  assert.equal((await call("/api/sources", { headers: app })).status, 200);
  for (const [path, init] of [["/api/images", {}], ["/api/logs", {}], ["/api/sources", { method: "POST", body: "{}" }]]) {
    assert.equal((await call(path, { ...init, headers: app })).status, 403, `app password must not reach ${init.method || "GET"} ${path}`);
  }
  assert.equal((await call("/api/images", { headers: admin })).status, 200);
  assert.equal((await call("/api/app-check", { headers: { "x-admin-key": "wrong" } })).status, 401);
});


test("a temporary key adds images to the library until it expires, and reaches nothing else", async () => {
  const { call, kv } = setup();
  const admin = { "x-admin-key": "secret", "content-type": "application/json" };
  assert.equal((await call("/api/temp-keys", { method: "POST", headers: { "x-admin-key": "app-pass" }, body: "{}" })).status, 403, "the app password cannot make keys");
  assert.equal((await call("/api/temp-keys", { method: "POST", headers: admin, body: JSON.stringify({ hours: 5 }) })).status, 400);
  const made = await (await call("/api/temp-keys", { method: "POST", headers: admin, body: JSON.stringify({ hours: 24 }) })).json();
  assert.match(made.key, /^hub_tmp_[0-9a-f]{40}$/);
  const tmp = { "x-admin-key": made.key };
  assert.equal((await call("/api/sources", { method: "POST", headers: { ...tmp, "content-type": "application/json" }, body: JSON.stringify({ name: "Đèn" }) })).status, 201);
  assert.equal((await call(`/api/sources/${encodeURIComponent("Đèn")}?name=a.jpg`, { method: "POST", headers: { ...tmp, "content-type": "image/jpeg" }, body: "x" })).status, 201);
  const listed = await (await call(`/api/sources/${encodeURIComponent("Đèn")}`, { headers: tmp })).json();
  assert.equal(listed.files.length, 1, "a switched-off group is still reachable for adding images");
  assert.equal((await call(`/api/sources/${encodeURIComponent("Đèn")}/${listed.files[0].id}`, { method: "DELETE", headers: tmp })).status, 403, "no deleting");
  assert.equal((await call("/api/images", { headers: tmp })).status, 403);
  assert.equal((await call("/api/temp-keys", { headers: tmp })).status, 403);
  const live = await (await call("/api/temp-keys", { headers: admin })).json();
  assert.equal(live.keys.length, 1);
  assert.equal(live.keys[0].hint, made.key.slice(-4));
  assert.equal(live.keys[0].key, made.key, "the admin can copy an earlier key again");
  // Expired keys stop working even before KV drops them; cancelling removes them at once.
  kv.set("tmpkeys", JSON.stringify(JSON.parse(kv.get("tmpkeys")).map((k) => ({ ...k, exp: Date.now() - 1 }))));
  assert.equal((await call("/api/sources", { headers: tmp })).status, 401);
  // Cancelling one key leaves the list and stops it at once; the others keep working.
  const one = await (await call("/api/temp-keys", { method: "POST", headers: admin, body: JSON.stringify({ hours: 1 }) })).json();
  const two = await (await call("/api/temp-keys", { method: "POST", headers: admin, body: JSON.stringify({ hours: 1 }) })).json();
  assert.equal((await (await call(`/api/temp-keys/${one.id}`, { method: "DELETE", headers: admin })).json()).removed, 1);
  assert.deepEqual((await (await call("/api/temp-keys", { headers: admin })).json()).keys.map((k) => k.id), [two.id]);
  assert.equal((await call("/api/sources", { headers: { "x-admin-key": one.key } })).status, 401);
  assert.equal((await call("/api/sources", { headers: { "x-admin-key": two.key } })).status, 200);
  assert.equal((await call("/api/temp-keys", { method: "DELETE", headers: admin })).status, 200);
  assert.equal((await call("/api/sources", { headers: { "x-admin-key": two.key } })).status, 401);
});

test("the Product Review Batch folder moves into Tools Hub as Product Review, keeping its id", async () => {
  const { call, env } = setup();
  const nodes = env.__nodes, kv = env.__kv;
  nodes.set("drive-root", { name: "My Drive", parents: [], folder: true });
  nodes.set("prb", { name: "Product Review Batch", parents: ["drive-root"], folder: true });
  kv.set("folder:app-root", "prb");
  kv.set("organized:runs", "1");
  await call("/api/images?batch=run1&name=a.png", { method: "POST", headers: { "x-admin-key": "secret" }, body: "png" });
  const hub = [...nodes].find(([, n]) => n.name === "Tools Hub")[0];
  assert.equal(nodes.get("prb").name, "Product Review");
  assert.deepEqual(nodes.get("prb").parents, [hub]);
  const runs = [...nodes].find(([, n]) => n.name === "Ảnh đã tạo");
  assert.equal(runs[1].parents[0], "prb", "runs stay in the same, moved folder");
  // Once moved, it is not moved again.
  nodes.get("prb").name = "renamed by hand";
  await call("/api/images?batch=run1&name=b.png", { method: "POST", headers: { "x-admin-key": "secret" }, body: "png" });
  assert.equal(nodes.get("prb").name, "renamed by hand");
});

test("Grok sample videos: admin uploads by prompt code into Tools Hub/Grok Video Prompt/Video mẫu/<n>s, anyone lists and plays", async () => {
  const { call, files, env } = setup();
  const mp4 = new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112]);
  const put = (path, key, body = mp4, type = "video/mp4") => call(path, { method: "PUT", headers: { "x-admin-key": key, "content-type": type }, body });
  assert.equal((await put("/api/grok-videos/10/close-to-wide", "app-pass")).status, 403, "the app password cannot upload");
  assert.equal((await put("/api/grok-videos/12/close-to-wide", "secret")).status, 400, "only 6, 10 and 15 s");
  assert.equal((await put("/api/grok-videos/10/close-to-wide", "secret", "x", "text/plain")).status, 400, "only videos");
  const first = await (await put("/api/grok-videos/10/close-to-wide", "secret")).json();
  const node = env.__nodes.get(first.fileId), byId = (id) => env.__nodes.get(id);
  assert.equal(node.name, "close-to-wide.mp4");
  assert.deepEqual([byId(node.parents[0]).name, byId(byId(node.parents[0]).parents[0]).name, byId(byId(byId(node.parents[0]).parents[0]).parents[0]).name], ["10s", "Video mẫu", "Grok Video Prompt"]);
  const listed = await call("/grok/videos", { headers: { origin: "http://127.0.0.1:46123" } });
  assert.equal(listed.headers.get("access-control-allow-origin"), "*", "the tool runs on a local port");
  const { videos } = await listed.json();
  assert.equal(videos["close-to-wide"].seconds, "10");
  const played = await call(new URL(videos["close-to-wide"].url).pathname);
  assert.equal(played.headers.get("content-type"), "video/mp4");
  assert.deepEqual(new Uint8Array(await played.arrayBuffer()), mp4);
  // A new upload replaces the old file; delete removes it.
  const second = await (await put("/api/grok-videos/10/close-to-wide", "secret")).json();
  assert.ok(!files.has(first.fileId) && files.has(second.fileId));
  assert.equal((await call(`/grok/video/${first.fileId}`)).status, 404, "only listed videos are served");
  await call("/api/grok-videos/10/close-to-wide", { method: "DELETE", headers: { "x-admin-key": "secret" } });
  assert.deepEqual((await (await call("/grok/videos")).json()).videos, {});
});

test("tool results keep their folders under Tools Hub/Content MXH/Ảnh đã tạo; same path replaces, only listed tools and types", async () => {
  const { call, files, env } = setup();
  const app = { "x-admin-key": "app-pass" };
  const put = (query, body = "x", headers = app) => call(`/api/tool-files?${query}`, { method: "POST", headers, body });
  const q = (tool, path) => `tool=${encodeURIComponent(tool)}&path=${encodeURIComponent(path)}`;
  assert.equal((await put(q("Product Review", "a/b.png"))).status, 400, "only listed tools");
  assert.equal((await put(q("Content MXH", "a/run.exe"))).status, 400, "only result file types");
  assert.equal((await put(q("Content MXH", "a/../b.png"))).status, 400, "no way out of the tool folder");
  assert.equal((await put(q("Content MXH", "a//b.png"))).status, 400, "no empty folder names");
  assert.equal((await put(q("Content MXH", "a/b.png"), "x", {})).status, 401, "needs the app password");
  const firstRes = await put(q("Content MXH", "2026-11-02_10h00m00s/01-ban-tra/bai-facebook.txt"), "hello");
  const first = await firstRes.json();
  assert.equal(firstRes.status, 201, JSON.stringify(first));
  assert.equal(first.path, "Content MXH/Ảnh đã tạo/2026-11-02_10h00m00s/01-ban-tra/bai-facebook.txt");
  const byId = (id) => env.__nodes.get(id);
  const node = byId(first.fileId);
  const chain = []; let p = node.parents[0];
  while (p) { chain.push(byId(p).name); p = byId(p).parents[0]; }
  assert.deepEqual(chain, ["01-ban-tra", "2026-11-02_10h00m00s", "Ảnh đã tạo", "Content MXH", "Tools Hub"]);
  const second = await (await put(q("Content MXH", "2026-11-02_10h00m00s/01-ban-tra/bai-facebook.txt"), "hello again")).json();
  assert.ok(!files.has(first.fileId) && files.has(second.fileId), "the same path replaces the file");
});
