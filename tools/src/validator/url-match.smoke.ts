/**
 * 校验器 URL 匹配原语冒烟测试 —— 用共享 golden 钉死校验器**实际使用**的
 * allowToRegex/urlCoveredByAllow/scopePrefix（经 validator/index.ts 的 re-export 面，
 * 实现单源在 @elecon/broker-primitives，审阅 P2-4），与 broker 两端（server 同包 /
 * client url_match.dart）行为一致。
 *
 *   contract/golden/broker/url-match.json  →  {urlCoveredByAllow, scopePrefix}  →  逐例等于 expected
 *
 * 校验器是 manifest 的**静态闸门**（C4/C6/C7 用同一匹配约定决定 scope ⊆ allow 等）；
 * broker 是**运行时**注入决策。历史上各持内联实现、由本测试事后钉死；现已结构性
 * 单源，本测试保留为接线哨兵（校验器改用别的实现/re-export 断链即红）。
 * 校验器无运行时 url-vs-scope 匹配（scopeMatches 由 broker 独有），故跳过该节。
 *
 *   运行：cd tools && npm run smoke:urlmatch
 *
 * 🔒 覆盖红线 #1 注入决策匹配约定；与被测代码一并须人工 + 安全清单复核。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { scopePrefix, urlCoveredByAllow } from "./index.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const goldenPath = `${repoRoot}contract/golden/broker/url-match.json`;

interface CoverCase {
  name: string;
  url: string;
  allow: string[];
  expected: boolean;
}
interface PrefixCase {
  name: string;
  pattern: string;
  expected: string;
}
interface GoldenFile {
  urlCoveredByAllow: CoverCase[];
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
  for (const c of g.scopePrefix) {
    assert.strictEqual(scopePrefix(c.pattern), c.expected, `scopePrefix '${c.name}': pattern=${c.pattern}`);
    passed++;
  }

  const total = g.urlCoveredByAllow.length + g.scopePrefix.length;
  assert.ok(total > 0, "golden 向量为空");
  console.log(`validator url-match smoke: ${passed}/${total} 例通过 ✅（与 broker 共享 golden）`);
}

main();
