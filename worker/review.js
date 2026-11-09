// Review Video: người quay up source, người dựng trả video kết quả. File nằm ở Drive
// "Tools Hub/Review Video/<mã sản phẩm>/Source|Kết quả/", danh sách sản phẩm lưu KV "review:<mã>".
// File lớn: Worker chỉ mở phiên upload resumable, trình duyệt gửi thẳng lên Google (không qua giới hạn 100 MB).
// Xem/tải: link ký HMAC có hạn, Worker chuyển tiếp từ Drive và hỗ trợ tua (Range).
export const REVIEW_FOLDER = "Review Video";
const STATUS = ["new", "editing", "done", "posted"];
const KIND_FOLDER = { source: "Source", result: "Kết quả" };
const LINK_HOURS = 12;

const slugify = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/đ/gi, "d").toLowerCase()
  .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "san-pham";
const cleanFile = (s) => String(s || "").replace(/[\\/\u0000-\u001f]/g, "_").trim().slice(0, 200);

async function hmac(env, text) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(`review:${env.ADMIN_PASSWORD}`), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}
async function signedUrl(env, origin, file, dl) {
  const exp = Date.now() + LINK_HOURS * 3600e3;
  const sig = await hmac(env, `${file.id}.${exp}`);
  return `${origin}/review/file/${file.id}?exp=${exp}&sig=${sig}${dl ? "&dl=1" : ""}`;
}

const readProduct = (env, slug) => env.STORE.get(`review:${slug}`, "json");
const writeProduct = (env, p) => env.STORE.put(`review:${p.slug}`, JSON.stringify(p));

async function withLinks(env, origin, p) {
  const files = await Promise.all((p.files || []).map(async (f) => ({ ...f, url: await signedUrl(env, origin, f), download: await signedUrl(env, origin, f, true) })));
  return { ...p, files };
}

/** Phát/tải file: GET /review/file/<id>?exp&sig[&dl=1] (công khai nhưng phải có chữ ký còn hạn) */
export async function reviewFile(req, env, url, id, { drive }) {
  const exp = Number(url.searchParams.get("exp"));
  const ok = exp > Date.now() && (await hmac(env, `${id}.${exp}`)) === url.searchParams.get("sig");
  if (!ok) return new Response("Link hết hạn, tải lại trang.", { status: 403 });
  const meta = await (await drive(env, `/drive/v3/files/${id}?fields=name,mimeType,size`)).json();
  const range = req.headers.get("range");
  const r = await drive(env, `/drive/v3/files/${id}?alt=media`, range ? { headers: { range } } : {});
  const h = new Headers({ "content-type": meta.mimeType || "application/octet-stream", "accept-ranges": "bytes", "cache-control": "private, max-age=3600" });
  for (const k of ["content-length", "content-range"]) if (r.headers.get(k)) h.set(k, r.headers.get(k));
  if (url.searchParams.get("dl")) h.set("content-disposition", `attachment; filename*=UTF-8''${encodeURIComponent(meta.name)}`);
  return new Response(r.body, { status: r.status, headers: h });
}

/** /api/review[/<mã>[/upload|/files[/<id>]]] — cần mật khẩu admin hoặc mật khẩu app */
export async function handleReview(req, env, url, parts, { drive, folder, json }) {
  const [slug, sub, fileId] = parts;
  const root = async () => folder(env, REVIEW_FOLDER, await folder(env, "Tools Hub"));

  if (!slug) {
    if (req.method === "GET") {
      const out = [];
      let cursor;
      do {
        const page = await env.STORE.list({ prefix: "review:", cursor });
        for (const k of page.keys) { const p = await env.STORE.get(k.name, "json"); if (p) out.push(p); }
        cursor = page.list_complete ? null : page.cursor;
      } while (cursor);
      return json(out, 200, { "cache-control": "no-store" });
    }
    if (req.method === "POST") {
      const { name, note = "" } = await req.json();
      if (!String(name || "").trim()) return json({ error: "Cần tên sản phẩm." }, 400);
      const p = {
        slug: `${slugify(name)}-${Date.now().toString(36).slice(-4)}`, name: String(name).trim().slice(0, 120),
        note: String(note).slice(0, 4000), status: "new", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), files: [],
      };
      p.folderId = await folder(env, p.slug, await root());
      await writeProduct(env, p);
      return json(p, 201);
    }
    return json({ error: "Not found" }, 404);
  }

  const p = await readProduct(env, slug);
  if (!p) return json({ error: "Không tìm thấy sản phẩm." }, 404);
  const save = async () => { p.updatedAt = new Date().toISOString(); await writeProduct(env, p); };

  if (!sub) {
    if (req.method === "GET") return json(await withLinks(env, url.origin, p), 200, { "cache-control": "no-store" });
    if (req.method === "PATCH") {
      const b = await req.json();
      if (b.status !== undefined) { if (!STATUS.includes(b.status)) return json({ error: "Trạng thái không hợp lệ." }, 400); p.status = b.status; }
      if (b.note !== undefined) p.note = String(b.note).slice(0, 4000);
      if (b.name !== undefined && String(b.name).trim()) p.name = String(b.name).trim().slice(0, 120);
      await save();
      return json(p);
    }
    if (req.method === "DELETE") {
      // Bỏ vào thùng rác Drive (khôi phục được trong 30 ngày), không xoá hẳn
      if (p.folderId) await drive(env, `/drive/v3/files/${p.folderId}`, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ trashed: true }) });
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
    const parent = await folder(env, KIND_FOLDER[kind], p.folderId || (p.folderId = await folder(env, p.slug, await root())));
    const r = await drive(env, "/upload/drive/v3/files?uploadType=resumable&fields=id,name,size,mimeType", {
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

  // Ghi nhận file đã up xong: POST /api/review/<mã>/files {id, kind}
  if (sub === "files" && !fileId && req.method === "POST") {
    const { id, kind = "source" } = await req.json();
    if (!KIND_FOLDER[kind] || !/^[\w-]+$/.test(id || "")) return json({ error: "Thiếu id file." }, 400);
    const meta = await (await drive(env, `/drive/v3/files/${id}?fields=id,name,size,mimeType,createdTime,parents`)).json();
    const f = { id: meta.id, name: meta.name, size: Number(meta.size || 0), mime: meta.mimeType, kind, uploaded: meta.createdTime };
    p.files = [...(p.files || []).filter((x) => x.id !== f.id), f];
    if (kind === "result" && ["new", "editing"].includes(p.status)) p.status = "done";
    await save();
    return json(f, 201);
  }

  if (sub === "files" && fileId && req.method === "DELETE") {
    if (!(p.files || []).some((f) => f.id === fileId)) return json({ error: "Không tìm thấy file." }, 404);
    await drive(env, `/drive/v3/files/${fileId}`, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ trashed: true }) });
    p.files = p.files.filter((f) => f.id !== fileId);
    await save();
    return json({ ok: true });
  }

  return json({ error: "Not found" }, 404);
}
