// Cấu hình page (hub/setup/page.html): the steps from setup-check.ps1 (POST /api/setup), each AI with the account it is
// signed in to, a button on each that can be fixed or changed, then Model AI. "← Quay lại" goes to ?back= (the page it
// was opened from), so the menu and every tool share this one page.
(() => {
  const $ = (s) => document.querySelector(s);
  const post = (path, data, method = "POST") => fetch(path, { method, body: data ? JSON.stringify(data) : undefined }).then((r) => r.json()).catch(() => ({ error: "Không kết nối được." }));
  const el = (tag, cls, text) => Object.assign(document.createElement(tag), cls ? { className: cls } : {}, text != null ? { textContent: text } : {});
  // Only a page of this server: a path, never another site.
  const back = new URLSearchParams(location.search).get("back");
  const backUrl = back && back.startsWith("/") && !back.startsWith("//") ? back : "/";
  $(".back").onclick = () => { location.href = backUrl; };
  fetch("/api/root").then((r) => r.json()).then((r) => { if (r.version) document.title = `Cấu hình ${r.version}`; }).catch(() => {});

  // Which section each step is in, in this order; anything else the check adds goes under Cài đặt.
  const AI = ["login", "google", "antigravity"];
  const BASE = ["drive", "node", "codex", "browser"];
  const marks = { ok: ["✔", "darkgreen"], fail: ["✖", "firebrick"], warn: ["!", "#b06000"] };
  const items = new Map();
  const item = (id, parent) => {
    const box = el("div", "item"), mark = el("span", "mark", "○"), body = el("div", "body"), side = el("div", "side");
    const name = el("div", "name"), account = el("div", "account"), detail = el("div", "detail", "Đang kiểm tra…"), uses = el("div", "uses"), extra = el("div");
    const fix = el("button", "btn", ""); fix.type = "button"; fix.hidden = true;
    body.append(name, account, detail, uses, extra); side.append(fix);
    box.append(mark, body, side);
    parent.append(box);
    const row = { box, mark, name, account, detail, uses, extra, fix, side };
    items.set(id, row);
    return row;
  };
  for (const id of AI) item(id, $("#ai"));
  for (const id of BASE) item(id, $("#base"));
  const NAMES = { login: "Codex (ChatGPT)", google: "Google (Flow, Gemini web)", antigravity: "Antigravity CLI", drive: "Mật khẩu app", node: "Node.js", codex: "Codex", browser: "Extension Tools Hub" };
  for (const [id, row] of items) row.name.textContent = NAMES[id];
  const LABELS = { install: "Cài", browser: "Mở", login: "Đăng nhập", drive: "Đăng nhập", google: "Đăng nhập", antigravity: "Đăng nhập" };
  // Beside the sign-in button: the AI's own site in Chrome, to see or switch the account there.
  const SITES = { login: [["Mở ChatGPT", "chatgpt"]], google: [["Mở Gemini", "gemini"], ["Mở Flow", "flow"]] };
  const WAIT = {
    install: "Đang cài…",
    browser: "Đã mở trang tiện ích của Chrome và thư mục extension: bật Chế độ nhà phát triển, bấm Tải tiện ích đã giải nén, chọn thư mục vừa mở, xong bấm Kiểm tra lại.",
    login: "Đang mở trang đăng nhập ChatGPT trong Chrome…",
    google: "Đã mở trang chọn tài khoản Google trong Chrome: đăng nhập, thêm hoặc đổi tài khoản ở đó, xong bấm Kiểm tra lại.",
    antigravity: "Đã mở Terminal chạy Antigravity: gõ /logout nếu muốn đổi tài khoản, rồi /login và đăng nhập Google trên trang mở ra. Xong bấm Kiểm tra lại.",
    site: "Đã mở trang trong Chrome. Đăng nhập hoặc đổi tài khoản ở đó, xong bấm Kiểm tra lại.",
  };

  let checking = false;
  const check = async () => {
    if (checking) return;
    checking = true;
    $(".again").disabled = true;
    for (const row of items.values()) { row.mark.textContent = "○"; row.mark.style.color = ""; row.detail.textContent = "Đang kiểm tra…"; row.fix.hidden = true; row.side.querySelectorAll(".site").forEach((b) => b.remove()); }
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 60000);
    const report = await fetch("/api/setup", { method: "POST", signal: abort.signal, cache: "no-store" }).then((r) => r.json())
      .catch((e) => ({ error: e.name === "AbortError" ? "Kiểm tra quá thời gian. Bấm Kiểm tra lại." : "Mất kết nối với app. Bấm Kiểm tra lại." }));
    clearTimeout(timer);
    const steps = [].concat(report.Steps || []);
    if (!steps.length) for (const row of items.values()) { row.mark.textContent = "!"; row.mark.style.color = marks.warn[1]; row.detail.textContent = report.error || "Chưa kiểm tra được. Bấm Kiểm tra lại."; }
    const quota = steps.find((s) => s.Id === "quota");
    for (const step of steps) {
      const row = items.get(step.Id) || (step.Id !== "quota" && item(step.Id, $("#base")));
      if (!row) continue;
      if (!NAMES[step.Id]) row.name.textContent = step.Title;
      const [mark, color] = marks[step.State] || ["○", ""];
      row.mark.textContent = mark; row.mark.style.color = color;
      row.detail.textContent = step.Detail || "";
      // The AIs: whose account, and what it is used for; Codex also shows what is left of its quota.
      const isAi = AI.includes(step.Id);
      row.account.hidden = !isAi;
      // Expired or signed out still names whose account it was (setup-check.ps1 keeps the last one seen).
      const lapsed = { expired: " · hết hạn", signedout: " · đã đăng xuất" }[step.SignIn] || "";
      row.account.textContent = step.Account ? `Tài khoản: ${step.Account}${lapsed}` : step.State === "ok" ? "Tài khoản: chưa đọc được email" : "Tài khoản: chưa đăng nhập";
      row.account.classList.toggle("none", !step.Account || !!lapsed);
      // Google with more than one account signed in: choose here which one Flow and Gemini run with.
      const accounts = [].concat(step.Accounts || []);
      if (step.Id === "google" && step.State === "ok" && accounts.length > 1) {
        const pick = el("select", "account-pick");
        pick.setAttribute("aria-label", "Tài khoản Google cho Flow và Gemini");
        for (const email of accounts) pick.append(Object.assign(el("option", "", email), { value: email, selected: email === step.Account }));
        pick.onchange = async () => {
          pick.disabled = true;
          const r = await post("/api/config/google", { email: pick.value });
          pick.disabled = false;
          row.detail.textContent = r.error || `Flow và Gemini sẽ chạy bằng ${r.email || pick.value}.`;
        };
        row.account.replaceChildren("Tài khoản: ", pick);
      }
      row.uses.textContent = step.Uses ? `Dùng cho: ${step.Uses}` : "";
      if (step.Id === "login" && quota && quota.State !== "wait" && quota.Detail) row.detail.textContent = `${step.Detail} Hạn mức: ${quota.Detail}`;
      if (step.Id === "antigravity" && step.State !== "ok") row.uses.textContent = `Dùng cho: ${step.Uses || "Viết review: Antigravity CLI"}. Đăng nhập trong Antigravity, đổi tài khoản cũng ở đó.`;
      if (step.Action) {
        const signedIn = step.State === "ok";
        row.fix.textContent = signedIn && ["login", "google", "antigravity"].includes(step.Action) ? "Đổi tài khoản" : ["expired", "signedout"].includes(step.SignIn) ? "Đăng nhập lại" : signedIn && step.Action === "drive" ? "Đăng xuất" : LABELS[step.Action] || "Mở";
        row.fix.classList.toggle("primary", !signedIn);
        row.fix.hidden = false;
        row.fix.onclick = () => fix(step, row);
      }
      if (step.Action && SITES[step.Id]) for (const [text, site] of SITES[step.Id]) {
        const b = el("button", "btn site", text);
        b.type = "button";
        b.onclick = () => fix({ ...step, Action: "site" }, row, site);
        row.side.append(b);
      }
    }
    if (!items.get("login").detail.dataset.code) watchLogin();
    $(".again").disabled = false;
    checking = false;
  };

  // While Codex signs in: the one-time code to type on the page opened in Chrome, with Chép mã.
  let watching = 0;
  const watchLogin = () => {
    if (watching) return;
    watching = setInterval(async () => {
      const { code } = await fetch("/api/setup-login").then((r) => r.json()).catch(() => ({}));
      const detail = items.get("login").detail;
      if (!code) { if (detail.dataset.code) { delete detail.dataset.code; } return; }
      if (detail.dataset.code === code && detail.querySelector(".copy-code")) return;
      detail.dataset.code = code;
      const copy = el("button", "copy-code", "Chép mã");
      copy.type = "button";
      copy.onclick = async () => {
        // The clipboard API needs a focused page; the old copy command covers the rest.
        const done = await navigator.clipboard.writeText(code).then(() => true, () => {
          const box = Object.assign(document.createElement("textarea"), { value: code });
          document.body.append(box); box.select();
          const ok = document.execCommand("copy");
          box.remove();
          return ok;
        });
        copy.textContent = done ? "Đã chép" : "Chưa chép được";
        setTimeout(() => { copy.textContent = "Chép mã"; }, 2000);
      };
      detail.replaceChildren(`Mã đăng nhập: ${code} `, copy, ". Dán vào trang đăng nhập vừa mở trong Chrome (đăng nhập tài khoản ChatGPT muốn dùng). Lỗi thì bấm lại để lấy mã mới.");
      for (const b of buttons()) b.disabled = false;
    }, 1000);
  };

  // Mật khẩu app: typed here once for every tool, or logged out.
  const drive = (step, row) => {
    if (step.State === "ok") {
      if (!confirm("Đăng xuất mật khẩu app trên máy này?")) return;
      return post("/api/config/drive", null, "DELETE").then(check);
    }
    if (row.extra.querySelector(".drive-form")) return row.extra.querySelector("input").focus();
    const form = el("div", "drive-form"), pass = el("input"), go = el("button", "btn primary", "Lưu"), err = el("div", "err");
    pass.type = "password"; pass.placeholder = "Mật khẩu app"; go.type = "button";
    form.append(pass, go);
    row.extra.replaceChildren(form, err);
    const save = async () => {
      go.disabled = true;
      const r = await post("/api/config/drive", { password: pass.value });
      go.disabled = false;
      if (r.error) { err.textContent = r.error; return; }
      row.extra.replaceChildren();
      check();
    };
    go.onclick = save;
    pass.onkeydown = (e) => { if (e.key === "Enter") save(); };
    pass.focus();
  };

  // Installing, opening Chrome or signing in runs on this computer; the steps are checked again after.
  const buttons = () => [...document.querySelectorAll(".item .side .btn")];
  const fix = async (step, row, site) => {
    if (step.Action === "drive") return drive(step, row);
    for (const b of buttons()) b.disabled = true;
    row.detail.textContent = WAIT[step.Action] || "Đang mở…";
    if (step.Action === "login") watchLogin();
    const r = await post("/api/setup-step", { step: step.Action, site });
    if (r.superseded) return;
    for (const b of buttons()) b.disabled = false;
    // Signing in on a site or in Antigravity happens outside this page: keep the hint until Kiểm tra lại.
    if (["google", "antigravity", "site"].includes(step.Action) && !r.error) return;
    await check();
    if (r.error) row.detail.textContent = r.error;
  };
  $(".again").onclick = check;

  // Model AI: the model and reasoning level Codex uses; empty keeps Codex's own default. Saved for every tool.
  const model = $(".model"), effort = $(".effort");
  const effortNames = { low: "Thấp · ít token nhất", medium: "Vừa", high: "Cao", xhigh: "Rất cao", max: "Tối đa", ultra: "Siêu cao" };
  let models = [];
  const fill = (select, values, labels, value) => { select.replaceChildren(...values.map((v, i) => Object.assign(el("option", "", labels[i]), { value: v }))); select.value = values.includes(value) ? value : ""; };
  const fillEfforts = (value) => {
    const m = models.find((x) => x.slug === model.value);
    const efforts = ["", ...(m ? [].concat(m.efforts || []) : ["low", "medium", "high"])];
    fill(effort, efforts, efforts.map((e) => (e ? effortNames[e] + (m && e === m.default_effort ? " (mặc định)" : "") : "Mức suy nghĩ mặc định")), value);
  };
  model.onchange = effort.onchange = async () => {
    fillEfforts(effort.value);
    const r = await post("/api/config/ai", { model: model.value, effort: effort.value });
    if (r.error) alert(r.error);
  };
  fetch("/api/config/ai").then((r) => r.json()).then((r) => {
    models = [].concat(r.models || []);
    const saved = r.settings || {};
    if (saved.model && !models.some((m) => m.slug === saved.model)) models.unshift({ slug: saved.model, name: saved.model, efforts: ["low", "medium", "high"], default_effort: "" });
    fill(model, ["", ...models.map((m) => m.slug)], ["Model mặc định của Codex", ...models.map((m) => m.name)], saved.model || "");
    fillEfforts(saved.effort || "");
  }).catch(() => { fill(model, [""], ["Model mặc định của Codex"], ""); fillEfforts(""); });
  check();
})();
