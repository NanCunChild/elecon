/**
 * 统一交付 firewall 冒烟（checklist C1 骨架 + C0 源响应投影用例）。
 *
 *   deliverThroughFirewall  —— 单 choke point：A3 → Capture/Validate/Project → Commit →
 *                              header 脱敏；任一步 fail-closed，绝不交付原响应。
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
import { MaskerError, type MaskerRule } from "./response-masker.js";

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
    const raw = {
      status: 200,
      headers: { "content-type": "application/json", "set-cookie": "s=1", "content-length": "40" },
      body: '{"token":"TOK_FICTITIOUS_abc","device":"d1"}',
    };
    const outcome = deliverThroughFirewall({
      raw,
      transportDecodeOk: true,
      rules: [CREDENTIAL_RULE],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    // 源响应投影：交付 body 里原 token 不复存在、被 sentinel 取代，业务字段保留。
    assert.ok(!outcome.response.body!.includes("TOK_FICTITIOUS_abc"), "源 token 不得出现在交付 body");
    assert.ok(raw.body.includes("TOK_FICTITIOUS_abc"), "firewall 不应原地改写传输层原响应对象");
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

  // ② 编码后的二进制文本仍按敏感原值处理：收割精确保真，交付边界只见 sentinel。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const encodedRule: MaskerRule = {
      id: "r-encoded-material",
      capture: {
        source: "json",
        path: "$.encodedMaterial",
        destination: { kind: "credential", ref: "aircon-session" },
      },
      project: "replace",
    };
    const outcome = deliverThroughFirewall({
      raw: {
        status: 200,
        headers: { "content-type": "application/json" },
        body: '{"encodedMaterial":"AP8Q","kind":"base64-fixture"}',
      },
      transportDecodeOk: true,
      rules: [encodedRule],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    assert.equal(outcome.response.body, `{"encodedMaterial":"${SENTINEL}","kind":"base64-fixture"}`);
    assert.equal((await store.get("aircon-session"))?.value, "AP8Q", "编码文本须逐字节保真落库");
    passed++;
    console.log("  ✓ 编码二进制文本：核心收割原值，adapter-visible 原响应仅见 sentinel");
  }

  // ③ header 源同样先 Capture/Project，再进入响应 allowlist 交付。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const headerRule: MaskerRule = {
      id: "r-header-token",
      capture: {
        source: "header",
        name: "x-session-secret",
        destination: { kind: "credential", ref: "aircon-session" },
      },
      project: "delete",
    };
    const outcome = deliverThroughFirewall({
      raw: {
        status: 200,
        headers: { "content-type": "text/plain", "X-Session-Secret": "HEADER_FIXTURE_SECRET" },
        body: "business payload",
      },
      transportDecodeOk: true,
      // P1-04：传输层证明了基数（无重复名），header 源规则方可执行。
      headerCardinalityAttested: true,
      rules: [headerRule],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    assert.equal(outcome.response.headers["X-Session-Secret"], undefined, "敏感源 header 不得交付");
    assert.equal((await store.get("aircon-session"))?.value, "HEADER_FIXTURE_SECRET");
    passed++;
    console.log("  ✓ header 源响应边界：敏感头删除后交付，原值仅落核心 store");
  }

  // ④ A3：传输层未解码明文 → fail-closed，绝不交付、绝不落库。
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

  // ⑤ selector miss：允许交付、不提交，并逐字段保留既有 credential。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const existing = {
      ref: "aircon-session",
      schoolId: "juhaolian-demo",
      type: "header" as const,
      scope: ["https://gxkt.juhaolian.cn/*"],
      value: "OLD_FIXTURE_SECRET",
      acquiredAt: 1_600_000_000_000,
      expiresAt: 1_800_000_000_000,
      status: "active" as const,
    };
    store.put(existing);
    const missingRule: MaskerRule = {
      id: "r-missing",
      capture: { source: "json", path: "$.nope", destination: { kind: "credential", ref: "aircon-session" } },
      project: "replace",
    };
    const raw = { status: 200, headers: { "content-type": "application/json" }, body: '{"business":"ok"}' };
    const outcome = deliverThroughFirewall({
      raw,
      transportDecodeOk: true,
      rules: [missingRule],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    assert.equal(outcome.committedCount, 0, "selector miss 不得提交 credential");
    assert.equal(outcome.response.body, raw.body, "selector miss 应交付未投影的业务响应");
    assert.deepEqual(store.list(), [existing], "selector miss 后旧 credential 的值、状态与时间戳须全部保持");
    passed++;
    console.log("  ✓ selector miss：正常交付、commit=0、旧 credential 逐字段保持");
  }

  // ⑥ 无策略命中：响应仍经 choke point 交付（header 脱敏生效），committedCount=0。
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

  // ⑦ P1-04：传输层不能证明原始基数 → header 源规则拒交付（json 源不受影响）。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const headerRule: MaskerRule = {
      id: "r-header-token",
      capture: {
        source: "header",
        name: "x-session-secret",
        destination: { kind: "credential", ref: "aircon-session" },
      },
      project: "delete",
    };
    const raw = {
      status: 200,
      headers: { "content-type": "text/plain", "X-Session-Secret": "HEADER_FIXTURE_SECRET" },
      body: "business payload",
    };
    assert.throws(
      () =>
        deliverThroughFirewall({
          raw,
          transportDecodeOk: true,
          // 缺省即「不可证明」：绝不把折叠后的 "a, b" 当单值凭证收割。
          rules: [headerRule],
          view: AIRCON_VIEW,
          sink: store,
          ctx,
        }),
      (e: unknown) => e instanceof DeliveryFirewallError && e.code === "header_cardinality_unattested",
      "基数不可证明时 header 源规则须 fail-closed",
    );
    assert.ok(!(await store.get("aircon-session")), "拒交付时绝不落库");
    // 同一响应下 json 源规则不受基数门影响（门只约束 header 源）。
    const jsonOutcome = deliverThroughFirewall({
      raw: { status: 200, headers: { "content-type": "application/json" }, body: '{"t":"J"}' },
      transportDecodeOk: true,
      rules: [
        {
          id: "r-json",
          capture: { source: "json", path: "$.t", destination: { kind: "redact" } },
          project: "replace",
        },
      ],
      view: AIRCON_VIEW,
      sink: store,
      ctx,
    });
    assert.ok(jsonOutcome.response.body?.includes("__ELECON_MASKED__"), "json 源规则不受基数门影响");
    passed++;
    console.log("  ✓ P1-04：基数不可证明 → header 源规则 fail-closed（不交付/不落库），json 源不受影响");
  }

  // ⑧ P1-04：传输层证明了「线上出现两次」→ 纯引擎 capture_ambiguous fail-closed。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const headerRule: MaskerRule = {
      id: "r-header-token",
      capture: {
        source: "header",
        name: "x-session-secret",
        destination: { kind: "credential", ref: "aircon-session" },
      },
      project: "delete",
    };
    assert.throws(
      () =>
        deliverThroughFirewall({
          raw: {
            status: 200,
            // 折叠视图只有一个 key，但传输层记下了它在线上出现两次。
            headers: { "content-type": "text/plain", "X-Session-Secret": "A, B" },
            body: "business payload",
            repeatedHeaders: ["x-session-secret"],
          },
          transportDecodeOk: true,
          headerCardinalityAttested: true,
          rules: [headerRule],
          view: AIRCON_VIEW,
          sink: store,
          ctx,
        }),
      (e: unknown) => e instanceof MaskerError && e.code === "capture_ambiguous",
      "两个同名 token 头须 capture_ambiguous fail-closed",
    );
    assert.ok(!(await store.get("aircon-session")), "歧义时绝不落库");
    passed++;
    console.log("  ✓ P1-04：两个同名 token 头（折叠前基数=2）→ capture_ambiguous fail-closed");
  }

  console.log(`统一交付 firewall 骨架 smoke: ${passed} 组通过 ✅`);
}

runMain(main);
