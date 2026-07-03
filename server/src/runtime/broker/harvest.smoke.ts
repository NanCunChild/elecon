/**
 * Broker B5 收割桥接冒烟测试 —— golden 驱动 decideHarvest + 与 CredentialStore 集成。
 *
 *   contract/golden/broker/harvest.json  →  decideHarvest  →  逐例等于 expected
 *   harvestInto + CredentialStore          →  收割后 get(ref) 取到序列化值（可供 B6 注入）
 *
 *   运行：cd server && npm run smoke:harvest
 *
 * 🔒 红线 #1 承重路径（凭证入核心库）：与被测代码一并须人工 + 安全清单复核
 * （不得 AI 独自闭环，AGENTS.md §1）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { resolveRepoRoot, runMain } from "../__testutils__/smoke-utils.js";

import { decideHarvest, harvestInto, type HarvestPlan } from "./harvest.js";
import type { JarCookie } from "./cookie-jar.js";
import type { BrokerManifestView } from "./inject-policy.js";
import { CredentialStore } from "../credential/store.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const goldenPath = `${repoRoot}contract/golden/broker/harvest.json`;

interface GoldenCase {
  name: string;
  input: { originCookies: JarCookie[]; view: BrokerManifestView };
  expected: HarvestPlan;
}

function goldenTests(): number {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as { cases: GoldenCase[] };
  assert.ok(golden.cases.length > 0, "golden 向量为空");
  for (const c of golden.cases) {
    const actual = decideHarvest(c.input.originCookies, c.input.view);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `case '${c.name}'\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
  }
  return golden.cases.length;
}

async function integrationTests(): Promise<number> {
  let checks = 0;
  const view: BrokerManifestView = {
    allow: ["https://ids.xjtu.edu.cn/*"],
    credentials: { sess: { scope: ["https://ids.xjtu.edu.cn/*"], type: "cookie" } },
  };
  const cookies: JarCookie[] = [
    { name: "JSESSIONID", value: "S1", domain: "ids.xjtu.edu.cn", path: "/", source: "origin" },
    { name: "CASTGC", value: "C1", domain: "ids.xjtu.edu.cn", path: "/", source: "origin" },
  ];

  // 收割 → 入库 → get 取到序列化值（B6 注入即用此值）
  let clock = 5000;
  const store = new CredentialStore(undefined, () => clock);
  const plan = decideHarvest(cookies, view);
  harvestInto(plan, view, store, { schoolId: "xjt", now: () => clock });

  const resolved = await store.get("sess");
  assert.ok(resolved !== null, "收割后应能 get 到");
  assert.equal(resolved.via, "cookie");
  assert.equal(resolved.value, "CASTGC=C1; JSESSIONID=S1");
  checks++;

  // 注入权威以 manifest 为准：store 记录的 scope 是防御性副本
  const entry = store.list().find((e) => e.ref === "sess");
  assert.ok(entry, "条目应存在");
  assert.deepStrictEqual(entry.scope, ["https://ids.xjtu.edu.cn/*"]);
  assert.equal(entry.schoolId, "xjt");
  assert.equal(entry.expiresAt, null); // session 语义（见 harvest.ts 文件头）
  checks++;

  // 会话轮换：同 ref 再收割覆盖旧值
  const rotated: JarCookie[] = [
    { name: "JSESSIONID", value: "S2", domain: "ids.xjtu.edu.cn", path: "/", source: "origin" },
  ];
  clock = 6000;
  harvestInto(decideHarvest(rotated, view), view, store, { schoolId: "xjt", now: () => clock });
  const after = await store.get("sess");
  assert.equal(after?.value, "JSESSIONID=S2");
  checks++;

  // 空计划不写库
  const emptyStore = new CredentialStore(undefined, () => clock);
  const noCred: BrokerManifestView = { allow: ["https://ids.xjtu.edu.cn/*"], credentials: {} };
  harvestInto(decideHarvest(cookies, noCred), noCred, emptyStore, { schoolId: "xjt", now: () => clock });
  assert.equal(emptyStore.list().length, 0, "无声明 ref → 不收割");
  checks++;

  return checks;
}

async function main(): Promise<void> {
  const g = goldenTests();
  const i = await integrationTests();
  console.log(`broker B5 harvest smoke: golden ${g}/${g} + 集成 ${i}/${i} 例通过 ✅`);
}

runMain(main);
