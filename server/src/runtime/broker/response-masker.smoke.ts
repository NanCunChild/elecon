/**
 * 响应凭证收割与投影引擎 golden 冒烟（ADR-026 §2.8 / 工程说明 §6）。
 *
 *   contract/golden/broker/response-masker.json  →  broker/response-masker.ts 纯函数  →  逐例等于 expected
 *
 * 同一份 golden 由客户端（Dart，broker_response_masker_test.dart）照样跑（两端双跑，ADR-001 §8）。
 * 覆盖 4 段：captureHeader / captureJson（收割 + fail-closed）/ project（投影 + 实体头清理）/
 * transaction（Capture→Project 原子性）。
 *
 *   运行：cd server && npm run smoke:masker
 *
 * 🔒 本测试覆盖红线 #1 凭证路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { resolveRepoRoot } from "../__testutils__/smoke-utils.js";
import {
  applyResponseMasker,
  captureHeader,
  captureJson,
  MaskerError,
  type MaskerRawResponse,
  type MaskerRule,
  projectResponse,
} from "./response-masker.js";

interface CaptureCase {
  name: string;
  headerName?: string;
  path?: string;
  response: MaskerRawResponse;
  expected?: string;
  error?: string;
  errorKey?: string;
}
interface ProjectCase {
  name: string;
  rules: MaskerRule[];
  response: MaskerRawResponse;
  expected: MaskerRawResponse;
}
interface TransactionCase {
  name: string;
  rules: MaskerRule[];
  response: MaskerRawResponse;
  error?: string;
  expected?: {
    captured: Array<{ ruleId: string; ref: string; value: string }>;
    projected: MaskerRawResponse;
  };
}
interface GeneratedLimitCase {
  name: string;
  kind: "header" | "body" | "captureValue" | "scanBudget";
  unit?: string;
  repeat?: number;
  entries?: number;
  rules?: number;
  error: string;
}
interface GoldenFile {
  generatedLimits: GeneratedLimitCase[];
  captureHeader: CaptureCase[];
  captureJson: CaptureCase[];
  project: ProjectCase[];
  transaction: TransactionCase[];
}

const repoRoot = resolveRepoRoot(import.meta.url);
const golden = JSON.parse(
  readFileSync(`${repoRoot}contract/golden/broker/response-masker.json`, "utf8"),
) as GoldenFile;

/** 断言 [fn] 抛出 MaskerError 且 code 匹配；给了 expectedKey 时还校验结构化 detail.key（B5）。 */
function expectError(fn: () => unknown, code: string, label: string, expectedKey?: string): void {
  try {
    fn();
    assert.fail(`${label}：期望 fail-closed（${code}），但未抛错`);
  } catch (err) {
    if (!(err instanceof MaskerError)) throw err;
    assert.equal(err.code, code, `${label}：错误码不符`);
    if (expectedKey !== undefined) {
      assert.equal(err.detail?.key, expectedKey, `${label}：重复键结构化 key 不符`);
    }
  }
}

let passed = 0;

for (const c of golden.generatedLimits) {
  if (c.kind === "header") {
    const value = (c.unit ?? "").repeat(c.repeat ?? 0);
    expectError(
      () => captureHeader("X-Limit", { status: 200, headers: { "X-Limit": value }, body: "" }),
      c.error,
      c.name,
    );
  } else if (c.kind === "body") {
    const body = (c.unit ?? "").repeat(c.repeat ?? 0) + "{}";
    expectError(() => captureJson("$", { status: 200, headers: {}, body }), c.error, c.name);
  } else if (c.kind === "captureValue") {
    const value = (c.unit ?? "").repeat(c.repeat ?? 0);
    const body = JSON.stringify({ token: value });
    expectError(() => captureJson("$.token", { status: 200, headers: {}, body }), c.error, c.name);
  } else {
    const entries: string[] = [];
    for (let k = 0; k < (c.entries ?? 0); k++) entries.push(`"k${k}":"v${k}"`);
    const rules: MaskerRule[] = [];
    for (let k = 0; k < (c.rules ?? 0); k++) {
      rules.push({
        id: `r${k}`,
        capture: { source: "json", path: `$.k${k}`, destination: { kind: "redact" } },
        project: "replace",
      });
    }
    expectError(
      () =>
        applyResponseMasker(rules, {
          status: 200,
          headers: { "content-type": "application/json" },
          body: `{${entries.join(",")}}`,
        }),
      c.error,
      c.name,
    );
  }
  passed++;
  console.log(`  ✓ generatedLimits/${c.name}`);
}

for (const c of golden.captureHeader) {
  if (c.error !== undefined) {
    expectError(() => captureHeader(c.headerName ?? "", c.response), c.error, c.name);
  } else {
    assert.equal(captureHeader(c.headerName ?? "", c.response), c.expected, c.name);
  }
  passed++;
  console.log(`  ✓ captureHeader/${c.name}`);
}

for (const c of golden.captureJson) {
  if (c.error !== undefined) {
    expectError(() => captureJson(c.path ?? "", c.response), c.error, c.name, c.errorKey);
  } else {
    assert.equal(captureJson(c.path ?? "", c.response), c.expected, c.name);
  }
  passed++;
  console.log(`  ✓ captureJson/${c.name}`);
}

for (const c of golden.project) {
  const actual = projectResponse(c.rules, c.response);
  assert.deepEqual(actual, c.expected, c.name);
  passed++;
  console.log(`  ✓ project/${c.name}`);
}

for (const c of golden.transaction) {
  if (c.error !== undefined) {
    expectError(() => applyResponseMasker(c.rules, c.response), c.error, c.name);
  } else {
    const actual = applyResponseMasker(c.rules, c.response);
    assert.deepEqual(actual.captured, c.expected?.captured, `${c.name}: captured`);
    assert.deepEqual(actual.projected, c.expected?.projected, `${c.name}: projected`);
  }
  passed++;
  console.log(`  ✓ transaction/${c.name}`);
}

console.log(`response-masker engine smoke: ${passed} cases passed`);
