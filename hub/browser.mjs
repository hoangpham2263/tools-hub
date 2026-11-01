// The tools' own Chrome: Chrome for Testing in <hub>/workspace/browser, its own profile, the Tools Hub extension
// (hub/extension) loaded. Signed in once from Cấu hình (Mở: Google Flow, Gemini, ChatGPT) in a window; runs then start it
// with no window at all (headless), so the user's own Chrome is never needed. A minimized window would not do: its
// pages drop the extension's clicks.
//   node hub/browser.mjs login   download it the first time, open it in a window with the sites to sign in to
//   node hub/browser.mjs open <url>…   the same with these pages (the ChatGPT sign-in for Codex)
//   node hub/browser.mjs start   for a run: start it hidden, or again hidden when open in a window (not downloaded: exit 2)
//   node hub/browser.mjs status  { installed, running }
//   node hub/browser.mjs logins  { installed, google, accounts, chatgpt }: signed in there (its cookies; accounts: the
//                                Google accounts, the first one being what Flow and Gemini use); starts it hidden if needed
// Prints one JSON line.
import { spawn, execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const dir = join(root, "workspace", "browser");
const profile = join(dir, "profile");
const modeFile = join(dir, "mode.txt");
const PORT = 45000 + (parseInt(createHash("sha1").update(root).digest("hex").slice(0, 6), 16) % 1000);
const LOGIN_URLS = ["https://flow.google.com/", "https://gemini.google.com/app", "https://chatgpt.com/"];
const platform = { darwin: process.arch === "arm64" ? "mac-arm64" : "mac-x64", win32: process.arch === "ia32" ? "win32" : "win64" }[process.platform] || "linux64";
export const executable = join(dir, `chrome-${platform}`, ...(platform.startsWith("mac")
  ? ["Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"]
  : [platform.startsWith("win") ? "chrome.exe" : "chrome"]));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const run = (cmd, args) => new Promise((done, fail) => execFile(cmd, args, { windowsHide: true, maxBuffer: 1 << 24 }, (err) => (err ? fail(err) : done())));

// The newest Chrome for Testing that Google lists as good, about 150 MB; unpacked once.
async function download() {
  const index = await fetch("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json").then((r) => r.json());
  const url = index.channels.Stable.downloads.chrome.find((d) => d.platform === platform)?.url;
  if (!url) throw new Error(`Chưa có Chrome cho máy này (${platform}).`);
  mkdirSync(dir, { recursive: true });
  const zip = join(dir, "chrome.zip");
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Tải Chrome lỗi ${response.status}.`);
  writeFileSync(zip, Buffer.from(await response.arrayBuffer()));
  rmSync(join(dir, `chrome-${platform}`), { recursive: true, force: true });
  // ditto keeps the app bundle's links on macOS; Windows 10+ has tar for zip files.
  if (platform.startsWith("mac")) await run("ditto", ["-x", "-k", zip, dir]);
  else await run("tar", ["-xf", zip, "-C", dir]);
  rmSync(zip, { force: true });
  if (!existsSync(executable)) throw new Error("Giải nén Chrome không thành công.");
}

const devtools = (path, method = "GET") => fetch(`http://127.0.0.1:${PORT}${path}`, { method }).then((r) => r.json());
const running = () => devtools("/json/version").then(() => true, () => false);
// The Tools Hub extension (hub/extension), shared by every tool.
const extensions = () => [join(root, "hub", "extension")];

// The cookies of every site in its profile, read through DevTools.
async function cookies() {
  const { webSocketDebuggerUrl } = await devtools("/json/version");
  const socket = new WebSocket(webSocketDebuggerUrl);
  await new Promise((done, fail) => { socket.onopen = done; socket.onerror = fail; });
  try {
    return await new Promise((done, fail) => {
      socket.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id === 1) (d.error ? fail(new Error(d.error.message)) : done(d.result.cookies)); };
      socket.send(JSON.stringify({ id: 1, method: "Storage.getCookies" }));
    });
  } finally { socket.close(); }
}

// The Google accounts signed in there, as Google's account switcher lists them (the first is the default one, which
// Flow and Gemini open with). Empty when Google does not answer.
async function googleAccounts(all) {
  const cookie = all.filter((c) => ["accounts.google.com", ".accounts.google.com", ".google.com"].includes(c.domain)).map((c) => `${c.name}=${c.value}`).join("; ");
  try {
    const r = await fetch("https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard", { method: "POST", headers: { cookie, origin: "https://www.google.com" }, signal: AbortSignal.timeout(10000) });
    return JSON.parse(await r.text())[1].map((a) => a[3]).filter((e) => /@/.test(e));
  } catch { return []; }
}

// Closes it through DevTools (Node 22+ has WebSocket; older Node is started with the flag) and waits until it is gone.
async function close() {
  const { webSocketDebuggerUrl } = await devtools("/json/version");
  const socket = new WebSocket(webSocketDebuggerUrl);
  await new Promise((done, fail) => { socket.onopen = done; socket.onerror = fail; });
  socket.send(JSON.stringify({ id: 1, method: "Browser.close" }));
  for (let i = 0; i < 40 && (await running()); i++) await sleep(250);
  await sleep(500);
}

// Headless Chrome names itself in the user agent; sites then see the same browser as in the window.
function userAgent() {
  const versions = platform.startsWith("mac")
    ? join(dirname(dirname(executable)), "Frameworks", "Google Chrome for Testing Framework.framework", "Versions")
    : dirname(executable);
  const version = readdirSync(versions).find((v) => /^\d+\.\d+\.\d+\.\d+$/.test(v)) || "140.0.0.0";
  const system = platform.startsWith("mac") ? "Macintosh; Intel Mac OS X 10_15_7" : platform.startsWith("win") ? "Windows NT 10.0; Win64; x64" : "X11; Linux x86_64";
  return `Mozilla/5.0 (${system}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${version} Safari/537.36`;
}

// Opens it (or, already open the same way, its tabs) and waits until it answers. hidden: no window.
async function open({ urls, hidden }) {
  if (await running()) {
    const wasHidden = existsSync(modeFile) && readFileSync(modeFile, "utf8") === "hidden";
    if (wasHidden === hidden) {
      for (const url of urls) await devtools(`/json/new?${encodeURI(url)}`, "PUT");
      return;
    }
    // One profile, one Chrome: switching between hidden and a window means starting it again.
    await close();
  }
  writeFileSync(modeFile, hidden ? "hidden" : "window");
  spawn(executable, [
    `--user-data-dir=${profile}`, `--remote-debugging-port=${PORT}`, "--no-first-run", "--no-default-browser-check", "--disable-infobars",
    "--disable-features=DisableLoadExtensionCommandLineSwitch", `--load-extension=${extensions().join(",")}`,
    "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", "--disable-background-timer-throttling",
    "--window-size=1200,850", ...(hidden ? ["--headless=new", `--user-agent=${userAgent()}`] : []), ...urls,
  ], { detached: true, stdio: "ignore", windowsHide: hidden }).unref();
  for (let i = 0; i < 60 && !(await running()); i++) await sleep(500);
  if (!(await running())) throw new Error("Không mở được Chrome của tool.");
}

async function main(command, urls) {
  if (command === "status") return { installed: existsSync(executable), running: await running() };
  if (command === "login" || command === "open") {
    if (!existsSync(executable)) await download();
    await open({ urls: command === "open" ? urls : LOGIN_URLS, hidden: false });
    return { ok: true };
  }
  if (command === "logins") {
    if (!existsSync(executable)) return { installed: false, google: false, chatgpt: false };
    if (!(await running())) await open({ urls: [], hidden: true });
    const all = await cookies();
    const has = (domain, test) => all.some((c) => c.domain.endsWith(domain) && test(c.name) && c.expires !== 0);
    // Google's sign-in cookie covers Flow and Gemini; ChatGPT keeps its session in next-auth's (sometimes split) cookie.
    const google = has("google.com", (n) => n === "SID" || n === "__Secure-1PSID");
    return { installed: true, google, accounts: google ? await googleAccounts(all) : [], chatgpt: has("chatgpt.com", (n) => n.startsWith("__Secure-next-auth.session-token")) };
  }
  if (command === "start") {
    if (!existsSync(executable)) { process.exitCode = 2; return { error: "Chưa có Chrome của tool. Mở Cấu hình, bấm Mở ở dòng Chrome của tool." }; }
    if (await running()) {
      // Runs never show it: a window (opened from Cấu hình to sign in) is closed and started again hidden. On macOS a
      // hidden one keeps running with every page closed, and the extension then sleeps: that one starts again too.
      const hidden = existsSync(modeFile) && readFileSync(modeFile, "utf8") === "hidden";
      const pages = (await devtools("/json/list")).filter((t) => t.type === "page");
      if (hidden && pages.length) return { ok: true };
      await close();
    }
    await open({ urls: ["https://flow.google.com/"], hidden: true });
    return { ok: true };
  }
  throw new Error("Lệnh: login | open <url> | start | status | logins");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv[2], process.argv.slice(3)).then((r) => console.log(JSON.stringify(r)), (e) => { console.log(JSON.stringify({ error: e.message })); process.exitCode = 1; });
}

// How the servers and PowerShell run it: a Node with WebSocket.
export const browserArgs = (command, ...args) => [...(Number(process.versions.node.split(".")[0]) < 22 ? ["--experimental-websocket"] : []), fileURLToPath(import.meta.url), command, ...args];
// The Tools Hub windows (hub/platform.mjs appWindow) use the same Chrome with a profile of their own, so they never
// share the run's hidden one.
export const appProfile = join(dir, "app");
