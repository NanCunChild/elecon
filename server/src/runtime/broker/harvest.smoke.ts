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
import { CredentialStore } from "../credential/store.js";
import { CookieJar, type JarCookie } from "./cookie-jar.js";
import { decideHarvest, decideQueryHarvest, type HarvestPlan, harvestInto } from "./harvest.js";
import type { BrokerManifestView } from "./inject-policy.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const goldenPath = `${repoRoot}contract/golden/broker/harvest.json`;

interface GoldenCase {
  name: string;
  /** nowMs 缺省 0：无 expiresAt 的旧向量不受过期判据影响（P1-06 新增例显式给值）。 */
  input: { originCookies: JarCookie[]; view: BrokerManifestView; nowMs?: number };
  expected: HarvestPlan;
}

interface QueryGoldenCase {
  name: string;
  input: { url: string; view: BrokerManifestView };
  expected: HarvestPlan;
}

function goldenTests(): number {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as {
    cases: GoldenCase[];
    queryCases: QueryGoldenCase[];
  };
  assert.ok(golden.cases.length > 0, "golden 向量为空");
  for (const c of golden.cases) {
    const actual = decideHarvest(c.input.originCookies, c.input.view, c.input.nowMs ?? 0);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `case '${c.name}'\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
  }

  // query 收割（ADR-020 §2.3）：同一 golden 文件的 queryCases 驱动 decideQueryHarvest，
  // 与 Dart 端逐字节双跑（此前两端各写手写断言，会漂移）。
  assert.ok(golden.queryCases.length > 0, "query golden 向量为空");
  for (const c of golden.queryCases) {
    const actual = decideQueryHarvest(c.input.url, c.input.view);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `query case '${c.name}'\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
  }
  return golden.cases.length + golden.queryCases.length;
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
  const plan = decideHarvest(cookies, view, clock);
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
  harvestInto(decideHarvest(rotated, view, clock), view, store, { schoolId: "xjt", now: () => clock });
  const after = await store.get("sess");
  assert.equal(after?.value, "JSESSIONID=S2");
  checks++;

  // 空计划不写库
  const emptyStore = new CredentialStore(undefined, () => clock);
  const noCred: BrokerManifestView = { allow: ["https://ids.xjtu.edu.cn/*"], credentials: {} };
  harvestInto(decideHarvest(cookies, noCred, clock), noCred, emptyStore, {
    schoolId: "xjt",
    now: () => clock,
  });
  assert.equal(emptyStore.list().length, 0, "无声明 ref → 不收割");
  checks++;

  // Set-Cookie parser → harvest：无 Domain 的 host-only cookie 不得被子域 credential scope 收割。
  const subdomainView: BrokerManifestView = {
    allow: ["https://sub.ids.xjtu.edu.cn/*"],
    credentials: { sub: { scope: ["https://sub.ids.xjtu.edu.cn/*"], type: "cookie" } },
  };
  const parsedJar = new CookieJar();
  parsedJar.captureSetCookie(["SID=HOST_ONLY; Path=/"], "https://ids.xjtu.edu.cn/login");
  assert.deepStrictEqual(
    decideHarvest([...parsedJar.harvestView()], subdomainView, clock),
    [],
    "parser 产生的 host-only 标记必须阻止子域收割",
  );
  checks++;

  // query credential 决策已由 golden queryCases 双跑覆盖；此处只验收割 → 入库 → get 序列化。
  const queryView: BrokerManifestView = {
    allow: ["https://card.xidian.edu.cn/*"],
    credentials: {
      card: {
        scope: ["https://card.xidian.edu.cn/*"],
        type: "query",
        queryParam: "openid",
      },
    },
  };
  harvestInto(
    decideQueryHarvest("https://card.xidian.edu.cn/home?openid=opaque", queryView),
    queryView,
    store,
    { schoolId: "xidian", now: () => clock },
  );
  const card = await store.get("card");
  assert.equal(card?.via, "query");
  assert.equal(card?.value, "opaque");
  checks++;

  return checks;
}

async function main(): Promise<void> {
  const g = goldenTests();
  const i = await integrationTests();
  console.log(`broker B5 harvest smoke: golden ${g}/${g} + 集成 ${i}/${i} 例通过 ✅`);
}

runMain(main);
