/**
 * Broker B1 注入策略冒烟测试 —— 用 golden 向量穷举决策面。
 *
 *   contract/golden/broker/inject-policy.json  →  decideInjection  →  逐例等于 expected
 *
 * 同一份 golden 由客户端（Dart）照样跑（两端双跑，ADR-001 §8）；并与 tools 校验器
 * 的 C4/C6/C7 共享匹配约定（url-match.ts 文件头）。
 *
 *   运行：cd server && npm run smoke:broker
 *
 * 🔒 本测试覆盖红线 #1 注入决策路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { decideInjection, type BrokerManifestView, type InjectionDecision } from "./inject-policy.js";

const repoRoot = fileURLToPath(new URL("../../../../", import.meta.url));
const goldenPath = `${repoRoot}contract/golden/broker/inject-policy.json`;

interface GoldenCase {
  name: string;
  url: string;
  view: BrokerManifestView;
  expected: InjectionDecision;
}

interface GoldenFile {
  cases: GoldenCase[];
}

function main(): void {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as GoldenFile;
  assert.ok(golden.cases.length > 0, "golden 向量为空");

  let passed = 0;
  for (const c of golden.cases) {
    const actual = decideInjection(c.url, c.view);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `case '${c.name}': url=${c.url}\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
    passed++;
  }

  console.log(`broker B1 inject-policy smoke: ${passed}/${golden.cases.length} 例通过 ✅`);
}

main();
