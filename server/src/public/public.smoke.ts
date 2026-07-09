/**
 * public 服务冒烟测试 —— 校验路由与零凭证/无状态不变量（不监听端口，直调 handler）。
 *
 * 🔒 分发验签 gate 未接线（人工闭环），故 /adapters/<id> 期望 501/403，非 200。
 *
 *   运行：cd server && npm run smoke:public
 */

import { strict as assert } from "node:assert";
import type { IncomingMessage, ServerResponse } from "node:http";
import { handler, listAdapters } from "./index.js";

interface FakeRes {
  code: number;
  body: unknown;
}

function invoke(url: string): FakeRes {
  const captured: FakeRes = { code: 0, body: undefined };
  const req = { url, headers: {} } as IncomingMessage;
  const res = {
    writeHead(code: number) {
      captured.code = code;
      return this;
    },
    end(payload?: string) {
      captured.body = payload ? JSON.parse(payload) : undefined;
    },
  } as unknown as ServerResponse;
  handler(req, res);
  return captured;
}

// health
{
  const r = invoke("/health");
  assert.strictEqual(r.code, 200);
  assert.deepStrictEqual(r.body, { status: "ok", stateless: true, zeroCredential: true });
  console.log("✓ /health（无状态/零凭证标注）");
}

// 列表：至少含真实 adapter，且标注 signed 状态
{
  const r = invoke("/adapters");
  assert.strictEqual(r.code, 200);
  const list = (r.body as { adapters: Array<{ adapterId: string; signed: boolean }> }).adapters;
  assert.ok(Array.isArray(list), "adapters 应为数组");
  assert.ok(list.some((a) => a.adapterId === "school-xidian"), "应发现 school-xidian");
  // 当前真实 adapter 均未签名 → 分发被拒（红线 #4）
  assert.ok(list.every((a) => a.signed === false), "当前 adapter 均未签名");
  console.log(`✓ /adapters 列表（${list.length} 个）`);
}

// 未签名 adapter 分发被拒（红线 #4）
{
  const r = invoke("/adapters/school-xidian");
  assert.strictEqual(r.code, 403, "未签名 adapter 应被拒（release 仅分发签名包）");
  assert.strictEqual((r.body as { status: string }).status, "unsigned_rejected");
  console.log("✓ 未签名 adapter 分发被拒（403）");
}

// 未知 adapter → 404
{
  const r = invoke("/adapters/school-nonexistent");
  assert.strictEqual(r.code, 404);
  console.log("✓ 未知 adapter → 404");
}

// 验签 gate 未接线的已签名场景无法在此覆盖（无签名夹具）——留待人工闭环 signer 后补。
// 吊销清单分发待人工闭环
{
  const r = invoke("/revocations");
  assert.strictEqual(r.code, 501);
  console.log("✓ /revocations 待人工闭环（501）");
}

// listAdapters 纯函数可直接调用
{
  const list = listAdapters();
  assert.ok(list.length >= 2, "应至少发现 xidian + xjt");
  console.log("✓ listAdapters() 可编程调用");
}

console.log("\npublic smoke 全部通过 ✅  —— 验签 gate / 吊销分发留待人工闭环。");
