/**
 * 校验器 URL 匹配原语冒烟测试 —— 用共享 golden 钉死校验器内联的 allowToRegex/
 * urlCoveredByAllow/scopePrefix，使其与 broker 两端（server url-match.ts / client
 * url_match.dart）行为一致。
 *
 *   contract/golden/broker/url-match.json  →  {urlCoveredByAllow, scopePrefix}  →  逐例等于 expected
 *
 * 校验器是 manifest 的**静态闸门**（C4/C6/C7 用同一匹配约定决定 scope ⊆ allow 等）；
 * broker 是**运行时**注入决策。二者历史上各持一份内联实现——本测试把校验器那份纳入
 * 同一 golden 闭环，任一处正则/转义漂移即 CI 红（关闭"manifest 过校验、运行时行为不同"的缝）。
 * 校验器无运行时 url-vs-scope 匹配（scopeMatches 由 broker 独有），故跳过该节。
 *
 *   运行：cd tools && npm run smoke:urlmatch
 *
 * 🔒 覆盖红线 #1 注入决策匹配约定；与被测代码一并须人工 + 安全清单复核。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { urlCoveredByAllow, scopePrefix } from "./index.js";

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
    assert.strictEqual(
      scopePrefix(c.pattern),
      c.expected,
      `scopePrefix '${c.name}': pattern=${c.pattern}`,
    );
    passed++;
  }

  const total = g.urlCoveredByAllow.length + g.scopePrefix.length;
  assert.ok(total > 0, "golden 向量为空");
  console.log(`validator url-match smoke: ${passed}/${total} 例通过 ✅（与 broker 共享 golden）`);
}

main();
