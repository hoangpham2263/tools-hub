// Removes the sparkle Google puts in the bottom right corner of the pictures its web AI makes (Flow, Gemini), in plain Node.
// The sparkle is one white veil of fixed shape (a four-point star with curved sides) and fixed place; it is not part of the
// picture. So it is undone, not painted over: shown = bg * (1 - a) + 255 * a, hence bg = (shown - 255 a) / (1 - a), and the
// detail under the star comes back. The strength a is measured on each picture: how much the star's inside is lifted over a
// smooth guess of the background (from the ring around the star). A picture without the star is left as it is.
//   node unsparkle.mjs --image <png> --out <png>     prints {"applied":true|false,"alpha":0.31}
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { decodePng, encodePng } from "./watermark.mjs";

// Measured on Flow's pictures (1024 x 1024 and 1200 x 896): the star keeps the same size in pixels whatever the picture's size, its
// centre about 101 px from the right and bottom edges, 25.8 px from centre to tip. The exact place can differ by a few pixels
// from one picture to the next, so removeSparkle looks for it around that place.
// (A shape measured on 18 real pictures instead of this formula was tried and not kept: on pictures it had not seen it left as
// much of an outline as the formula does. What limits the result is the guess of the background under the star, not the shape.)
const CENTER = 101, RADIUS = 25.8, CURVE = 0.66, MIN_SIDE = 400, SEARCH = 8, CORE = 0.98;

// How much of each pixel the star covers (0 to 1, soft at the edge), for a picture of this size; dx and dy move the star.
export function sparkleCover(width, height, dx = 0, dy = 0) {
  const cx = width - CENTER + dx, cy = height - CENTER + dy, r = RADIUS;
  const x0 = Math.max(0, Math.floor(cx - r - 4)), x1 = Math.min(width - 1, Math.ceil(cx + r + 4));
  const y0 = Math.max(0, Math.floor(cy - r - 4)), y1 = Math.min(height - 1, Math.ceil(cy + r + 4));
  const cover = new Float32Array(width * height);
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
    const f = Math.pow(Math.abs(x + 0.5 - cx) / r, CURVE) + Math.pow(Math.abs(y + 0.5 - cy) / r, CURVE); // below 1 inside
    cover[y * width + x] = Math.max(0, Math.min(1, ((1 - f) * r * 0.45) / 1.2 + 0.5));
  }
  return { cover, box: [x0, y0, x1, y1] };
}

// Where the star really is: the shift (within SEARCH px) at which its inside is brightest against a ring just outside it.
function findShift(image) {
  const { width: W, height: H, data } = image;
  const lum = (x, y) => { const i = (y * W + x) * 4; return 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]; };
  const { cover, box } = sparkleCover(W, H);
  const inner = [], outer = [];
  for (let y = box[1] - 6; y <= box[3] + 6; y++) for (let x = box[0] - 6; x <= box[2] + 6; x++) {
    if (cover[y * W + x] >= CORE) inner.push([x, y]);
    else if (cover[y * W + x] < 0.02) {
      let near = false;
      for (let dy = -4; dy <= 4 && !near; dy++) for (let dx = -4; dx <= 4; dx++) if (cover[(y + dy) * W + x + dx] >= 0.5) { near = true; break; }
      if (near) outer.push([x, y]);
    }
  }
  let best = { dx: 0, dy: 0, score: -1e9 };
  for (let dy = -SEARCH; dy <= SEARCH; dy++) for (let dx = -SEARCH; dx <= SEARCH; dx++) {
    let a = 0, b = 0;
    for (const [x, y] of inner) a += lum(x + dx, y + dy);
    for (const [x, y] of outer) b += lum(x + dx, y + dy);
    const score = a / inner.length - b / outer.length;
    if (score > best.score) best = { dx, dy, score };
  }
  return best;
}

// Returns { applied, alpha } and changes image.data in place when the star was there.
export function removeSparkle(image) {
  const { width: W, height: H, data } = image;
  if (Math.min(W, H) < MIN_SIDE) return { applied: false, alpha: 0 };
  const shift = findShift(image);
  // The real star is within a few pixels of its usual place and clearly brighter inside than around it; a best match at the edge of
  // the search, or a weak one, is something else (a bright object, a gradient).
  if (Math.abs(shift.dx) > 4 || Math.abs(shift.dy) > 4 || shift.score < 12) return { applied: false, alpha: 0 };
  const { cover, box: [x0, y0, x1, y1] } = sparkleCover(W, H, shift.dx, shift.dy);
  const at = (x, y) => (y * W + x) * 4;
  const inside = [];
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) if (cover[y * W + x] > 0.02) inside.push([x, y]);
  // Smooth background under the star: start from the mean of the ring around it, then diffuse from the ring inwards.
  const bg = new Float32Array(W * H * 3);
  const ring = [0, 0, 0]; let n = 0;
  for (let y = y0 - 1; y <= y1 + 1; y++) for (let x = x0 - 1; x <= x1 + 1; x++) {
    for (let c = 0; c < 3; c++) bg[(y * W + x) * 3 + c] = data[at(x, y) + c];
    if (cover[y * W + x] <= 0.02) { for (let c = 0; c < 3; c++) ring[c] += data[at(x, y) + c]; n++; }
  }
  for (const [x, y] of inside) for (let c = 0; c < 3; c++) bg[(y * W + x) * 3 + c] = ring[c] / n;
  for (let pass = 0; pass < 500; pass++) for (const [x, y] of inside) for (let c = 0; c < 3; c++) {
    const i = (y * W + x) * 3 + c;
    bg[i] = (bg[i - W * 3] + bg[i + W * 3] + bg[i - 3] + bg[i + 3]) / 4;
  }
  // Strength: the median lift of the pixels the star fully covers. A star that is there lifts nearly all of them.
  const lifts = []; let lifted = 0, tested = 0;
  for (const [x, y] of inside) {
    if (cover[y * W + x] < CORE) continue;
    for (let c = 0; c < 3; c++) {
      const b = bg[(y * W + x) * 3 + c], v = data[at(x, y) + c];
      if (255 - b < 30) continue;
      lifts.push((v - b) / (255 - b)); tested++; if (v > b) lifted++;
    }
  }
  if (tested < 100 || lifted / tested < 0.9) return { applied: false, alpha: 0 };
  lifts.sort((a, b) => a - b);
  const alpha = lifts[lifts.length >> 1];
  if (alpha < 0.1 || alpha > 0.8) return { applied: false, alpha };
  const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
  for (const [x, y] of inside) {
    const a = alpha * cover[y * W + x], i = at(x, y);
    for (let c = 0; c < 3; c++) data[i + c] = clamp((data[i + c] - 255 * a) / (1 - a));
  }
  // The edge of the star is where the measured shape is soft: a pixel only partly covered, whose strength is the least certain. Those
  // pixels take the mean of the clean pixels around them (inside and outside), so no faint outline is left.
  const edge = (x, y) => cover[y * W + x] > 0 && cover[y * W + x] < 0.99;
  const before = Uint8Array.from(data);
  for (const [x, y] of inside) {
    if (!edge(x, y)) continue;
    const t = [0, 0, 0]; let m = 0;
    for (let dy = -3; dy <= 3; dy++) for (let dx = -3; dx <= 3; dx++) {
      const xx = x + dx, yy = y + dy;
      if (xx < 0 || yy < 0 || xx >= W || yy >= H || edge(xx, yy)) continue;
      const j = at(xx, yy); t[0] += before[j]; t[1] += before[j + 1]; t[2] += before[j + 2]; m++;
    }
    if (!m) continue;
    const i = at(x, y);
    for (let c = 0; c < 3; c++) data[i + c] = clamp(before[i + c] * 0.2 + (t[c] / m) * 0.8);
  }
  return { applied: true, alpha, score: shift.score };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const args = process.argv.slice(2), get = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : ""; };
  const image = get("--image"), out = get("--out");
  if (image && out) {
    try {
      const picture = decodePng(readFileSync(image));
      const result = removeSparkle(picture);
      writeFileSync(out, result.applied ? encodePng(picture) : readFileSync(image));
      console.log(JSON.stringify({ applied: result.applied, alpha: Number(result.alpha.toFixed(3)) }));
    } catch (error) { console.error(String(error.message || error)); process.exit(1); }
  }
}
