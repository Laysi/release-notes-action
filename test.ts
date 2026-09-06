#!/usr/bin/env bun
// The action must never fail the caller's release, and must read the right
// commits before it asks a model about them.
//
//   bun test.ts
//
// Runs against a throwaway git repository so the tag walking, the path and
// type filters and the OpenAI-format request are all checked for real, with a
// stub server standing in for the model.

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = mkdtempSync(join(tmpdir(), "release-notes-action-"));

function git(...args: string[]): void {
  const r = Bun.spawnSync(["git", ...args], {
    cwd: repo,
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "t",
      GIT_AUTHOR_EMAIL: "t@t",
      GIT_COMMITTER_NAME: "t",
      GIT_COMMITTER_EMAIL: "t@t",
    },
  });
  if (r.exitCode !== 0) throw new Error(`git ${args[0]}: ${r.stderr.toString()}`);
}

function commit(subject: string, file = "f.txt"): void {
  mkdirSync(join(repo, file, ".."), { recursive: true });
  writeFileSync(join(repo, file), subject);
  git("add", file);
  git("commit", "-q", "-m", subject);
}

git("init", "-q", "-b", "main");
commit("feat(payroll): 補算同一期薪資");
git("tag", "v0.1.0");
commit("ci: 換一版 runner");
commit("chore(deps): 升級 jq");
commit("fix(leave): 休假時數不含週末");
commit("fix(license): 換一版簽章", "license-server/x.rs");
// A second product shipping from the same history: its tags must not be
// mistaken for the previous version.
git("tag", "license-v9.9.9");
git("tag", "v0.2.0");

let failed = 0;

function ok(label: string, condition: boolean): void {
  if (!condition) failed += 1;
  console.log(`${condition ? "  ok" : "FAIL"}  ${label}`);
}

// Not spawnSync: the stub below runs on this process's event loop, and a
// synchronous spawn blocks it, so the request would never be answered.
async function run(
  env: Record<string, string>,
): Promise<{ notes: string; outputs: Record<string, string>; code: number }> {
  const outputs = join(repo, `outputs-${Math.random().toString(36).slice(2)}`);
  writeFileSync(outputs, "");
  const notes = join(repo, "notes.md");
  const p = Bun.spawn(["bash", join(import.meta.dir, "notes.sh")], {
    cwd: repo,
    env: { ...process.env, TAG: "v0.2.0", OUTPUT_FILE: notes, GITHUB_OUTPUT: outputs, ...env },
    stdout: "ignore",
    stderr: "ignore",
  });
  const code = await p.exited;
  return {
    notes: code === 0 ? readFileSync(notes, "utf8") : "",
    outputs: Object.fromEntries(
      readFileSync(outputs, "utf8")
        .split("\n")
        .filter(Boolean)
        .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
    ),
    code,
  };
}

let seen: { path: string; auth: string; gateway: string; body: any } | null = null;
let reply: () => Response = () =>
  Response.json({ choices: [{ message: { content: "### 修正\n- **休假**：時數不含週末" } }] });

const stub = Bun.serve({
  port: 0,
  async fetch(req) {
    seen = {
      path: new URL(req.url).pathname,
      auth: req.headers.get("authorization") ?? "",
      gateway: req.headers.get("cf-aig-authorization") ?? "",
      body: await req.json(),
    };
    return reply();
  },
});
const base = `http://127.0.0.1:${stub.port}/v1`;
const ai = { AI_BASE_URL: base, AI_MODEL: "gpt-test", AI_API_KEY: "k" };

function prompt(): string {
  return String(seen?.body?.messages?.[1]?.content ?? "");
}

const good = await run({ ...ai, TAG_PATTERN: "v*", EXCLUDE_PATHS: "license-server" });
ok("模型回覆成為說明", good.notes.includes("**休假**：時數不含週末"));
ok("成功時 failed=0", good.outputs.failed === "0");
ok("回報寫出去的檔案", good.outputs.file?.endsWith("notes.md") === true);
ok("找到上一版", good.outputs["previous-tag"] === "v0.1.0");
ok("算出區間", good.outputs.range === "v0.1.0..v0.2.0");
ok("tag-pattern 擋掉另一個產品的 tag", good.outputs["previous-tag"] !== "license-v9.9.9");
ok("送出本版的 commit", prompt().includes("休假時數不含週末"));
ok("不送上一版的 commit", !prompt().includes("補算同一期薪資"));
ok("預設濾掉 ci", !prompt().includes("換一版 runner"));
ok("預設濾掉 chore", !prompt().includes("升級 jq"));
ok("exclude-paths 濾掉整個目錄", !prompt().includes("換一版簽章"));
ok("打的是 chat completions", seen?.path === "/v1/chat/completions");
ok("帶著金鑰", seen?.auth === "Bearer k");
ok("送出設定的模型", seen?.body?.model === "gpt-test");

// Newer OpenAI models reject both fields; sending neither keeps the action
// working across model generations.
ok("不送 temperature", seen?.body?.temperature === undefined);
ok("不送 max_tokens", seen?.body?.max_tokens === undefined);

await run({ ...ai, EXCLUDE_TYPES: "" });
ok("exclude-types 留空就不濾", prompt().includes("換一版 runner"));

await run({ ...ai, TAG_PATTERN: "v*", LIMIT: "1" });
ok("limit 截斷清單", prompt().split("\n").filter((l) => l.startsWith("- ")).length === 1);

await run({ ...ai, PREVIOUS_TAG: "v0.1.0" });
ok("previous-tag 直接指定", prompt().includes("休假時數不含週末"));

await run({ ...ai, CONTEXT: "這是一套財務系統" });
ok("context 交給模型", String(seen?.body?.messages?.[0]?.content).startsWith("這是一套財務系統"));

// A gateway in front of the model can want a header of its own; Cloudflare AI
// Gateway wants this one when the gateway itself is authenticated.
await run({ ...ai, AI_EXTRA_HEADERS: "cf-aig-authorization: Bearer cf" });
ok("送出額外的標頭", seen?.gateway === "Bearer cf");
ok("額外的標頭不取代金鑰", seen?.auth === "Bearer k");

await run({ ...ai, AI_BASE_URL: "https://192.0.2.1/v1", INPUT_BASE_URL: base });
ok("input 覆蓋環境變數", seen?.path === "/v1/chat/completions");

reply = () => Response.json({ error: { message: "model not found" } }, { status: 404 });
const apiError = await run({ ...ai, TAG_PATTERN: "v*" });
ok("模型回錯誤時不失敗", apiError.code === 0);
ok("模型回錯誤時回退成 commit 清單", apiError.notes.includes("- fix(leave): 休假時數不含週末"));
ok("模型回錯誤時 failed=1", apiError.outputs.failed === "1");

stub.stop(true);

// Reserved by RFC 5737 for documentation; nothing answers there.
const unreachable = await run({ AI_BASE_URL: "https://192.0.2.1/v1", AI_MODEL: "m", AI_API_KEY: "k" });
ok("端點連不上時不失敗", unreachable.code === 0);
ok("端點連不上時回退成 commit 清單", unreachable.notes.includes("- fix(leave)"));

const unset = await run({});
ok("沒有設定模型時不失敗", unset.code === 0);
ok("沒有設定模型時回退成 commit 清單", unset.notes.includes("- fix(leave)"));
ok("沒有設定模型時 failed=1", unset.outputs.failed === "1");

// A shallow clone has neither the tag nor the commits, and publishing empty
// notes would hide that. This one is a configuration error, so it fails.
const noTag = await run({ ...ai, TAG: "v9.9.9" });
ok("找不到 tag 就失敗", noTag.code !== 0);

// The first release has no previous tag: the whole history is the range.
const first = await run({ ...ai, TAG: "v0.1.0", TAG_PATTERN: "v*" });
ok("第一版沒有上一版", first.outputs["previous-tag"] === "");
ok("第一版取整段歷史", first.outputs.range === "v0.1.0");

rmSync(repo, { recursive: true, force: true });
console.log(failed === 0 ? "\n全部通過" : `\n${failed} 項未通過`);
process.exit(failed === 0 ? 0 : 1);
