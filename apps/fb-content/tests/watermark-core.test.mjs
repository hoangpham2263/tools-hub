// src/infrastructure/watermark.mjs: the PNG reader and writer, the scaling, where the watermark lands, and the command line.
// Pure Node, so the same checks hold on Windows and macOS.   node --test apps/fb-content/tests/watermark-core.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { decodePng, encodePng, resize, placeWatermark } from "../src/infrastructure/watermark.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const script = resolve(here, "../src/infrastructure/watermark.mjs");
const assetFile = resolve(here, "../data/brands/grenheim/watermark.png");
const BOX = JSON.parse(readFileSync(resolve(here, "../data/brands/grenheim/brand.json"), "utf8").replace(/^\uFEFF/, "")).watermark.content_box; // where the plate sits inside GRENHEIM's PNG

// A PNG built by hand, so the reader is checked against bytes it did not write itself.
const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcTable[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => { const out = Buffer.alloc(12 + data.length); out.writeUInt32BE(data.length, 0); out.write(type, 4, "latin1"); Buffer.from(data).copy(out, 8); out.writeUInt32BE(crc(out.subarray(4, 8 + data.length)), 8 + data.length); return out; };
function craft({ width, height, depth = 8, color, rows, plte, trns, interlace = 0 }) {
  const head = Buffer.alloc(13); head.writeUInt32BE(width, 0); head.writeUInt32BE(height, 4); head[8] = depth; head[9] = color; head[12] = interlace;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", head), ...(plte ? [chunk("PLTE", plte)] : []), ...(trns ? [chunk("tRNS", trns)] : []), chunk("IDAT", deflateSync(Buffer.concat(rows))), chunk("IEND", Buffer.alloc(0))]);
}
const solid = (width, height, rgba) => ({ width, height, data: Uint8Array.from({ length: width * height * 4 }, (_, i) => rgba[i % 4]) });
const pixel = (img, x, y) => Array.from(img.data.subarray((y * img.width + x) * 4, (y * img.width + x) * 4 + 4));
const isPlate = ([r, g, b]) => r < 60 && g - r > 25 && g - b > 8; // the brand's dark green over a grey photo
function plateBox(img, region) {
  let minX = 1e9, maxX = -1, minY = 1e9, maxY = -1;
  for (let y = region.y0; y < region.y1; y++) for (let x = region.x0; x < region.x1; x++) if (isPlate(pixel(img, x, y))) { minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y); }
  return { minX, maxX, minY, maxY, width: maxX - minX + 1 };
}

test("writing then reading a PNG gives the same pixels, opaque or with transparency", () => {
  const opaque = { width: 5, height: 4, data: Uint8Array.from({ length: 80 }, (_, i) => (i % 4 === 3 ? 255 : (i * 37) & 255)) };
  const clear = { width: 3, height: 3, data: Uint8Array.from({ length: 36 }, (_, i) => (i * 53) & 255) };
  for (const img of [opaque, clear]) { const back = decodePng(encodePng(img)); assert.equal(back.width, img.width); assert.deepEqual(Array.from(back.data), Array.from(img.data)); }
  assert.equal(encodePng(opaque)[25], 2, "an opaque picture is written as RGB");
  assert.equal(encodePng(clear)[25], 6, "a picture with transparency is written as RGBA");
});

test("every row filter is undone, and the other PNG kinds are read", () => {
  // 3x3 RGB with a different filter on each row, filtered here independently of the reader
  const rgb = [[10, 20, 30, 40, 50, 60, 70, 80, 90], [12, 24, 36, 48, 60, 72, 84, 96, 108], [5, 200, 7, 9, 180, 11, 13, 160, 15]];
  const filterRow = (type, row, prev) => row.map((v, i) => {
    const a = i >= 3 ? row[i - 3] : 0, b = prev ? prev[i] : 0, c = prev && i >= 3 ? prev[i - 3] : 0;
    if (type === 1) return (v - a) & 255; if (type === 2) return (v - b) & 255; if (type === 3) return (v - ((a + b) >> 1)) & 255;
    if (type === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); return (v - (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 255; }
    return v;
  });
  for (const types of [[1, 2, 3], [4, 4, 4], [0, 3, 4]]) {
    const rows = rgb.map((row, y) => Buffer.from([types[y], ...filterRow(types[y], row, rgb[y - 1])]));
    const img = decodePng(craft({ width: 3, height: 3, color: 2, rows }));
    assert.deepEqual(Array.from(img.data), rgb.flatMap((row) => [0, 3, 6].flatMap((i) => [row[i], row[i + 1], row[i + 2], 255])), `filters ${types}`);
  }
  const gray = decodePng(craft({ width: 2, height: 1, color: 0, rows: [Buffer.from([0, 0, 255])] }));
  assert.deepEqual(Array.from(gray.data), [0, 0, 0, 255, 255, 255, 255, 255]);
  const grayAlpha = decodePng(craft({ width: 1, height: 1, color: 4, rows: [Buffer.from([0, 90, 128])] }));
  assert.deepEqual(Array.from(grayAlpha.data), [90, 90, 90, 128]);
  const deep = decodePng(craft({ width: 1, height: 1, depth: 16, color: 2, rows: [Buffer.from([0, 200, 1, 100, 2, 50, 3])] }));
  assert.deepEqual(Array.from(deep.data), [200, 100, 50, 255], "16 bit keeps the high byte");
  const bit1 = decodePng(craft({ width: 3, height: 1, depth: 1, color: 0, rows: [Buffer.from([0, 0b10100000])] }));
  assert.deepEqual(Array.from(bit1.data), [255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255]);
  const indexed = decodePng(craft({ width: 3, height: 1, depth: 4, color: 3, rows: [Buffer.from([0, 0x01, 0x20])], plte: Buffer.from([255, 0, 0, 0, 255, 0, 0, 0, 255]), trns: Buffer.from([255, 128]) }));
  assert.deepEqual(Array.from(indexed.data), [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255], "indexes 0, 1, 2; alpha from tRNS where it has an entry");
});

test("files that are not plain PNGs are refused with a reason", () => {
  assert.throws(() => decodePng(Buffer.from("GIF89a....")), /Không phải file PNG/);
  assert.throws(() => decodePng(craft({ width: 1, height: 1, color: 2, interlace: 1, rows: [Buffer.from([0, 1, 2, 3])] })), /xen kẽ/);
  const whole = craft({ width: 2, height: 2, color: 2, rows: [Buffer.alloc(7), Buffer.alloc(7)] });
  assert.throws(() => decodePng(craft({ width: 2, height: 9, color: 2, rows: [Buffer.alloc(7)] })), /cắt ngang/);
  assert.ok(whole.length > 40);
});

test("scaling keeps a shadow's color: transparent edges do not darken it", () => {
  const flat = resize(solid(4, 4, [200, 100, 50, 255]), 2, 2);
  assert.deepEqual(pixel(flat, 1, 1), [200, 100, 50, 255]);
  const half = { width: 2, height: 1, data: Uint8Array.from([255, 255, 255, 255, 0, 0, 0, 0]) }; // white, then nothing
  const one = resize(half, 1, 1);
  const [r, g, bl, al] = pixel(one, 0, 0);
  assert.ok(r >= 250 && g >= 250 && bl >= 250 && al >= 90 && al <= 170, `half covered: white at about half strength, not grey: ${[r, g, bl, al]}`);
  const edge = resize({ width: 8, height: 1, data: Uint8Array.from([0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255]) }, 4, 1);
  assert.ok(pixel(edge, 0, 0)[0] < 30 && pixel(edge, 3, 0)[0] > 225, "a black to white edge stays an edge");
});

test("the watermark lands in the corner, at its size and margin, and nothing else changes", () => {
  const asset = decodePng(readFileSync(assetFile));
  const photo = solid(800, 600, [110, 110, 110, 255]);
  const before = Uint8Array.from(photo.data);
  const { image, placed } = placeWatermark(photo, asset, { box: BOX, position: "top-right", size: 0.16, margin: 0.03 });
  assert.deepEqual(Array.from(photo.data), Array.from(before), "the input picture is not modified");
  assert.equal(image.width, 800); assert.equal(image.height, 600);
  const plate = plateBox(image, { x0: 0, x1: 800, y0: 0, y1: 600 });
  assert.ok(Math.abs(plate.width - 128) <= 6, `16% of 800 is 128 px, got ${plate.width}`);
  assert.ok(Math.abs(800 - 1 - plate.maxX - 24) <= 4 && Math.abs(plate.minY - 24) <= 4, `3% from the top and right: right ${800 - 1 - plate.maxX}, top ${plate.minY}`);
  assert.ok(plate.minX > 400 && plate.maxY < 120, "in the top right corner");
  for (let y = 0; y < 600; y++) for (let x = 0; x < 800; x++) if (x < 400 || y > 300) assert.deepEqual(pixel(image, x, y), [110, 110, 110, 255], `untouched at ${x},${y}`);
  assert.ok(placed.w > 0 && placed.h > 0);
});

test("the other corners and the middle of the bottom", () => {
  const asset = decodePng(readFileSync(assetFile));
  const photo = solid(1600, 900, [110, 110, 110, 255]);
  const bl = plateBox(placeWatermark(photo, asset, { box: BOX, position: "bottom-left", size: 0.1, margin: 0.05 }).image, { x0: 0, x1: 800, y0: 450, y1: 900 });
  assert.ok(Math.abs(bl.minX - 80) <= 5 && Math.abs(900 - 1 - bl.maxY - 80) <= 5, `bottom left at 5%: left ${bl.minX}, bottom ${900 - 1 - bl.maxY}`);
  const tl = plateBox(placeWatermark(photo, asset, { box: BOX, position: "top-left", size: 0.1, margin: 0.05 }).image, { x0: 0, x1: 800, y0: 0, y1: 450 });
  assert.ok(Math.abs(tl.minX - 80) <= 5 && Math.abs(tl.minY - 80) <= 5, "top left at 5%");
  const br = plateBox(placeWatermark(photo, asset, { box: BOX, position: "bottom-right", size: 0.1, margin: 0.05 }).image, { x0: 800, x1: 1600, y0: 450, y1: 900 });
  assert.ok(Math.abs(1600 - 1 - br.maxX - 80) <= 5 && Math.abs(900 - 1 - br.maxY - 80) <= 5, "bottom right at 5%");
  const bc = plateBox(placeWatermark(photo, asset, { box: BOX, position: "bottom-center", size: 0.1, margin: 0.05 }).image, { x0: 0, x1: 1600, y0: 450, y1: 900 });
  assert.ok(Math.abs((bc.minX + bc.maxX) / 2 - 800) <= 4, "centered");
});

test("a picture with transparency keeps it, and a tiny one does not break", () => {
  const asset = decodePng(readFileSync(assetFile));
  const clear = { width: 300, height: 200, data: new Uint8Array(300 * 200 * 4) }; // fully transparent
  const { image } = placeWatermark(clear, asset, { box: BOX, size: 0.2 });
  assert.equal(pixel(image, 0, 0)[3], 0, "far from the mark the picture stays transparent");
  assert.ok(Array.from({ length: 300 * 200 }, (_, i) => image.data[i * 4 + 3]).some((a) => a > 200), "the plate itself is drawn");
  assert.doesNotThrow(() => placeWatermark(solid(8, 6, [10, 10, 10, 255]), asset, { box: BOX }));
});

test("bad settings are refused", () => {
  const asset = decodePng(readFileSync(assetFile)), photo = solid(100, 100, [0, 0, 0, 255]);
  assert.throws(() => placeWatermark(photo, asset, { box: BOX, position: "middle" }), /Vị trí/);
  assert.throws(() => placeWatermark(photo, asset, { box: BOX, size: 0.9 }), /Cỡ logo/);
  assert.throws(() => placeWatermark(photo, asset, { box: [1, 2, 3] }), /Hộp nội dung/);
  assert.throws(() => placeWatermark(photo, asset, { box: [0, 0, 0, 5] }), /Hộp nội dung/);
});

test("the command line writes a copy, never touches the original, and says why when it fails", () => {
  const dir = mkdtempSync(join(tmpdir(), "wm-test-"));
  try {
    const image = join(dir, "photo.png"), out = join(dir, "sub", "photo-logo.png");
    writeFileSync(image, encodePng(solid(400, 300, [110, 110, 110, 255])));
    const original = readFileSync(image);
    const ok = spawnSync(process.execPath, [script, "--image", image, "--mark", assetFile, "--out", out, "--box", BOX.join(","), "--position", "top-right", "--size", "0.16", "--margin", "0.03"], { encoding: "utf8" });
    assert.equal(ok.status, 0, ok.stderr);
    assert.equal(JSON.parse(ok.stdout).width, 400);
    assert.ok(existsSync(out) && decodePng(readFileSync(out)).height === 300, "a marked copy of the same size");
    assert.ok(readFileSync(image).equals(original), "the original is unchanged");
    const text = join(dir, "notes.txt"); writeFileSync(text, "not an image");
    const bad = spawnSync(process.execPath, [script, "--image", text, "--mark", assetFile, "--out", join(dir, "x.png"), "--box", BOX.join(",")], { encoding: "utf8" });
    assert.equal(bad.status, 1); assert.match(bad.stderr, /Không phải file PNG/);
    const missing = spawnSync(process.execPath, [script, "--image", image], { encoding: "utf8" });
    assert.equal(missing.status, 1); assert.match(missing.stderr, /Thiếu --mark/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
