/**
 * Masker 策略装配冒烟（parse + select），照 `contract/golden/broker/masker-policy.json` 与 Dart 双跑。
 *
 *   运行：cd server && npx tsx src/runtime/broker/masker-policy.smoke.ts
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  type MaskerPolicy,
  MaskerPolicyError,
  parseMaskerPolicy,
  selectMaskerRules,
} from "./masker-policy.js";

interface ParseCase {
  name: string;
  text: string;
  ok: boolean;
  ruleCount?: number;
  error?: string;
}
interface SelectCase {
  name: string;
  context: { capability: string; method: string; finalUrl: string; requestKey?: string };
  expectedRuleIds: string[];
}
interface Golden {
  parseErrorCodes: string[];
  parse: ParseCase[];
  selectPolicy: MaskerPolicy;
  select: SelectCase[];
}

const goldenPath = fileURLToPath(
  new URL("../../../../contract/golden/broker/masker-policy.json", import.meta.url),
);
const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as Golden;

let n = 0;
for (const c of golden.parse) {
  if (c.ok) {
    const policy = parseMaskerPolicy(c.text);
    assert.equal(policy.rules.length, c.ruleCount, `${c.name}: ruleCount`);
  } else {
    assert.throws(
      () => parseMaskerPolicy(c.text),
      (e: unknown) => e instanceof MaskerPolicyError && e.code === c.error,
      `${c.name}: 应以 ${c.error} 拒`,
    );
    assert.ok(golden.parseErrorCodes.includes(c.error ?? ""), `${c.name}: 错误码须在 golden 词表内`);
  }
  n++;
  console.log(`  ✓ parse/${c.name}`);
}

// select 的策略先经 parse 往返，保证 golden 策略本身合法。
const policy = parseMaskerPolicy(JSON.stringify(golden.selectPolicy));
for (const c of golden.select) {
  const ids = selectMaskerRules(policy, c.context).map((r) => r.id);
  assert.deepEqual(
    ids,
    c.expectedRuleIds,
    `${c.name}: 选出 ${ids.join(",")} ≠ 期望 ${c.expectedRuleIds.join(",")}`,
  );
  n++;
  console.log(`  ✓ select/${c.name}`);
}

// 选出的规则不携带 match（纯引擎只吃 id/capture/project）。
{
  const picked = selectMaskerRules(policy, {
    capability: "notice.list",
    method: "GET",
    finalUrl: "https://api.example.edu/notices/1",
  });
  assert.ok(picked.length > 0);
  assert.ok(!("match" in picked[0]!), "引擎规则不含 match");
  n++;
}

console.log(`masker-policy smoke: ${n} cases passed`);
