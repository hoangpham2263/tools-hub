import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readUsage, summarizeUsage } from "../setup/usage.mjs";

const now = new Date("2026-11-01T15:00:00");
const at = (hoursAgo) => new Date(now - hoursAgo * 3600000).toISOString();

test("adds up calls per AI and account for today, 7 and 30 days", () => {
  const rows = summarizeUsage([
    { t: at(1), ai: "flow", account: "a@gmail.com", ok: true },
    { t: at(2), ai: "flow", account: "a@gmail.com", ok: false, cause: "BUSY" },
    { t: at(3 * 24), ai: "flow", account: "a@gmail.com", ok: true },
    { t: at(20 * 24), ai: "flow", account: "a@gmail.com", ok: true },
    { t: at(40 * 24), ai: "flow", account: "a@gmail.com", ok: true },
    { t: at(1), ai: "codex", account: "me@x.com", ok: true, in: 1000, cached: 800, out: 200 },
    { t: at(1), ai: "flow", account: "b@gmail.com", ok: true },
  ], { now });
  assert.deepEqual(rows.map((r) => `${r.ai} ${r.account}`), ["codex me@x.com", "flow a@gmail.com", "flow b@gmail.com"]);
  const a = rows[1];
  assert.deepEqual([a.today.calls, a.week.calls, a.month.calls, a.today.fail], [2, 3, 4, 1]);
  assert.equal(a.okSinceFail, true);
  assert.equal(rows[0].today.tokens, 1200);
});

test("a QUOTA with nothing working after it stays the account's state", () => {
  const [row] = summarizeUsage([
    { t: at(5), ai: "gemini", account: "a@gmail.com", ok: true },
    { t: at(1), ai: "gemini", account: "a@gmail.com", ok: false, cause: "QUOTA" },
  ], { now });
  assert.equal(row.lastFail.cause, "QUOTA");
  assert.equal(row.okSinceFail, false);
});

test("skips broken lines and trims a big file to its last days", () => {
  const file = join(mkdtempSync(join(tmpdir(), "usage-")), "ai-usage.jsonl");
  const old = JSON.stringify({ t: at(200 * 24), ai: "flow", account: "", ok: true });
  const recent = JSON.stringify({ t: at(1), ai: "flow", account: "", ok: true });
  writeFileSync(file, `${old}\nnot json\n${recent}\n`);
  assert.equal(readUsage(file, { now }).length, 2);
  assert.equal(readUsage(file, { now, maxBytes: 10 }).length, 1);
  assert.equal(readFileSync(file, "utf8").trim(), recent);
  assert.ok(statSync(file).size < 200);
  assert.deepEqual(readUsage(join(tmpdir(), "missing-usage.jsonl")), []);
});
