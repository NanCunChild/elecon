/**
 * 首个真实 imperative adapter 端到端冒烟（Gate A）—— school-xjt（西安交通大学教务处通知）。
 *
 * adapter（index.js，requestGraph: imperative）→ runImperativeAdapter → ctx.fetch → proxyFetch
 *   → **录制夹具回放 Transport**（adapters/school-xjt/fixtures/，已脱敏）。
 *
 * 验证整条真实管线（用录制的真实响应，可复现、CI 友好，不打活网）：
 *   ① 多步握手：GET /（挑战页）→ POST /dynamic_challenge（拿 client_id）→ GET /（真实通知页）
 *   ② body-token 缺口：client_id 经 Set-Cookie（jar 捕获）+ ctx.setEphemeralCookie（冗余兜底）→
 *      第 2 次 GET / 自动携带 client_id cookie
 *   ③ 产出 = notice.list，过 contract schema（elecon.notice.list 1.1）
 *
 *   运行：cd server && npm run smoke:xjt
 *
 * 🔒 imperative 凭证注入承重路径（红线 #1）：与被测代码一并须人工 + 安全清单复核。
 */

import { strict as assert } from "node:assert";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
// codegen 产物（contract/schema 单源，审阅 P0-1）：ajv 校验通过后以此类型消费，
// 替代裸 `as { items: ... }` cast。类型声明零运行时，不参与 emit。
import type { NoticeList } from "../../../contract/generated/ts/notice.list.js";
import {
  adapterDirIfPresent,
  FakeTransport,
  noResolver,
  readText,
  resolveRepoRoot,
  runMain,
  skipSmoke,
} from "./__testutils__/smoke-utils.js";
import type { BrokerManifestView } from "./broker/inject-policy.js";
import { runImperativeAdapter } from "./sandbox.js";
import { TrustedAdapterContext } from "./trusted-context.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  const xjtDir = adapterDirIfPresent(repoRoot, "school-xjt");
  if (!xjtDir) {
    skipSmoke("缺 elecon-adapters 中的 school-xjt");
    return;
  }
  const fixDir = `${xjtDir}/fixtures/dean.xjtu.edu.cn`;
  const source = readText(`${xjtDir}/index.js`);
  const challengeHtml = readText(`${fixDir}/challenge.html`);
  const noticeHtml = readText(`${fixDir}/notice.html`);
  const challengeResp = JSON.parse(readText(`${fixDir}/challenge_response.json`)) as {
    headers: Record<string, string>;
    body: { success: boolean; client_id: string };
  };

  // 录制的真实握手三步（已脱敏）：
  const transport = new FakeTransport([
    // [1] GET / → JS 挑战页
    {
      status: 200,
      headers: { "content-type": "text/html" },
      setCookie: [],
      location: null,
      body: challengeHtml,
    },
    // [2] POST /dynamic_challenge → client_id（origin 经 Set-Cookie 下发 + body）
    {
      status: 200,
      headers: { "content-type": "application/json" },
      setCookie: [challengeResp.headers["Set-Cookie"]!],
      location: null,
      body: JSON.stringify(challengeResp.body),
    },
    // [3] GET /（带会话 cookie）→ 真实通知页
    {
      status: 200,
      headers: { "content-type": "text/html" },
      setCookie: [],
      location: null,
      body: noticeHtml,
    },
  ]);

  const view: BrokerManifestView = { allow: ["https://dean.xjtu.edu.cn/*"] }; // manifest：全 passthrough、无 credentials

  const { data } = await runImperativeAdapter(
    { source, capability: "notice.list", params: {}, nowMs: 1_700_000_000_000 },
    { trust: TrustedAdapterContext.devSideload(), view, resolver: noResolver, transport },
  );

  // ── 握手顺序 + 会话 cookie 携带 ──
  assert.equal(transport.seen.length, 3, "应发 3 次请求（GET / → POST 挑战 → GET /）");
  assert.equal(transport.seen[1]!.method, "POST", "第 2 步为 POST 挑战端点");
  assert.ok(transport.seen[1]!.url.endsWith("/dynamic_challenge"), "第 2 步打 /dynamic_challenge");
  const cookie3 = transport.seen[2]!.headers["Cookie"] ?? "";
  assert.ok(cookie3.includes("client_id="), `第 3 步应携带 client_id 会话 cookie（实得：${cookie3}）`);
  console.log("  ✓ 多步握手 + client_id 会话 cookie 跨步携带");

  // ── contract schema 校验（elecon.notice.list 1.1）——先验形状，再类型化消费 ──
  const schema = JSON.parse(readText(`${repoRoot}contract/schema/notice.list.schema.json`));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema as object);
  assert.ok(validate(data), `产出未通过 notice.list schema：${JSON.stringify(validate.errors)}`);
  console.log("  ✓ 通过 contract schema（elecon.notice.list 1.1）");

  // ── 产出语义（ajv 通过 ⇒ 形状即 NoticeList；类型来自 codegen 单源，非手写断言）──
  const result = data as NoticeList;
  assert.ok(result.items.length > 0, "应解析出非空通知列表");
  for (const it of result.items) {
    assert.ok(it.id.length > 0, "item.id 非空");
    assert.ok(it.title.length > 0, "item.title 非空");
    assert.ok(it.url?.startsWith("http"), "item.url 绝对 URL");
    assert.equal(it.category, "academic");
    assert.equal(it.source, "教务处");
  }
  console.log(`  ✓ 解析出 ${result.items.length} 条通知（结构齐全，typed）`);

  console.log("首个真实 fetch adapter（school-xjt notice.list）端到端跑通 ✅");
}

runMain(main);
