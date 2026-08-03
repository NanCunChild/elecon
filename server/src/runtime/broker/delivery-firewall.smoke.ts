/**
 * 统一交付 firewall 冒烟（checklist C1 骨架 + C0 源响应投影用例）。
 *
 *   deliverThroughFirewall  —— 单 choke point：A3 → Capture/Validate/Project → Commit →
 *                              回显剥离 → header 脱敏；任一步 fail-closed，绝不交付原响应。
 *
 *   运行：cd server && npm run smoke:delivery-firewall
 *
 * 🔒 红线 #1 承重路径 + 不可绕过边界：与被测代码一并须人工 + 安全清单复核
 * （不得 AI 独自闭环，AGENTS.md §1）。
 */

import { strict as assert } from "node:assert";
import { runMain } from "../__testutils__/smoke-utils.js";
import { CredentialStore } from "../credential/store.js";
import { DeliveryFirewallError, deliverThroughFirewall } from "./delivery-firewall.js";
import type { BrokerManifestView } from "./inject-policy.js";
import type { MaskerRule } from "./response-masker.js";

const SENTINEL = "__ELECON_MASKED__";

const AIRCON_VIEW: BrokerManifestView = {
  allow: ["https://gxkt.juhaolian.cn/*"],
  credentials: {
    "aircon-session": {
      scope: ["https://gxkt.juhaolian.cn/*"],
      type: "header",
      headerName: "x-access-token",
    },
  },
};

const ctx = { schoolId: "juhaolian-demo", now: () => 1_700_000_000_000 };

const CREDENTIAL_RULE: MaskerRule = {
  id: "r-aircon",
  capture: { source: "json", path: "$.token", destination: { kind: "credential", ref: "aircon-session" } },
  project: "replace",
};

async function main(): Promise<void> {
  let passed = 0;

  // ① C0 源响应投影 + 闭环：源 body 里的 token 被投影为 sentinel 后才交付；同一 token 落库。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const outcome = deliverThroughFirewall({
      raw: {
        status: 200,
        headers: { "content-type": "application/json", "set-cookie": "s=1", "content-length": "40" },
        body: '{"token":"TOK_FICTITIOUS_abc","device":"d1"}',
      },
      transportDecodeOk: true,
      rules: [CREDENTIAL_RULE],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    // 源响应投影：交付 body 里原 token 不复存在、被 sentinel 取代，业务字段保留。
    assert.ok(!outcome.response.body!.includes("TOK_FICTITIOUS_abc"), "源 token 不得出现在交付 body");
    assert.ok(outcome.response.body!.includes(SENTINEL), "命中值应被投影为 sentinel");
    assert.ok(outcome.response.body!.includes('"device":"d1"'), "业务字段应保留");
    // header 脱敏：Set-Cookie 剥除、Content-Type 保留、失真实体头（Content-Length）剥除。
    assert.equal(outcome.response.headers["set-cookie"], undefined, "Set-Cookie 应剥除");
    assert.equal(outcome.response.headers["content-type"], "application/json", "Content-Type 应保留");
    assert.equal(outcome.response.headers["content-length"], undefined, "改写后 Content-Length 应剥除");
    assert.equal(outcome.committedCount, 1, "应提交 1 个持久 credential");
    // 闭环：落库值 = 源 token（供命名头注入）。
    const resolved = await store.get("aircon-session");
    assert.ok(resolved !== null && resolved.value === "TOK_FICTITIOUS_abc", "落库值应等于源 token");
    assert.equal(resolved!.via, "header", "via 应为 header");
    passed++;
    console.log("  ✓ C0 源响应投影 + 闭环：源值投影为 sentinel 后交付，同值落库（via=header）");
  }

  // ② A3：传输层未解码明文 → fail-closed，绝不交付、绝不落库。
  {
    const store = new CredentialStore(undefined, ctx.now);
    assert.throws(
      () =>
        deliverThroughFirewall({
          raw: { status: 200, headers: {}, body: "��" },
          transportDecodeOk: false,
          rules: [CREDENTIAL_RULE],
          view: AIRCON_VIEW,
          sink: store,
          ctx,
        }),
      (e: unknown) => e instanceof DeliveryFirewallError && e.code === "body_not_plaintext",
      "A3：非明文应 body_not_plaintext fail-closed",
    );
    assert.equal(store.list().length, 0, "A3 失败不得落库");
    passed++;
    console.log("  ✓ A3：transportDecodeOk=false → body_not_plaintext fail-closed（不交付/不落库）");
  }

  // ③ 交付事务 fail-closed：capture 未命中 → 抛、不半提交、不交付原响应。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const badRule: MaskerRule = {
      id: "r-missing",
      capture: { source: "json", path: "$.nope", destination: { kind: "credential", ref: "aircon-session" } },
      project: "replace",
    };
    assert.throws(
      () =>
        deliverThroughFirewall({
          raw: { status: 200, headers: { "content-type": "application/json" }, body: '{"token":"x"}' },
          transportDecodeOk: true,
          rules: [badRule],
          view: AIRCON_VIEW,
          sink: store,
          ctx,
        }),
      "capture 未命中应整体 fail-closed（抛错）",
    );
    assert.equal(store.list().length, 0, "capture 失败不得半提交");
    passed++;
    console.log("  ✓ 交付事务 fail-closed：capture 未命中 → 抛错、不半提交、不交付原响应");
  }

  // ④ 无策略命中：响应仍经 choke point 交付（header 脱敏生效），committedCount=0。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const outcome = deliverThroughFirewall({
      raw: {
        status: 200,
        headers: { "content-type": "text/plain", "set-cookie": "s=1", authorization: "Bearer x" },
        body: "plain business data",
      },
      transportDecodeOk: true,
      rules: [],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    assert.equal(outcome.response.body, "plain business data", "无策略时 body 原样");
    assert.equal(outcome.response.headers["set-cookie"], undefined, "Set-Cookie 仍剥除（choke point 生效）");
    assert.equal(outcome.response.headers["authorization"], undefined, "Authorization 回显仍剥除");
    assert.equal(outcome.committedCount, 0, "无策略不提交凭证");
    passed++;
    console.log("  ✓ 无策略命中：仍经 choke point 交付（header 脱敏生效），committedCount=0");
  }

  // ⑤ dataflow 回显剥离：下游注入值在交付 body 里被掩码。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const outcome = deliverThroughFirewall({
      raw: {
        status: 200,
        headers: { "content-type": "text/plain" },
        body: "echo of INJECTED_NONCE_42 here",
      },
      transportDecodeOk: true,
      rules: [],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
      injectedValues: ["INJECTED_NONCE_42"],
    });
    assert.ok(!outcome.response.body!.includes("INJECTED_NONCE_42"), "注入值回显应被剥离");
    assert.ok(outcome.response.body!.includes("[stripped]"), "回显应替换为掩码");
    passed++;
    console.log("  ✓ dataflow 回显剥离：下游注入值在交付 body 被掩码");
  }

  console.log(`统一交付 firewall 骨架 smoke: ${passed} 组通过 ✅`);
}

runMain(main);
