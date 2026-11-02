// Builds a brand's watermark: the logotype in white on a rounded plate in the brand's main color. The mark is the G of
// the name, so the letters are only RENHEIM (the mark, then the letters, with no G drawn twice)
// (brand.json colors.primary), with a soft shadow, as a transparent PNG the tool draws on every image
// (apps/fb-content/src/infrastructure/watermark.ps1). White on the brand color reads on any photo, light or dark, and
// one file means the plate and its shadow are identical on every image and at every size.
//   node scripts/build-brand-watermark.mjs apps/fb-content/data/brands/grenheim
// Reads <brand>/logo.svg and <brand>/brand.json and writes <brand>/watermark.png, then prints the content box (the plate,
// without the shadow's room) to keep in brand.json.
// The SVG must be built like GRENHEIM's avatar: the mark's three strokes are the paths path8, path10 and circle12,
// the name's letters path22 (the G, not drawn: the mark stands for it) and path24 to path36 (R E N H E I M); their ids and
// the viewBoxes below come from that file. Needs Chrome.
import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const brand = resolve(process.argv[2] || "");
const svgFile = join(brand, "logo.svg");
if (!existsSync(svgFile)) { console.error(`No logo.svg in ${brand}`); process.exit(2); }
const svg = readFileSync(svgFile, "utf8");
const brandJson = JSON.parse(readFileSync(join(brand, "brand.json"), "utf8").replace(/^\uFEFF/, ""));
const PLATE = brandJson.colors?.primary;
if (!/^#[0-9a-f]{6}$/i.test(PLATE || "")) { console.error("brand.json needs colors.primary, a #rrggbb color."); process.exit(2); }
const elements = [...svg.matchAll(/<path\s+([^>]*?)\/>/gs)].map((m) => m[1]);
const pathOf = (id) => {
  const attrs = elements.find((e) => new RegExp(`id="${id}"`).test(e));
  const d = attrs && /\sd="([^"]+)"/.exec(` ${attrs}`);
  if (!d) throw new Error(`The logo has no path ${id}`);
  return d[1];
};
const markPaths = ["path8", "path10", "circle12"].map(pathOf);
const wordPaths = ["path24", "path26", "path28", "path30", "path32", "path34", "path36"].map(pathOf);

// CSS pixels. RENHEIM is 190 px wide, its capitals 27 px tall; the mark, standing for the G, is exactly as tall as they
// are and is spaced from the R like one letter from the next (about 3 px in this typeface). The plate has 13 px above
// and below, 16 px at the left and 22 px at the right; the padding around the plate holds its shadow. Drawn 6 times
// larger than it is shown, so it can be scaled down sharply for any image size.
// THIN: strokes cut from the letters (in viewBox units, 2.75 per CSS px) to lighten their weight
const THIN = 3.5;
const MARK = 27, WORD = 190, GAP = 3, PAD = 48, SCALE = 6, PX = 13, PL = 16, PR = 22;
const HEIGHT = MARK + 2 * PX, WIDTH = PL + MARK + GAP + WORD + PR;
const markSvg = `<svg width="${MARK}" height="${MARK}" viewBox="400 318 454 454" style="display:block"><g fill="none" stroke="currentColor" stroke-width="38">${markPaths.map((p) => `<path d="${p}"/>`).join("")}</g></svg>`;
const wordSvg = `<svg width="${WORD}" height="${(WORD * 90) / 522}" viewBox="408 852 522 90" style="display:block"><defs><mask id="thin" maskUnits="userSpaceOnUse" x="408" y="852" width="522" height="90"><g fill="#fff" stroke="#000" stroke-width="${THIN}">${wordPaths.map((p) => `<path d="${p}"/>`).join("")}</g></mask></defs><rect x="408" y="852" width="522" height="90" fill="currentColor" mask="url(#thin)"/></svg>`;
const html = `<!doctype html><meta charset="utf-8"><body style="margin:0;background:transparent"><div style="position:absolute;left:${PAD}px;top:${PAD}px;width:${WIDTH}px;height:${HEIGHT}px;box-sizing:border-box;padding:${PX}px ${PR}px ${PX}px ${PL}px;color:#fff;display:flex;align-items:center;gap:${GAP}px;border-radius:14px;background:${PLATE}cc;box-shadow:0 4px 16px rgba(0,0,0,.3)">${markSvg}${wordSvg}</div>`;

const chrome = ["C:/Program Files/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"].find(existsSync);
if (!chrome) { console.error("Chrome is needed to draw the watermark."); process.exit(3); }
const work = mkdtempSync(join(tmpdir(), "watermark-"));
const page = join(work, "page.html");
writeFileSync(page, html);
const out = join(brand, "watermark.png");
const outW = (WIDTH + 2 * PAD) * SCALE, outH = (HEIGHT + 2 * PAD) * SCALE;
const run = spawnSync(chrome, ["--headless=new", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000", `--force-device-scale-factor=${SCALE}`, `--window-size=${WIDTH + 2 * PAD},${HEIGHT + 2 * PAD}`, `--screenshot=${out}`, `file:///${page.replace(/\\/g, "/")}`], { stdio: "ignore", timeout: 60000 });
rmSync(work, { recursive: true, force: true });
if (run.status !== 0 || !existsSync(out)) { console.error("Chrome did not write the watermark."); process.exit(4); }
console.log(JSON.stringify({ file: "watermark.png", image: [outW, outH], content_box: [PAD * SCALE, PAD * SCALE, WIDTH * SCALE, HEIGHT * SCALE] }));
