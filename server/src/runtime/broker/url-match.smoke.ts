/**
 * Broker URL 匹配原语冒烟测试 —— 用共享 golden 钉死 server 侧 url-match.ts 的行为。
 *
 *   contract/golden/broker/url-match.json  →  {urlCoveredByAllow, scopeMatches, scopePrefix}  →  逐例等于 expected
 *
 * 同一份 golden 由 client（Dart `test/broker_url_match_test.dart`）与 tools 校验器
 * （`tools/src/validator/url-match.smoke.ts`，跑其内联的同名原语子集）照样跑——三方
 * 共享一份事实源，任一处正则/转义漂移即 CI 红。钉死的是**行为**，不是源文件
 * （ADR-001 §8 两端双跑哲学 + url-match.ts 文件头）。
 *
 *   运行：cd server && npm run smoke:urlmatch
 *
 * 🔒 本测试覆盖红线 #1 注入决策匹配路径；与被测代码一并须人工 + 安全清单复核。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { urlCoveredByAllow, scopeMatches, scopePrefix } from "./url-match.js";

const repoRoot = fileURLToPath(new URL("../../../../", import.meta.url));
const goldenPath = `${repoRoot}contract/golden/broker/url-match.json`;

interface CoverCase {
  name: string;
  url: string;
  allow: string[];
  expected: boolean;
}
interface ScopeCase {
  name: string;
  url: string;
  pattern: string;
  expected: boolean;
}
interface PrefixCase {
  name: string;
  pattern: string;
  expected: string;
}
interface GoldenFile {
  urlCoveredByAllow: CoverCase[];
  scopeMatches: ScopeCase[];
  scopePrefix: PrefixCase[];
}

function main(): void {
  const g = JSON.parse(readFileSync(goldenPath, "utf8")) as GoldenFile;
  let passed = 0;

  for (const c of g.urlCoveredByAllow) {
    assert.strictEqual(
      urlCoveredByAllow(c.url, c.allow),
      c.expected,
      `urlCoveredByAllow '${c.name}': url=${c.url} allow=${JSON.stringify(c.allow)}`,
    );
    passed++;
  }
  for (const c of g.scopeMatches) {
    assert.strictEqual(
      scopeMatches(c.url, c.pattern),
      c.expected,
      `scopeMatches '${c.name}': url=${c.url} pattern=${c.pattern}`,
    );
    passed++;
  }
  for (const c of g.scopePrefix) {
    assert.strictEqual(
      scopePrefix(c.pattern),
      c.expected,
      `scopePrefix '${c.name}': pattern=${c.pattern}`,
    );
    passed++;
  }

  const total = g.urlCoveredByAllow.length + g.scopeMatches.length + g.scopePrefix.length;
  assert.ok(total > 0, "golden 向量为空");
  console.log(`broker url-match smoke: ${passed}/${total} 例通过 ✅`);
}

main();
