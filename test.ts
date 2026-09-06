#!/usr/bin/env bun
// The one thing this action must never do is fail the release.
//
//   bun test.ts
//
// Covers the success path against a stub that speaks the OpenAI format, and
// the three ways a call goes wrong -- unset, unreachable, error body. In all
// three the output file has to come back holding the commits unchanged.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "release-notes-action-"));
const commitsFile = join(dir, "commits.md");
const commits = "- fix(leave): 休假時數不含週末\n- feat(payroll): 補算同一期薪資";
writeFileSync(commitsFile, commits);

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
  const outputs = join(dir, `outputs-${Math.random().toString(36).slice(2)}`);
  writeFileSync(outputs, "");
  const p = Bun.spawn(["bash", join(import.meta.dir, "notes.sh")], {
    env: {
      ...process.env,
      COMMITS_FILE: commitsFile,
      OUTPUT_FILE: join(dir, "notes.md"),
      GITHUB_OUTPUT: outputs,
      ...env,
    },
    stdout: "ignore",
    stderr: "ignore",
  });
  const code = await p.exited;
  return {
    notes: readFileSync(join(dir, "notes.md"), "utf8"),
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

const good = await run({ AI_BASE_URL: base, AI_MODEL: "gpt-test", AI_API_KEY: "k" });
ok("模型回覆成為說明", good.notes.includes("**休假**：時數不含週末"));
ok("成功時 failed=0", good.outputs.failed === "0");
ok("回報寫出去的檔案", good.outputs.file?.endsWith("notes.md") === true);
ok("打的是 chat completions", seen?.path === "/v1/chat/completions");
ok("帶著金鑰", seen?.auth === "Bearer k");
ok("送出設定的模型", seen?.body?.model === "gpt-test");
ok("commit 清單進了 prompt", String(seen?.body?.messages?.[1]?.content).includes("休假時數不含週末"));

// Newer OpenAI models reject both fields; sending neither keeps the action
// working across model generations.
ok("不送 temperature", seen?.body?.temperature === undefined);
ok("不送 max_tokens", seen?.body?.max_tokens === undefined);

const withContext = await run({
  AI_BASE_URL: base,
  AI_MODEL: "m",
  AI_API_KEY: "k",
  CONTEXT: "這是一套財務系統",
});
ok("context 交給模型", String(seen?.body?.messages?.[0]?.content).startsWith("這是一套財務系統"));
ok("帶 context 仍然寫出說明", withContext.notes.length > 0);

// A gateway in front of the model can want a header of its own; Cloudflare AI
// Gateway wants this one when the gateway itself is authenticated.
await run({
  AI_BASE_URL: base,
  AI_MODEL: "m",
  AI_API_KEY: "k",
  AI_EXTRA_HEADERS: "cf-aig-authorization: Bearer cf",
});
ok("送出額外的標頭", seen?.gateway === "Bearer cf");
ok("額外的標頭不取代金鑰", seen?.auth === "Bearer k");

// Inputs win over the environment, so a job-level default can be overridden
// on one step.
await run({ AI_BASE_URL: "https://192.0.2.1/v1", INPUT_BASE_URL: base, AI_MODEL: "m", AI_API_KEY: "k" });
ok("input 覆蓋環境變數", seen?.path === "/v1/chat/completions");

reply = () => Response.json({ error: { message: "model not found" } }, { status: 404 });
const apiError = await run({ AI_BASE_URL: base, AI_MODEL: "nope", AI_API_KEY: "k" });
ok("模型回錯誤時不失敗", apiError.code === 0);
ok("模型回錯誤時回退成 commit 清單", apiError.notes.trim() === commits);
ok("模型回錯誤時 failed=1", apiError.outputs.failed === "1");

stub.stop(true);

// Reserved by RFC 5737 for documentation; nothing answers there.
const unreachable = await run({ AI_BASE_URL: "https://192.0.2.1/v1", AI_MODEL: "m", AI_API_KEY: "k" });
ok("端點連不上時不失敗", unreachable.code === 0);
ok("端點連不上時回退成 commit 清單", unreachable.notes.trim() === commits);

const unset = await run({});
ok("沒有設定模型時不失敗", unset.code === 0);
ok("沒有設定模型時回退成 commit 清單", unset.notes.trim() === commits);
ok("沒有設定模型時 failed=1", unset.outputs.failed === "1");

rmSync(dir, { recursive: true, force: true });
console.log(failed === 0 ? "\n全部通過" : `\n${failed} 項未通過`);
process.exit(failed === 0 ? 0 : 1);
