// Puts a watermark PNG on a copy of a PNG image. Plain Node (node:zlib only), so it works the same on Windows and macOS
// with nothing else installed: no System.Drawing, no sips, no Chrome. The original file is never written.
//   node hub/image/watermark.mjs --image in.png --mark watermark.png --out out.png --box x,y,w,h
//        [--position top-right|top-left|bottom-right|bottom-left|bottom-center] [--size 0.16] [--margin 0.03]
// --size is the visible watermark's width as a fraction of the image width, --margin its distance from the edge, also
// as a fraction of the width; --box is where the visible part sits inside the mark PNG (x,y,width,height in its pixels;
// the rest is room for a shadow). Prints {"width","height","x","y","w","h"} (the placed box) or fails with a message.
// Images are PNG: 1 to 16 bit, gray, palette, RGB or RGBA, not interlaced (the image AIs save plain PNG).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { inflateSync, deflateSync } from "node:zlib";
import { fileURLToPath } from "node:url";

const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// ----- PNG decode: RGBA, 8 bits per channel -----
export function decodePng(file) {
  if (file.length < 8 || !file.subarray(0, 8).equals(SIGNATURE)) throw new Error("Không phải file PNG.");
  let pos = 8, head = null, palette = null, trns = null;
  const idat = [];
  while (pos + 12 <= file.length) {
    const length = file.readUInt32BE(pos);
    const type = file.toString("latin1", pos + 4, pos + 8);
    const data = file.subarray(pos + 8, pos + 8 + length);
    pos += 12 + length;
    if (type === "IHDR") head = { width: data.readUInt32BE(0), height: data.readUInt32BE(4), depth: data[8], color: data[9], interlace: data[12] };
    else if (type === "PLTE") palette = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
  }
  if (!head) throw new Error("PNG thiếu IHDR.");
  if (head.interlace) throw new Error("PNG xen kẽ (interlaced) chưa được hỗ trợ.");
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[head.color];
  if (!channels || ![1, 2, 4, 8, 16].includes(head.depth)) throw new Error("Kiểu PNG này chưa được hỗ trợ.");
  const { width, height, depth, color } = head;
  const bits = channels * depth, bpp = Math.max(1, Math.ceil(bits / 8)), stride = Math.ceil((width * bits) / 8);
  const raw = inflateSync(Buffer.concat(idat));
  if (raw.length < height * (stride + 1)) throw new Error("PNG bị cắt ngang.");
  // undo the row filters
  const px = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)], src = y * (stride + 1) + 1, row = y * stride, up = row - stride;
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? px[row + i - bpp] : 0, b = y ? px[up + i] : 0, c = y && i >= bpp ? px[up + i - bpp] : 0, x = raw[src + i];
      let v;
      if (filter === 0) v = x;
      else if (filter === 1) v = x + a;
      else if (filter === 2) v = x + b;
      else if (filter === 3) v = x + ((a + b) >> 1);
      else if (filter === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c); }
      else throw new Error("PNG có kiểu lọc không hợp lệ.");
      px[row + i] = v & 255;
    }
  }
  // to RGBA
  const out = new Uint8Array(width * height * 4);
  const mask = (1 << Math.min(depth, 8)) - 1;
  const sample = (row, index) => { // the index-th sample of a row, scaled to 0..255 for gray, raw for palette
    if (depth === 8) return px[row + index];
    if (depth === 16) return px[row + index * 2];
    const bit = index * depth;
    return (px[row + (bit >> 3)] >> (8 - depth - (bit & 7))) & mask;
  };
  for (let y = 0; y < height; y++) {
    const row = y * stride;
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (color === 6) { for (let k = 0; k < 4; k++) out[o + k] = sample(row, x * 4 + k); }
      else if (color === 2) { for (let k = 0; k < 3; k++) out[o + k] = sample(row, x * 3 + k); out[o + 3] = 255; }
      else if (color === 4) { const g = sample(row, x * 2); out[o] = out[o + 1] = out[o + 2] = g; out[o + 3] = sample(row, x * 2 + 1); }
      else if (color === 0) { const g = depth >= 8 ? sample(row, x) : Math.round((sample(row, x) * 255) / mask); out[o] = out[o + 1] = out[o + 2] = g; out[o + 3] = 255; }
      else {
        const i = sample(row, x);
        if (!palette || i * 3 + 2 >= palette.length) throw new Error("PNG có màu ngoài bảng màu.");
        out[o] = palette[i * 3]; out[o + 1] = palette[i * 3 + 1]; out[o + 2] = palette[i * 3 + 2];
        out[o + 3] = trns && i < trns.length ? trns[i] : 255;
      }
    }
  }
  return { width, height, data: out };
}

// ----- PNG encode: RGB when every pixel is opaque, else RGBA; the best of three filters for each row -----
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = (buf) => { let c = 0xffffffff; for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "latin1");
  Buffer.from(data.buffer ?? data, data.byteOffset ?? 0, data.length).copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
};
export function encodePng({ width, height, data }) {
  let opaque = true;
  for (let i = 3; i < data.length; i += 4) if (data[i] !== 255) { opaque = false; break; }
  const channels = opaque ? 3 : 4, stride = width * channels;
  const rows = Buffer.alloc(height * (stride + 1));
  const line = new Uint8Array(stride), none = new Uint8Array(stride), sub = new Uint8Array(stride), upf = new Uint8Array(stride);
  let previous = new Uint8Array(stride);
  const cost = (r) => { let s = 0; for (let i = 0; i < r.length; i++) s += r[i] < 128 ? r[i] : 256 - r[i]; return s; };
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) for (let k = 0; k < channels; k++) line[x * channels + k] = data[(y * width + x) * 4 + k];
    for (let i = 0; i < stride; i++) { none[i] = line[i]; sub[i] = (line[i] - (i >= channels ? line[i - channels] : 0)) & 255; upf[i] = (line[i] - previous[i]) & 255; }
    const costs = [cost(none), cost(sub), cost(upf)], best = costs.indexOf(Math.min(...costs));
    rows[y * (stride + 1)] = best;
    rows.set([none, sub, upf][best], y * (stride + 1) + 1);
    previous = Uint8Array.from(line);
  }
  const head = Buffer.alloc(13);
  head.writeUInt32BE(width, 0); head.writeUInt32BE(height, 4); head[8] = 8; head[9] = opaque ? 2 : 6;
  return Buffer.concat([SIGNATURE, chunk("IHDR", head), chunk("IDAT", deflateSync(rows, { level: 6 })), chunk("IEND", Buffer.alloc(0))]);
}

// ----- scale an RGBA picture with a Lanczos filter, on premultiplied colors so the shadow stays clean -----
// A logo drawn large and scaled down by ten keeps crisp edges with Lanczos; averaging boxes makes them soft.
const sinc = (x) => (x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x));
const lanczos = (x, a) => (Math.abs(x) < a ? sinc(x) * sinc(x / a) : 0);
export function resize({ width: sw, height: sh, data }, dw, dh, a = 3) {
  const pre = new Float32Array(sw * sh * 4);
  for (let i = 0; i < sw * sh; i++) { const al = data[i * 4 + 3] / 255; pre[i * 4] = data[i * 4] * al; pre[i * 4 + 1] = data[i * 4 + 1] * al; pre[i * 4 + 2] = data[i * 4 + 2] * al; pre[i * 4 + 3] = data[i * 4 + 3]; }
  // for each destination index along one axis: the source indexes it reads and their weights (sum 1)
  const taps = (sB, dB) => {
    const ratio = sB / dB, scale = Math.max(1, ratio), support = a * scale, out = [];
    for (let d = 0; d < dB; d++) {
      const center = (d + 0.5) * ratio - 0.5, from = Math.max(0, Math.ceil(center - support)), to = Math.min(sB - 1, Math.floor(center + support));
      const weights = []; let sum = 0;
      for (let s = from; s <= to; s++) { const v = lanczos((s - center) / scale, a); weights.push(v); sum += v; }
      out.push({ from, weights: weights.map((v) => v / sum) });
    }
    return out;
  };
  const tx = taps(sw, dw), ty = taps(sh, dh);
  const across = new Float32Array(dw * sh * 4); // dw x sh
  for (let y = 0; y < sh; y++) for (let x = 0; x < dw; x++) {
    const { from, weights } = tx[x], o = (y * dw + x) * 4;
    for (let k = 0; k < weights.length; k++) { const s = (y * sw + from + k) * 4, v = weights[k]; across[o] += pre[s] * v; across[o + 1] += pre[s + 1] * v; across[o + 2] += pre[s + 2] * v; across[o + 3] += pre[s + 3] * v; }
  }
  const out = new Uint8Array(dw * dh * 4);
  for (let y = 0; y < dh; y++) for (let x = 0; x < dw; x++) {
    const { from, weights } = ty[y];
    let r = 0, g = 0, bl = 0, al = 0;
    for (let k = 0; k < weights.length; k++) { const s = ((from + k) * dw + x) * 4, v = weights[k]; r += across[s] * v; g += across[s + 1] * v; bl += across[s + 2] * v; al += across[s + 3] * v; }
    const alpha = Math.max(0, Math.min(255, al)), o = (y * dw + x) * 4;
    out[o + 3] = Math.round(alpha);
    if (alpha > 0.5) { out[o] = Math.max(0, Math.min(255, Math.round((r * 255) / alpha))); out[o + 1] = Math.max(0, Math.min(255, Math.round((g * 255) / alpha))); out[o + 2] = Math.max(0, Math.min(255, Math.round((bl * 255) / alpha))); }
  }
  return { width: dw, height: dh, data: out };
}

// ----- place the watermark -----
export const POSITIONS = ["top-right", "top-left", "bottom-right", "bottom-left", "bottom-center"];
export function placeWatermark(image, mark, { box, position = "top-right", size = 0.16, margin = 0.03 }) {
  if (!POSITIONS.includes(position)) throw new Error(`Vị trí không hợp lệ: ${position}.`);
  if (!(size > 0 && size <= 0.5)) throw new Error("Cỡ logo phải là tỉ lệ chiều rộng ảnh, tối đa 0,5.");
  if (!Array.isArray(box) || box.length !== 4 || box.some((n) => !Number.isFinite(n)) || box[2] <= 0 || box[3] <= 0) throw new Error("Hộp nội dung của logo phải là x,y,rộng,cao.");
  const [cx, cy, cw, ch] = box;
  const scale = (size * image.width) / cw;
  const dw = Math.max(1, Math.round(mark.width * scale)), dh = Math.max(1, Math.round(mark.height * scale));
  const small = resize(mark, dw, dh);
  const inset = [cx * scale, cy * scale, (mark.width - cx - cw) * scale, (mark.height - cy - ch) * scale]; // left, top, right, bottom
  const m = margin * image.width;
  // The visible part, not the shadow's room, sits `m` from the edges.
  const x = Math.round(position.endsWith("right") ? image.width - m - dw + inset[2] : position === "bottom-center" ? (image.width - dw) / 2 : m - inset[0]);
  const y = Math.round(position.startsWith("top") ? m - inset[1] : image.height - m - dh + inset[3]);
  const out = { width: image.width, height: image.height, data: Uint8Array.from(image.data) };
  for (let j = 0; j < dh; j++) {
    const ty = y + j;
    if (ty < 0 || ty >= out.height) continue;
    for (let i = 0; i < dw; i++) {
      const tx = x + i;
      if (tx < 0 || tx >= out.width) continue;
      const s = (j * dw + i) * 4, t = (ty * out.width + tx) * 4, a = small.data[s + 3] / 255;
      if (a === 0) continue;
      const base = out.data[t + 3] / 255, over = a + base * (1 - a);
      for (let k = 0; k < 3; k++) out.data[t + k] = Math.round((small.data[s + k] * a + out.data[t + k] * base * (1 - a)) / over);
      out.data[t + 3] = Math.round(over * 255);
    }
  }
  return { image: out, placed: { x, y, w: dw, h: dh } };
}

// ----- command line -----
function main(argv) {
  const arg = {};
  for (let i = 0; i < argv.length; i += 2) arg[argv[i].replace(/^--/, "")] = argv[i + 1];
  for (const need of ["image", "mark", "out", "box"]) if (!arg[need]) throw new Error(`Thiếu --${need}.`);
  const box = String(arg.box).split(",").map(Number);
  const image = decodePng(readFileSync(arg.image));
  const mark = decodePng(readFileSync(arg.mark));
  const { image: result, placed } = placeWatermark(image, mark, { box, position: arg.position || "top-right", size: arg.size === undefined ? 0.16 : Number(arg.size), margin: arg.margin === undefined ? 0.03 : Number(arg.margin) });
  mkdirSync(dirname(arg.out), { recursive: true });
  writeFileSync(arg.out, encodePng(result));
  console.log(JSON.stringify({ width: result.width, height: result.height, ...placed }));
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try { main(process.argv.slice(2)); } catch (e) { console.error(e.message); process.exit(1); }
}
