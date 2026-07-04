/**
 * fetch 模式运行时冒烟测试（Gate A · B6b）—— 证明 ctx.fetch 端到端跑通（fake transport 驱动）。
 *
 *   adapter（async handler）→ ctx.fetch → proxyFetch（B6a）→ FakeTransport
 *     ├─ broker 注入凭证出站 / 响应脱敏交回 adapter
 *     ├─ 多步握手 + setEphemeralCookie 跨步携带（XJT body-token 缺口）
 *     ├─ fail-closed：allow 外 ctx.fetch 被拒（adapter 可 catch）
 *     ├─ 限额硬执行：单次 ≤N 请求超限 → fetch_limit，且 fail 不收割
 *     └─ 执行结束 B5 收割：声明的耐久 cookie 入 CredentialStore
 *
 * 运行时触 QuickJS 引擎、不可纯 golden 化（计划 §2），用 fake transport 驱动集成。
 *
 *   运行：cd server && npm run smoke:fetch
 *
 * 🔒 红线 #1 凭证注入 + 出网承重路径：与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";

import { runFetchAdapter, SandboxError, type FetchAdapterDeps } from "./sandbox.js";
import type { CredentialResolver, ResolvedCredential } from "./broker/ports.js";
import type { Transport, TransportRequest, TransportResponse } from "./broker/fetch-proxy.js";
import type { BrokerManifestView } from "./broker/inject-policy.js";
import { CredentialStore } from "./credential/store.js";
import { TrustedAdapterContext, fetchTrustPermitted } from "./trusted-context.js";
import {
  FakeResolver,
  FakeTransport,
  resp,
  runMain,
} from "./__testutils__/smoke-utils.js";

const NOW = 1_700_000_000_000;

/** 1. inject 端到端 + 响应脱敏交回 adapter + 执行结束 B5 收割。 */
async function testInjectAndHarvest(): Promise<void> {
  const view: BrokerManifestView = {
    allow: ["https://h.edu.cn/api/*"],
    credentials: { session: { scope: ["https://h.edu.cn/api/*"], type: "cookie" } },
  };
  const transport = new FakeTransport([
    resp({
      status: 200,
      headers: { "Content-Type": "application/json", "Set-Cookie": "JSESSIONID=ROT" },
      setCookie: ["JSESSIONID=ROT"],
      body: '[{"id":1,"t":"hi"}]',
    }),
  ]);
  const store = new CredentialStore(undefined, () => NOW);
  const source = `
    export const capabilities = {
      'notice.list': async (ctx) => {
        const res = await ctx.fetch('https://h.edu.cn/api/list');
        return { items: await res.json(), gotHeaders: res.headers };
      }
    };`;

  const deps: FetchAdapterDeps = {
    trust: TrustedAdapterContext.devSideload(),
    view,
    resolver: new FakeResolver({ session: { via: "cookie", value: "JSESSIONID=S1" } }),
    transport,
    harvest: { sink: store, schoolId: "xidian" },
  };
  const { data } = await runFetchAdapter({ source, capability: "notice.list", params: {}, nowMs: NOW }, deps);

  const d = data as { items: unknown; gotHeaders: Record<string, string> };
  assert.deepEqual(d.items, [{ id: 1, t: "hi" }], "产出 items 不符");
  assert.equal(transport.seen[0]!.headers["Cookie"], "JSESSIONID=S1", "broker 注入 cookie 应出站");
  assert.equal(d.gotHeaders["Set-Cookie"], undefined, "Set-Cookie 不得回交 adapter");
  // 执行结束收割：origin Set-Cookie 的声明 ref 入库（会话轮换值 ROT）
  const harvested = await store.get("session");
  assert.ok(harvested && harvested.value === "JSESSIONID=ROT", "声明 ref 应被收割入库");
  console.log("  ✓ inject 出站 + 响应脱敏 + B5 收割");
}

/** 2. 多步握手 + setEphemeralCookie 跨步携带（passthrough origin，XJT body-token 缺口）。 */
async function testEphemeralMultiStep(): Promise<void> {
  const view: BrokerManifestView = { allow: ["https://dean.xjtu.edu.cn/*"] };
  const transport = new FakeTransport([
    resp({ status: 200, body: '{"client_id":"XYZ"}' }),
    resp({ status: 200, body: "[1,2,3]" }),
  ]);
  const source = `
    export const capabilities = {
      'notice.list': async (ctx) => {
        const a = await ctx.fetch('https://dean.xjtu.edu.cn/challenge');
        const cid = (await a.json()).client_id;
        ctx.setEphemeralCookie('client_id', cid, { domain: 'dean.xjtu.edu.cn' });
        const b = await ctx.fetch('https://dean.xjtu.edu.cn/list');
        return { rows: await b.json() };
      }
    };`;
  const deps: FetchAdapterDeps = { trust: TrustedAdapterContext.devSideload(), view, resolver: new FakeResolver({}), transport };
  const { data } = await runFetchAdapter({ source, capability: "notice.list", params: {}, nowMs: NOW }, deps);

  assert.deepEqual((data as { rows: unknown }).rows, [1, 2, 3], "第二步产出不符");
  assert.equal(transport.seen[1]!.headers["Cookie"], "client_id=XYZ", "ephemeral cookie 应在第二步携带");
  console.log("  ✓ 多步握手 + ephemeral 跨步携带");
}

/** 3. fail-closed：allow 外 ctx.fetch 被拒，adapter 可 catch；不发任何请求。 */
async function testFailClosedCatchable(): Promise<void> {
  const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
  const transport = new FakeTransport([]);
  const source = `
    export const capabilities = {
      'notice.list': async (ctx) => {
        try { await ctx.fetch('https://evil.com/x'); return { reached: true }; }
        catch (e) { return { blocked: true }; }
      }
    };`;
  const deps: FetchAdapterDeps = { trust: TrustedAdapterContext.devSideload(), view, resolver: new FakeResolver({}), transport };
  const { data } = await runFetchAdapter({ source, capability: "notice.list", params: {}, nowMs: NOW }, deps);

  assert.deepEqual(data, { blocked: true }, "allow 外应被拒、adapter 可 catch");
  assert.equal(transport.seen.length, 0, "fail-closed 不得发任何请求");
  console.log("  ✓ fail-closed（allow 外被拒，可 catch，零出网）");
}

/** 4. 限额：单次执行请求数超限 → fetch_limit 终止，且 fail 不收割。 */
async function testRequestLimitNoHarvest(): Promise<void> {
  const view: BrokerManifestView = {
    allow: ["https://h.edu.cn/api/*"],
    credentials: { session: { scope: ["https://h.edu.cn/api/*"], type: "cookie" } },
  };
  const transport = new FakeTransport([
    resp({ status: 200, setCookie: ["JSESSIONID=A"], body: "{}" }),
    resp({ status: 200, setCookie: ["JSESSIONID=B"], body: "{}" }),
  ]);
  const store = new CredentialStore(undefined, () => NOW);
  // adapter 不 catch：第二个 fetch 触发超限，限额须压过 adapter 错误
  const source = `
    export const capabilities = {
      'notice.list': async (ctx) => {
        await ctx.fetch('https://h.edu.cn/api/a');
        await ctx.fetch('https://h.edu.cn/api/b');
        return { ok: true };
      }
    };`;
  const deps: FetchAdapterDeps = {
    trust: TrustedAdapterContext.devSideload(),
    view,
    resolver: new FakeResolver({ session: { via: "cookie", value: "S" } }),
    transport,
    harvest: { sink: store, schoolId: "xidian" },
  };
  await assert.rejects(
    runFetchAdapter({ source, capability: "notice.list", params: {}, nowMs: NOW }, deps, undefined, {
      perRequestTimeoutMs: 10_000,
      totalNetworkMs: 30_000,
      maxRequests: 1,
      maxHopsPerRequest: 5,
    }),
    (e: unknown) => e instanceof SandboxError && e.reason === "fetch_limit",
    "超请求数应抛 fetch_limit",
  );
  assert.equal(store.list().length, 0, "失败执行不得收割（fail 不收割）");
  console.log("  ✓ 请求数限额硬执行 + fail 不收割");
}

/** 5. 限额：单请求超时是硬终止——adapter catch 后返回"成功"也压不过 fetch_limit，且 fail 不收割。 */
async function testPerRequestTimeoutNotSwallowable(): Promise<void> {
  const view: BrokerManifestView = {
    allow: ["https://h.edu.cn/api/*"],
    credentials: { session: { scope: ["https://h.edu.cn/api/*"], type: "cookie" } },
  };
  // transport 延迟 50ms >> perRequestTimeoutMs=1ms → 必然单请求超时
  const transport: Transport = {
    fetch: () =>
      new Promise<TransportResponse>((res) => {
        setTimeout(() => res(resp({ status: 200, setCookie: ["JSESSIONID=A"], body: "{}" })), 50);
      }),
  };
  const store = new CredentialStore(undefined, () => NOW);
  const source = `
    export const capabilities = {
      'notice.list': async (ctx) => {
        try { await ctx.fetch('https://h.edu.cn/api/slow'); return { caught: false }; }
        catch (e) { return { caught: true }; }
      }
    };`;
  const deps: FetchAdapterDeps = {
    trust: TrustedAdapterContext.devSideload(),
    view,
    resolver: new FakeResolver({ session: { via: "cookie", value: "JSESSIONID=S" } }),
    transport,
    harvest: { sink: store, schoolId: "xidian" },
  };
  await assert.rejects(
    runFetchAdapter({ source, capability: "notice.list", params: {}, nowMs: NOW }, deps, undefined, {
      perRequestTimeoutMs: 1,
      totalNetworkMs: 30_000,
      maxRequests: 20,
      maxHopsPerRequest: 5,
    }),
    (e: unknown) => e instanceof SandboxError && e.reason === "fetch_limit",
    "单请求超时须抛 fetch_limit，即便 adapter catch 后返回成功",
  );
  assert.equal(store.list().length, 0, "失败执行不得收割（fail 不收割）");
  console.log("  ✓ 单请求超时硬终止（adapter catch 不可绕过）+ fail 不收割");
}

/** 6. 信任闸门（ADR-002 §2.6 · #79 P0-1）：伪造/越权 trust 在触达引擎前被拒，零出网。 */
async function testTrustGate(): Promise<void> {
  const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
  const transport = new FakeTransport([resp({ status: 200, body: "[]" })]);
  const source = `
    export const capabilities = {
      'notice.list': async (ctx) => { await ctx.fetch('https://h.edu.cn/x'); return {}; }
    };`;

  // 6a. 字面量伪造 trust（结构化类型 cast 绕过私有构造器）→ instanceof 拦截
  const forged = { tier: "official" } as unknown as TrustedAdapterContext;
  await assert.rejects(
    runFetchAdapter(
      { source, capability: "notice.list", params: {}, nowMs: NOW },
      { trust: forged, view, resolver: new FakeResolver({}), transport },
    ),
    (e: unknown) => e instanceof SandboxError && e.reason === "trust_rejected",
    "伪造 trust 对象应被 instanceof 校验拒绝",
  );
  assert.equal(transport.seen.length, 0, "trust 拒绝须发生在任何出网之前");

  // 6b. 入场判定负例：生产环境下 dev_sideload 拒绝、official 放行（纯函数）
  assert.equal(fetchTrustPermitted("dev_sideload", { production: true }), false, "生产下侧载须拒");
  assert.equal(fetchTrustPermitted("official", { production: true }), true, "生产下 official 放行");
  assert.equal(fetchTrustPermitted("dev_sideload", { production: false }), true, "非生产侧载放行（§2.5）");

  // 6c. 生产环境下 devSideload() 构造即抛（fail-closed）
  const prevEnv = process.env.NODE_ENV;
  process.env.NODE_ENV = "production";
  try {
    assert.throws(() => TrustedAdapterContext.devSideload(), "生产下 dev 侧载上下文不可构造");
  } finally {
    if (prevEnv === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = prevEnv;
  }
  console.log("  ✓ 信任闸门（伪造拒绝 + 生产 fail-closed + 零出网）");
}

async function main(): Promise<void> {
  console.log("fetch-runtime smoke:");
  await testInjectAndHarvest();
  await testEphemeralMultiStep();
  await testFailClosedCatchable();
  await testRequestLimitNoHarvest();
  await testPerRequestTimeoutNotSwallowable();
  await testTrustGate();
  console.log("全部通过。fetch 模式运行时端到端跑通。");
}

runMain(main);
