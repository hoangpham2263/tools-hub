// Router: keeps a WebSocket to the local bridge (hub/bridge) and forwards each job to the matching tab.
// The job is submitted inside the signed-in tab, so the page itself handles its own anti-abuse checks.
// It runs in the user's own Chrome: jobs only use tabs it opened itself, in the Chrome window already open, in a tab
// group named Tools Hub; the user's own tabs are never touched. A site only works in a tab that is shown (Gemini stops
// answering behind another tab), so a job shows its tab and then goes back to the tab the user was on.
const BRIDGE_URL = "ws://127.0.0.1:8765";
// hosts: the tabs to look through; page: a tab a job can run in (a Flow project, under /u/<n>/ for another account).
const SITES = {
  chatgpt: { hosts: "https://chatgpt.com/*", page: /^https:\/\/chatgpt\.com\//, start: "https://chatgpt.com/" },
  flow: { hosts: "https://flow.google.com/*", page: /^https:\/\/flow\.google\.com\/(u\/\d+\/)?project\//, start: "https://flow.google.com/" },
  gemini: { hosts: "https://gemini.google.com/*", page: /^https:\/\/gemini\.google\.com\//, start: "https://gemini.google.com/app" },
};
// Flow and Gemini run with the Google account chosen on Cấu hình (job.account; "" is Google's default, the first one
// signed in), opened with ?authuser=; Google then shows the page under /u/<n>/.
const startUrl = (platform, account) => SITES[platform].start + (account ? `?authuser=${encodeURIComponent(account)}` : "");
// One job at a time per site: parallel workflow threads share its tab.
const queues = {};

let socket = null;

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  socket = new WebSocket(BRIDGE_URL);
  socket.onopen = () => {
    socket.send(JSON.stringify({ type: "hello", version: chrome.runtime.getManifest().version }));
    chrome.storage.session.set({ connected: true });
  };
  socket.onclose = () => { socket = null; chrome.storage.session.set({ connected: false }); };
  socket.onerror = () => {};
  socket.onmessage = (event) => {
    let job;
    try { job = JSON.parse(event.data); } catch { return; }
    if (job.type === "generate") queues[job.platform] = (queues[job.platform] || Promise.resolve()).then(() => runJob(job));
    if (job.type === "logins") logins().then((r) => reply({ type: "result", id: job.id, ok: true, ...r }), (e) => reply({ type: "result", id: job.id, ok: false, error: String(e.message || e) }));
    // After an update the app asks for this, so the new files load without a click in chrome://extensions.
    if (job.type === "reload") chrome.runtime.reload();
  };
}

function reply(message) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

// The tab each site's jobs ran in last and the account it was opened with, so a changed account gets a tab of its own.
async function remembered(platform) {
  const { tabs = {} } = await chrome.storage.session.get("tabs");
  return tabs[platform];
}
async function remember(platform, tab, account) {
  const { tabs = {} } = await chrome.storage.session.get("tabs");
  tabs[platform] = { id: tab.id, account };
  await chrome.storage.session.set({ tabs });
  return tab;
}

async function findTab(platform, account) {
  const site = SITES[platform];
  if (!site) throw new Error(`Nền tảng không hỗ trợ: ${platform}`);
  const known = await remembered(platform);
  if (known && known.account === account) {
    const tab = await chrome.tabs.get(known.id).catch(() => null);
    if (tab && site.page.test(tab.url || "")) return tab;
  }
  if (platform === "flow") return remember(platform, await newFlowProject(account), account);
  reply({ type: "progress", id: "tab", stage: `opening ${platform}` });
  const tab = await toolsTab(startUrl(platform, account));
  await waitForLoad(tab.id);
  return remember(platform, tab, account);
}

// A tab of the tools: in the Chrome window open now (a new window only when there is none), not brought to the front,
// in that window's Tools Hub group.
async function toolsTab(url) {
  const window = await chrome.windows.getLastFocused({ windowTypes: ["normal"] }).catch(() => null);
  const tab = window ? await chrome.tabs.create({ url, windowId: window.id, active: false }) : (await chrome.windows.create({ url })).tabs[0];
  await group(tab);
  return tab;
}
async function group(tab) {
  try {
    const [existing] = await chrome.tabGroups.query({ windowId: tab.windowId, title: "Tools Hub" });
    const groupId = tab.groupId > -1 ? tab.groupId : await chrome.tabs.group({ tabIds: tab.id, ...(existing ? { groupId: existing.id } : { createProperties: { windowId: tab.windowId } }) });
    await chrome.tabGroups.update(groupId, { title: "Tools Hub", color: "blue", collapsed: false });
  } catch {}
}

// No Flow project open: open Flow's home (as the chosen account) and press its new-project button, then use that project.
async function newFlowProject(account) {
  // The chosen account's Flow home from an earlier try (its /u/<n>/ is only known once opened), else a new one.
  const { flowHome } = await chrome.storage.session.get("flowHome");
  const kept = flowHome?.account === account ? await chrome.tabs.get(flowHome.id).catch(() => null) : null;
  const home = kept && /^https:\/\/flow\.google\.com\//.test(kept.url || "") && !SITES.flow.page.test(kept.url) ? kept : null;
  const tab = home || await toolsTab(startUrl("flow", account));
  if (!home) await waitForLoad(tab.id);
  await chrome.storage.session.set({ flowHome: { id: tab.id, account } });
  const ask = () => chrome.tabs.sendMessage(tab.id, { type: "new-project" });
  // A tab open from before the extension (re)loaded has no content script: reload it once.
  const at = await ask().catch(async () => { await chrome.tabs.reload(tab.id); await waitForLoad(tab.id); return ask(); }).catch(() => null);
  if (!at?.ok) throw new Error(at?.error || "Không mở được Google Flow. Đăng nhập Google trong Chrome rồi chạy lại.");
  reply({ type: "progress", id: "tab", stage: "clicking Flow's new-project button" });
  await trustedClick(tab, at.x, at.y);
  for (let i = 0; i < 60; i++) {
    const now = await chrome.tabs.get(tab.id);
    if (SITES.flow.page.test(now.url || "") && now.status === "complete") return now;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("Google Flow chưa tạo được dự án mới.");
}

function waitForLoad(tabId) {
  return new Promise((resolve) => {
    const listener = (id, info) => {
      if (id === tabId && info.status === "complete") { chrome.tabs.onUpdated.removeListener(listener); resolve(); }
    };
    chrome.tabs.onUpdated.addListener(listener);
  });
}

async function runJob(job) {
  const progress = (stage) => reply({ type: "progress", id: job.id, stage });
  let restore = null;
  try {
    const account = job.platform === "chatgpt" ? "" : String(job.account || "");
    const tab = await findTab(job.platform, account);
    // Shown while it works (an open group, its tab in front); the user's tab comes back once the job is done.
    const [back] = await chrome.tabs.query({ windowId: tab.windowId, active: true });
    restore = back && back.id !== tab.id ? back.id : null;
    await group(tab);
    await chrome.tabs.update(tab.id, { active: true });
    if (job.platform === "chatgpt" || job.platform === "gemini") {
      // Every job starts in a fresh conversation so earlier images and answers are never reused.
      await chrome.tabs.update(tab.id, { url: startUrl(job.platform, account) });
      await waitForLoad(tab.id);
    }
    progress("submitting");
    let result;
    try {
      result = await chrome.tabs.sendMessage(tab.id, { type: "generate", job });
    } catch {
      // Tabs opened before the extension was installed have no content script yet.
      await chrome.tabs.reload(tab.id);
      await waitForLoad(tab.id);
      result = await chrome.tabs.sendMessage(tab.id, { type: "generate", job });
    }
    if (!result || !result.ok) throw new Error(result?.error || "Tab không trả kết quả.");
    if (result.url && !result.data) {
      // Signed Flow links are fetched here, where the host permission applies.
      const response = await fetch(result.url, { credentials: "include" });
      if (!response.ok) throw new Error(`Tải ảnh Flow lỗi ${response.status}`);
      const blob = await response.blob();
      result = { mime: blob.type, data: await toBase64(blob), source: result.source };
    }
    reply({ type: "result", id: job.id, ok: true, ...result });
  } catch (error) {
    reply({ type: "result", id: job.id, ok: false, error: String(error.message || error) });
  } finally {
    // Back to the user's tab, unless the user has gone to another one meanwhile.
    if (restore) {
      const [now] = await chrome.tabs.query({ active: true, lastFocusedWindow: true }).catch(() => []);
      const tools = Object.values((await chrome.storage.session.get("tabs")).tabs || {}).map((t) => t.id);
      if (!now || tools.includes(now.id)) await chrome.tabs.update(restore, { active: true }).catch(() => {});
    }
  }
}

async function toBase64(blob) {
  const buffer = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (let i = 0; i < buffer.length; i += 0x8000) binary += String.fromCharCode(...buffer.subarray(i, i + 0x8000));
  return btoa(binary);
}

// Who is signed in, for Cấu hình: Google (its sign-in cookie covers Flow and Gemini; accounts: every one signed in,
// the first being Google's default) and ChatGPT (next-auth's session cookie, sometimes split).
async function logins() {
  const has = async (domain, test) => (await chrome.cookies.getAll({ domain })).some((c) => test(c.name));
  const google = await has("google.com", (n) => n === "SID" || n === "__Secure-1PSID");
  let accounts = [];
  if (google) {
    try {
      // Google answers its account list only to its own pages: this one request says it comes from www.google.com.
      await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [1], addRules: [{ id: 1, priority: 1,
        action: { type: "modifyHeaders", requestHeaders: [{ header: "origin", operation: "set", value: "https://www.google.com" }] },
        condition: { urlFilter: "|https://accounts.google.com/ListAccounts", resourceTypes: ["xmlhttprequest", "other"], initiatorDomains: [chrome.runtime.id] } }] });
      const r = await fetch("https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard", { method: "POST", credentials: "include" });
      accounts = JSON.parse(await r.text())[1].map((a) => a[3]).filter((e) => /@/.test(e));
    } catch {}
  }
  return { google, accounts, chatgpt: await has("chatgpt.com", (n) => n.startsWith("__Secure-next-auth.session-token")) };
}

// MV3 workers sleep; an alarm wakes the worker to reconnect to the bridge.
chrome.alarms.create("bridge", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
// A real left click at (x, y) in the tab's viewport, sent through the debugger so the page sees a trusted event.
// Chrome shows its "debugging this browser" bar while attached, for this moment only. The window is left where it is.
async function trustedClick(tab, x, y) {
  await chrome.tabs.update(tab.id, { active: true });
  const target = { tabId: tab.id };
  await chrome.debugger.attach(target, "1.3");
  try {
    const mouse = (type, extra = {}) => chrome.debugger.sendCommand(target, "Input.dispatchMouseEvent", { type, x, y, button: "left", ...extra });
    await mouse("mouseMoved", { button: "none" });
    await mouse("mousePressed", { buttons: 1, clickCount: 1 });
    await mouse("mouseReleased", { buttons: 0, clickCount: 1 });
  } finally {
    await chrome.debugger.detach(target).catch(() => {});
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "click" && _sender.tab) {
    trustedClick(_sender.tab, message.x, message.y).then(() => sendResponse({ ok: true }), (error) => sendResponse({ ok: false, error: String(error.message || error) }));
    return true;
  }
  if (message?.type === "progress" && _sender.tab) {
    reply({ type: "progress", id: "tab", stage: message.stage });
    return;
  }
  if (message?.type === "needs-click" && _sender.tab) {
    // The automatic click did not start Flow: bring that tab to the front for the user's click.
    chrome.tabs.update(_sender.tab.id, { active: true });
    chrome.windows.update(_sender.tab.windowId, { focused: true });
    reply({ type: "progress", id: "flow", stage: "waiting for the Flow click" });
    return;
  }
  if (message?.type === "status") {
    connect();
    sendResponse({ connected: !!socket && socket.readyState === WebSocket.OPEN });
  }
});
connect();
