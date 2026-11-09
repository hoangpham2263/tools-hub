// Review Video: người quay up source, người dựng trả video kết quả. File nằm ở Drive
// "Tools Hub/Review Video/<mã sản phẩm>/Source|Kết quả/".
// Nhanh theo kiểu memories-api: cả danh sách nằm trong 1 khoá KV (1 lần đọc), danh sách trả kèm link xem
// đã ký nên web không phải gọi thêm, file được cache ở edge sau lần xem đầu.
// File lớn: Worker chỉ mở phiên upload resumable, trình duyệt gửi thẳng lên Google (không qua giới hạn 100 MB).
export const REVIEW_FOLDER = "Review Video";
const STATUS = ["new", "editing", "done", "posted"];
const KIND_FOLDER = { source: "Source", result: "Kết quả" };
const LINK_HOURS = 12;
const ALL_KEY = "review:all";

const slugify = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/đ/gi, "d").toLowerCase()
  .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "san-pham";
const cleanFile = (s) => String(s || "").replace(/[\\/\u0000-\u001f]/g, "_").trim().slice(0, 200);

let hmacKey;
async function hmac(env, text) {
  hmacKey ||= await crypto.subtle.importKey("raw", new TextEncoder().encode(`review:${env.ADMIN_PASSWORD}`), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", hmacKey, new TextEncoder().encode(text));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}
// Hạn link làm tròn theo giờ để URL giống nhau trong 1 giờ → trình duyệt cache được ảnh/video
async function links(env, origin, f) {
  const exp = (Math.floor(Date.now() / 3600e3) + LINK_HOURS) * 3600e3;
  const q = `exp=${exp}&sig=${await hmac(env, `${f.id}.${exp}`)}`;
  return { url: `${origin}/review/file/${f.id}?${q}`, download: `${origin}/review/file/${f.id}?${q}&dl=1&name=${encodeURIComponent(f.name)}` };
}

/** Toàn bộ sản phẩm: { [slug]: product }. Lần đầu gom từ các khoá cũ "review:<slug>". */
async function readAll(env) {
  const all = await env.STORE.get(ALL_KEY, "json");
  if (all) return all;
  const out = {};
  let cursor;
  do {
    const page = await env.STORE.list({ prefix: "review:", cursor });
    for (const k of page.keys) if (k.name !== ALL_KEY) { const p = await env.STORE.get(k.name, "json"); if (p?.slug) out[p.slug] = p; }
    cursor = page.list_complete ? null : page.cursor;
  } while (cursor);
  await env.STORE.put(ALL_KEY, JSON.stringify(out));
  return out;
}
const writeAll = (env, all) => env.STORE.put(ALL_KEY, JSON.stringify(all));
const withLinks = async (env, origin, p) => ({ ...p, files: await Promise.all((p.files || []).map(async (f) => ({ ...f, ...(await links(env, origin, f)) }))) });

/** Phát/tải file: GET /review/file/<id>?exp&sig[&dl=1]. Công khai nhưng cần chữ ký còn hạn; cache ở edge theo id. */
export async function reviewFile(req, env, url, id, { drive, ctx }) {
  const exp = Number(url.searchParams.get("exp"));
  const ok = exp > Date.now() && (await hmac(env, `${id}.${exp}`)) === url.searchParams.get("sig");
  if (!ok) return new Response("Link hết hạn, tải lại trang.", { status: 403 });
  const dl = !!url.searchParams.get("dl");
  const key = new Request(`${url.origin}/review/file/${id}`, { headers: req.headers.get("range") ? { range: req.headers.get("range") } : {} });
  const cache = caches.default;
  let res = await cache.match(key);
  if (!res) {
    const r = await drive(env, `/drive/v3/files/${id}?alt=media`);
    const h = new Headers({
      "content-type": r.headers.get("content-type") || "application/octet-stream", "accept-ranges": "bytes",
      "cache-control": "public, max-age=2592000, immutable",
    });
    if (r.headers.get("content-length")) h.set("content-length", r.headers.get("content-length"));
    const full = new Response(r.body, { headers: h });
    if (req.headers.get("range")) {
      // Lưu bản đầy đủ vào cache (chạy nền), lần này trả phần được hỏi thẳng từ Drive
      ctx.waitUntil(cache.put(new Request(`${url.origin}/review/file/${id}`), full));
      const part = await drive(env, `/drive/v3/files/${id}?alt=media`, { headers: { range: req.headers.get("range") } });
      const ph = new Headers(h);
      for (const k of ["content-length", "content-range"]) if (part.headers.get(k)) ph.set(k, part.headers.get(k));
      res = new Response(part.body, { status: part.status, headers: ph });
    } else {
      ctx.waitUntil(cache.put(new Request(`${url.origin}/review/file/${id}`), full.clone()));
      res = full;
    }
  }
  if (!dl) return res;
  const h = new Headers(res.headers);
  h.set("content-disposition", `attachment; filename*=UTF-8''${encodeURIComponent(url.searchParams.get("name") || id)}`);
  return new Response(res.body, { status: res.status, headers: h });
}

/** /api/review[/<mã>[/upload|/files[/<id>]]] */
export async function handleReview(req, env, url, parts, { drive, folder, json }) {
  const [slug, sub, fileId] = parts;
  const root = async () => folder(env, REVIEW_FOLDER, await folder(env, "Tools Hub"));
  const all = await readAll(env);
  const out = async (p, status = 200) => json(await withLinks(env, url.origin, p), status, { "cache-control": "no-store" });

  if (!slug) {
    if (req.method === "GET") {
      const list = await Promise.all(Object.values(all).map((p) => withLinks(env, url.origin, p)));
      return json(list, 200, { "cache-control": "no-store" });
    }
    if (req.method === "POST") {
      const { name, note = "" } = await req.json();
      if (!String(name || "").trim()) return json({ error: "Cần tên sản phẩm." }, 400);
      const now = new Date().toISOString();
      const p = {
        slug: `${slugify(name)}-${Date.now().toString(36).slice(-4)}`, name: String(name).trim().slice(0, 120),
        note: String(note).slice(0, 4000), status: "new", createdAt: now, updatedAt: now, files: [],
      };
      all[p.slug] = p;
      await writeAll(env, all);
      return out(p, 201);
    }
    return json({ error: "Not found" }, 404);
  }

  const p = all[slug];
  if (!p) return json({ error: "Không tìm thấy sản phẩm." }, 404);
  const save = async () => { p.updatedAt = new Date().toISOString(); await writeAll(env, all); };
  const trash = (id) => drive(env, `/drive/v3/files/${id}`, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ trashed: true }) });

  if (!sub) {
    if (req.method === "GET") return out(p);
    if (req.method === "PATCH") {
      const b = await req.json();
      if (b.status !== undefined) { if (!STATUS.includes(b.status)) return json({ error: "Trạng thái không hợp lệ." }, 400); p.status = b.status; }
      if (b.note !== undefined) p.note = String(b.note).slice(0, 4000);
      if (b.name !== undefined && String(b.name).trim()) p.name = String(b.name).trim().slice(0, 120);
      await save();
      return out(p);
    }
    if (req.method === "DELETE") {
      // Bỏ vào thùng rác Drive (khôi phục được trong 30 ngày), không xoá hẳn
      if (p.folderId) await trash(p.folderId);
      delete all[slug];
      await writeAll(env, all);
      await env.STORE.delete(`review:${slug}`);
      return json({ ok: true });
    }
  }

  // Mở phiên upload: POST /api/review/<mã>/upload {name,size,mime,kind} → {uploadUrl}; trình duyệt PUT file vào uploadUrl
  if (sub === "upload" && req.method === "POST") {
    const { name, size, mime, kind = "source" } = await req.json();
    const fname = cleanFile(name);
    if (!fname || !(size > 0) || !KIND_FOLDER[kind]) return json({ error: "Thiếu tên, cỡ hoặc loại file." }, 400);
    if (size > 5 * 1024 ** 3) return json({ error: "File quá 5 GB." }, 400);
    if (!p.folderId) { p.folderId = await folder(env, p.slug, await root()); await writeAll(env, all); }
    const parent = await folder(env, KIND_FOLDER[kind], p.folderId);
    const r = await drive(env, "/upload/drive/v3/files?uploadType=resumable&fields=id,name,size,mimeType,createdTime", {
      method: "POST",
      headers: {
        "content-type": "application/json; charset=UTF-8",
        "x-upload-content-type": mime || "application/octet-stream", "x-upload-content-length": String(size),
        origin: req.headers.get("origin") || url.origin,
      },
      body: JSON.stringify({ name: fname, parents: [parent] }),
    });
    return json({ uploadUrl: r.headers.get("location") });
  }

  // Ghi nhận file đã up xong, nhiều file 1 lần ghi: POST /api/review/<mã>/files {items:[{id,name,size,mimeType,createdTime,kind}]}
  // (thông tin lấy từ phản hồi của Google khi up xong, không phải hỏi lại Drive)
  if (sub === "files" && !fileId && req.method === "POST") {
    const b = await req.json();
    const items = (b.items || [b]).filter((x) => KIND_FOLDER[x.kind || "source"] && /^[\w-]+$/.test(x.id || ""));
    if (!items.length) return json({ error: "Thiếu id file." }, 400);
    const files = await Promise.all(items.map(async (x) => {
      if (x.name && x.size) return { id: x.id, name: cleanFile(x.name), size: Number(x.size), mime: x.mimeType || "", kind: x.kind || "source", uploaded: x.createdTime || new Date().toISOString() };
      const m = await (await drive(env, `/drive/v3/files/${x.id}?fields=id,name,size,mimeType,createdTime`)).json();
      return { id: m.id, name: m.name, size: Number(m.size || 0), mime: m.mimeType, kind: x.kind || "source", uploaded: m.createdTime };
    }));
    const ids = new Set(files.map((f) => f.id));
    p.files = [...(p.files || []).filter((f) => !ids.has(f.id)), ...files];
    if (files.some((f) => f.kind === "result") && ["new", "editing"].includes(p.status)) p.status = "done";
    await save();
    return out(p, 201);
  }

  if (sub === "files" && fileId && req.method === "DELETE") {
    if (!(p.files || []).some((f) => f.id === fileId)) return json({ error: "Không tìm thấy file." }, 404);
    await trash(fileId);
    p.files = p.files.filter((f) => f.id !== fileId);
    await save();
    return out(p);
  }

  return json({ error: "Not found" }, 404);
}
