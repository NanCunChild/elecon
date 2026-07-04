/**
 * 凭证存储冒烟测试 —— 模型往返 + 生命周期 + 与 B1 broker 的集成。
 *
 *   put → get(值)；不存在/过期/吊销 → null；登出 delete → 抹除
 *   decideInjection(inject, ref) → store.get(ref) → 值；store/manifest 注入方式漂移可检出
 *
 *   运行：cd server && npm run smoke:credential
 *
 * 🔒 覆盖红线 #1 凭证存储路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 * ⚠️ 夹具值为显式假值（红线 #8）：绝不使用真实学生凭证。
 */

import { strict as assert } from "node:assert";

import { decideInjection, type BrokerManifestView } from "../broker/inject-policy.js";
import { CredentialStore } from "./store.js";
import { InMemorySecureStore } from "./secure-store.js";
import { runMain } from "../__testutils__/smoke-utils.js";
import type { CredentialEntry } from "./types.js";

const FAKE_VALUE = "TEST-SESSION-not-a-real-credential";

function entry(over: Partial<CredentialEntry>): CredentialEntry {
  return {
    ref: "session",
    schoolId: "test",
    type: "cookie",
    scope: ["https://h.edu.cn/api/*"],
    value: FAKE_VALUE,
    acquiredAt: 1_000,
    expiresAt: null,
    status: "active",
    ...over,
  };
}

async function run(): Promise<void> {
  let now = 10_000;
  const store = new CredentialStore(undefined, () => now);

  // 往返：put → get 取到值（via = store type）
  store.put(entry({}));
  assert.deepStrictEqual(await store.get("session"), { via: "cookie", value: FAKE_VALUE });

  // 不存在 → null
  assert.equal(await store.get("nope"), null, "未知 ref 返回 null");

  // 过期（expiresAt 已过）→ null
  store.put(entry({ ref: "exp", expiresAt: 9_000 }));
  assert.equal(await store.get("exp"), null, "过期凭证不可解析");

  // 吊销 → null（即便未到 expiresAt）
  store.put(entry({ ref: "rev", status: "revoked", expiresAt: null }));
  assert.equal(await store.get("rev"), null, "吊销凭证不可解析");

  // 登出 = 抹除：delete 后 get → null
  store.delete("session");
  assert.equal(await store.get("session"), null, "登出后凭证已抹除");

  // —— 与 B1 broker 集成：inject 决策 → 解析凭证值 ——
  store.put(entry({}));
  const view: BrokerManifestView = {
    allow: ["https://h.edu.cn/api/*"],
    credentials: { session: { scope: ["https://h.edu.cn/api/*"], type: "cookie" } },
  };
  const decision = decideInjection("https://h.edu.cn/api/grades", view);
  assert.equal(decision.kind, "inject", "url 命中 scope 应判 inject");
  if (decision.kind === "inject") {
    const resolved = await store.get(decision.ref);
    assert.ok(resolved, "inject 决策应能解析到凭证值");
    // ADR-012 §2.4：manifest via（注入权威）应与 store type（防御性副本）一致
    assert.equal(decision.via, resolved.via, "manifest via 与 store type 一致");
  }

  // §2.4 漂移检测：store.type 与 manifest via 冲突 → 须能检出（实际注入以 manifest 为准 + 告警）
  store.put(entry({ ref: "drift", type: "header" }));
  const driftView: BrokerManifestView = {
    allow: ["https://h.edu.cn/api/*"],
    credentials: { drift: { scope: ["https://h.edu.cn/api/*"], type: "cookie" } },
  };
  const driftDecision = decideInjection("https://h.edu.cn/api/x", driftView);
  assert.equal(driftDecision.kind, "inject");
  if (driftDecision.kind === "inject") {
    const r = await store.get(driftDecision.ref);
    assert.ok(r);
    const mismatch = r.via !== driftDecision.via; // 注入权威 = manifest（driftDecision.via=cookie）
    assert.equal(mismatch, true, "应检出 store/manifest 注入方式漂移（store=header vs manifest=cookie）");
  }

  // 过期后续期：put 覆盖同 ref → 重新可解析（§2.3 续期写回的退化形态）
  store.put(entry({ ref: "exp", expiresAt: now + 5_000 }));
  assert.ok(await store.get("exp"), "续期写回后凭证重新可解析");
  now += 6_000;
  assert.equal(await store.get("exp"), null, "时间推进越过新 expiresAt 后再次失效");

  // #79 P0-2：生产环境下省略 store 的默认构造须 fail-closed（不静默用明文内存后端）。
  const prevEnv = process.env.NODE_ENV;
  process.env.NODE_ENV = "production";
  try {
    assert.throws(
      () => new CredentialStore(),
      /InMemorySecureStore|fail-closed|生产/,
      "生产下缺省 store 的构造须抛错（不得静默回退明文内存）",
    );
    // 显式注入后端在生产下仍合法（真实 secure store 落地后走此路径）
    assert.doesNotThrow(
      () => new CredentialStore(new InMemorySecureStore()),
      "显式注入 store 时不应抛（注入责任在调用方）",
    );
  } finally {
    if (prevEnv === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = prevEnv;
  }

  console.log("credential store smoke: 全部通过 ✅");
}

runMain(run);
