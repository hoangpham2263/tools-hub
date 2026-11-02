// hub/image/unsparkle.mjs: Google's sparkle is undone (not painted over), a picture without it is left alone, and the
// command line writes a copy.   node --test hub/tests/unsparkle.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { encodePng, decodePng } from "../image/watermark.mjs";
import { removeSparkle, sparkleCover } from "../image/unsparkle.mjs";

const script = resolve(dirname(fileURLToPath(import.meta.url)), "../image/unsparkle.mjs");
// A picture with detail (diagonal stripes and a gradient) so that "the detail comes back" means something.
function scene(width, height) {
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const i = (y * width + x) * 4, stripe = ((x + y) % 40 < 3) ? -50 : 0;
    data[i] = 120 + (x / width) * 60 + stripe; data[i + 1] = 90 + (y / height) * 50 + stripe; data[i + 2] = 70 + stripe; data[i + 3] = 255;
  }
  return { width, height, data };
}
// The same picture under the veil of strength alpha.
function veiled(image, alpha) {
  const { cover } = sparkleCover(image.width, image.height), copy = { ...image, data: Uint8Array.from(image.data) };
  for (let p = 0; p < cover.length; p++) if (cover[p] > 0) for (let c = 0; c < 3; c++) { const a = alpha * cover[p], i = p * 4 + c; copy.data[i] = Math.round(copy.data[i] * (1 - a) + 255 * a); }
  return copy;
}
// Largest difference over the pixels the star covers fully (its soft edge is smoothed, so it differs a little more).
const inner = (a, b) => { const { cover } = sparkleCover(a.width, a.height); let m = 0; for (let p = 0; p < cover.length; p++) if (cover[p] > 0.99) for (let c = 0; c < 3; c++) m = Math.max(m, Math.abs(a.data[p * 4 + c] - b.data[p * 4 + c])); return m; };
const maxDiff = (a, b, box) => { let m = 0; for (let y = box[1]; y <= box[3]; y++) for (let x = box[0]; x <= box[2]; x++) for (let c = 0; c < 3; c++) m = Math.max(m, Math.abs(a.data[(y * a.width + x) * 4 + c] - b.data[(y * a.width + x) * 4 + c])); return m; };

test("the sparkle is undone and the detail under it comes back, for several strengths and sizes", () => {
  for (const [size, alpha] of [[1024, 0.3], [1024, 0.48], [1024, 0.2]]) {
    const clean = scene(size, size), marked = veiled(clean, alpha), { box } = sparkleCover(size, size);
    assert.ok(maxDiff(clean, marked, box) > 40, "the veil must be visible before");
    const result = removeSparkle(marked);
    assert.equal(result.applied, true, `size ${size} alpha ${alpha}`);
    assert.ok(Math.abs(result.alpha - alpha) < 0.08, `strength measured ${result.alpha} for ${alpha}`);
    // Inside the star the stripes are back; only the soft edge may differ a little.
    assert.ok(inner(clean, marked) <= 14, `inside the star differs by ${inner(clean, marked)} (size ${size}, alpha ${alpha}, measured ${result.alpha})`);
  }
});

test("pixels away from the corner never change", () => {
  const clean = scene(1024, 1024), marked = veiled(clean, 0.3), copy = Uint8Array.from(marked.data);
  removeSparkle(marked);
  for (let y = 0; y < 1024; y++) for (let x = 0; x < 1024; x++) if (x < 850 || y < 850) for (let c = 0; c < 4; c++) assert.equal(marked.data[(y * 1024 + x) * 4 + c], copy[(y * 1024 + x) * 4 + c]);
});

test("a picture without the sparkle, a flat one and a tiny one are left as they are", () => {
  for (const image of [scene(1024, 1024), { width: 1024, height: 1024, data: Uint8Array.from({ length: 1024 * 1024 * 4 }, () => 200) }, scene(100, 100)]) {
    const before = Uint8Array.from(image.data);
    assert.equal(removeSparkle(image).applied, false);
    assert.deepEqual(image.data, before);
  }
});

test("a rectangular picture has the star at its own corner", () => {
  const clean = scene(1280, 720), marked = veiled(clean, 0.3);
  assert.equal(removeSparkle(marked).applied, true);
  const { box } = sparkleCover(1280, 720);
  assert.ok(inner(clean, marked) <= 20 && maxDiff(clean, marked, box) <= 30, `rectangular picture differs by ${inner(clean, marked)} inside, ${maxDiff(clean, marked, box)} overall`);
});

test("the command line writes a cleaned copy, keeps a clean picture byte for byte, and says why it fails", () => {
  const dir = mkdtempSync(join(tmpdir(), "unsparkle-"));
  try {
    const clean = scene(1024, 1024), a = join(dir, "marked.png"), b = join(dir, "clean.png"), out = join(dir, "out.png");
    writeFileSync(a, encodePng(veiled(clean, 0.3))); writeFileSync(b, encodePng(clean));
    const run = (image) => spawnSync(process.execPath, [script, "--image", image, "--out", out], { encoding: "utf8" });
    let r = run(a);
    assert.equal(r.status, 0); assert.equal(JSON.parse(r.stdout).applied, true);
    assert.notDeepEqual(readFileSync(out), readFileSync(a));
    r = run(b);
    assert.equal(JSON.parse(r.stdout).applied, false);
    assert.deepEqual(readFileSync(out), readFileSync(b));
    writeFileSync(join(dir, "x.png"), "not a picture");
    r = run(join(dir, "x.png"));
    assert.notEqual(r.status, 0); assert.match(r.stderr, /PNG/);
    assert.equal(decodePng(readFileSync(a)).width, 1024, "the input is never written");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
