/**
 * Broker B2 头净化冒烟测试 —— 用 golden 向量穷举请求/响应两方向。
 *
 *   contract/golden/broker/header-sanitize.json  →  sanitize{Request,Response}Headers  →  逐例等于 expected
 *
 * 同一份 golden 由客户端（Dart）照样跑（两端双跑，ADR-001 §8）。
 *
 *   运行：cd server && npm run smoke:header
 *
 * 🔒 覆盖红线 #1 凭证头边界；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";

import {
  sanitizeRequestHeaders,
  sanitizeResponseHeaders,
  type HeaderMap,
} from "./header-sanitize.js";
import { resolveRepoRoot } from "../__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const goldenPath = `${repoRoot}contract/golden/broker/header-sanitize.json`;

interface GoldenCase {
  name: string;
  direction: "request" | "response";
  input: HeaderMap;
  expected: HeaderMap;
}

interface GoldenFile {
  cases: GoldenCase[];
}

function main(): void {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as GoldenFile;
  assert.ok(golden.cases.length > 0, "golden 向量为空");

  let passed = 0;
  for (const c of golden.cases) {
    const actual =
      c.direction === "request"
        ? sanitizeRequestHeaders(c.input)
        : sanitizeResponseHeaders(c.input);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `case '${c.name}' (${c.direction})\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
    passed++;
  }

  console.log(`broker B2 header-sanitize smoke: ${passed}/${golden.cases.length} 例通过 ✅`);
}

main();
