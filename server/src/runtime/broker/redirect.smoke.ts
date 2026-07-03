/**
 * Broker B3 重定向冒烟测试 —— golden 驱动 decideRedirect + followRedirects driver。
 *
 *   contract/golden/broker/redirect.json  →  decideRedirect  →  逐例等于 expected
 *   followRedirects + fake fetcher         →  链路跟随 / 超跳数 / 越 allow / Location 不外泄
 *
 *   运行：cd server && npm run smoke:redirect
 *
 * 🔒 覆盖红线 #1 数据外泄面（跟随出 allow / Location 泄露）；与被测代码一并须人工 +
 * 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { resolveRepoRoot, runMain } from "../__testutils__/smoke-utils.js";

import {
  decideRedirect,
  followRedirects,
  type RedirectDecision,
  type RedirectFetcher,
  type RedirectHop,
  type RedirectInput,
} from "./redirect.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const goldenPath = `${repoRoot}contract/golden/broker/redirect.json`;

interface GoldenCase {
  name: string;
  input: RedirectInput;
  expected: RedirectDecision;
}
interface GoldenFile {
  cases: GoldenCase[];
}

function goldenTests(): number {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as GoldenFile;
  assert.ok(golden.cases.length > 0, "golden 向量为空");
  for (const c of golden.cases) {
    const actual = decideRedirect(c.input);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `case '${c.name}'\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
  }
  return golden.cases.length;
}

function scriptedFetcher(script: Record<string, RedirectHop>): RedirectFetcher {
  return {
    fetch: (url) => Promise.resolve(script[url] ?? { status: 404, location: null }),
  };
}

async function driverTests(): Promise<void> {
  const allow = ["https://h.edu.cn/*"];

  // 链路跟随到最终 200（含一跳相对 Location）
  const chain = scriptedFetcher({
    "https://h.edu.cn/a": { status: 302, location: "https://h.edu.cn/b" },
    "https://h.edu.cn/b": { status: 302, location: "/c" },
    "https://h.edu.cn/c": { status: 200, location: null },
  });
  assert.deepStrictEqual(await followRedirects("https://h.edu.cn/a", chain, { allow }), {
    finalUrl: "https://h.edu.cn/c",
    status: 200,
    hops: 2,
    stopReason: null,
  });

  // 自循环 → 触顶 maxHops 停止
  const loop = scriptedFetcher({
    "https://h.edu.cn/loop": { status: 302, location: "https://h.edu.cn/loop" },
  });
  const loopOut = await followRedirects("https://h.edu.cn/loop", loop, { allow, maxHops: 5 });
  assert.equal(loopOut.stopReason, "max_hops");
  assert.equal(loopOut.hops, 5);

  // 越 allow → 停止于 0 跳，交付当前 3xx
  const evil = scriptedFetcher({
    "https://h.edu.cn/a": { status: 302, location: "https://evil.example.com/x" },
  });
  const evilOut = await followRedirects("https://h.edu.cn/a", evil, { allow });
  assert.deepStrictEqual(evilOut, {
    finalUrl: "https://h.edu.cn/a",
    status: 302,
    hops: 0,
    stopReason: "outside_allow",
  });

  // Location 不外泄：FollowOutcome 结构上无 location / 中间 URL 字段
  assert.ok(!("location" in evilOut), "FollowOutcome 不得含 location 字段");
}

async function main(): Promise<void> {
  const n = goldenTests();
  await driverTests();
  console.log(`broker B3 redirect smoke: golden ${n}/${n} + driver 4/4 例通过 ✅`);
}

runMain(main);
