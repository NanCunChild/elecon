/**
 * adapter 服务端执行沙箱 —— QuickJS-wasm（quickjs-emscripten）。
 *
 * 为什么是 QuickJS-wasm 而不是 Node 的 `vm`：
 *   - Node 的 `vm` **不是安全边界**，半可信/侧载 adapter 在里面等于裸奔。
 *   - QuickJS-wasm 同时给到真正的沙箱与纯 JS/wasm 无 cgo；客户端使用另一套
 *     QuickJS 绑定，已使用语义的一致性由共享 golden/canary 约束（ADR-008 §3.2）。
 * 详见 docs/adr/adr_005_runtime.md。
 *
 * 分派（ADR-022）：调用方按被执行 capability 的 `requestGraph` 选择入口——
 *   - `declarative` → [runDeclarativeAdapter]（同步纯解析，无 ctx.fetch）
 *   - `imperative`  → [runImperativeAdapter]（ctx.fetch 自编排；入场前信任闸门）
 * 本模块不读完整 manifest；不在入口间根据 mode 自动切换。
 */

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  getQuickJS,
  type QuickJSContext,
  type QuickJSHandle,
  type QuickJSRuntime,
  Scope,
  shouldInterruptAfterDeadline,
} from "quickjs-emscripten";
import type { RequestInit as BrokerRequestInit } from "./broker/assemble.js";
import { CookieJar } from "./broker/cookie-jar.js";
import {
  BrokerFetchRejected,
  type FetchProxyOutcome,
  proxyFetch,
  type Transport,
  TransportBodyLimitExceeded,
} from "./broker/fetch-proxy.js";
import { decideHarvest, type HarvestSink, harvestInto } from "./broker/harvest.js";
import type { BrokerManifestView } from "./broker/inject-policy.js";
import type { MaskerCommitContext, MaskerCommitSink } from "./broker/masker-commit.js";
import type { CredentialResolver } from "./broker/ports.js";
import type { MaskerRule } from "./broker/response-masker.js";
import {
  isThenable,
  isThenableHandle,
  jsonToHandle,
  marshal,
  SandboxError,
  unwrap,
  withTimeout,
} from "./sandbox-qjs-util.js";
import {
  fetchTrustPermitted,
  isTrustedAdapterContext,
  type TrustedAdapterContext,
} from "./trusted-context.js";

export { SandboxError, type SandboxFailureReason } from "./sandbox-qjs-util.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const HTML_STDLIB_SOURCE = readFileSync(
  resolve(__dirname, "../../../adapters/_stdlib/html.bundle.js"),
  "utf-8",
);
const FETCH_RESPONSE_SHIM_SOURCE = readFileSync(resolve(__dirname, "./fetch-response-shim.js"), "utf-8");

export interface SandboxLimits {
  /** 单次执行墙钟超时（毫秒） */
  timeoutMs: number;
  /** wasm 线性内存上限（字节） */
  memoryBytes: number;
}

/**
 * 解析限额环境变量：仅接受 (0, max] 的有限数；非法或越界回退默认并告警。
 * 限额保护 QuickJS 执行/内存/网络放大，是安全承重——不得被未校验的环境配置静默放宽。
 */
function envLimit(name: string, fallback: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0 || n > max) {
    console.warn(`[sandbox] 忽略非法限额 ${name}=${raw}（需 0 < n ≤ ${max}），回退默认 ${fallback}`);
    return fallback;
  }
  return Math.floor(n);
}

export const DEFAULT_LIMITS: SandboxLimits = {
  timeoutMs: envLimit("SANDBOX_TIMEOUT_MS", 5_000, 60_000),
  memoryBytes: envLimit("SANDBOX_MEMORY_BYTES", 64 * 1024 * 1024, 512 * 1024 * 1024),
};

export type LogLevel = "debug" | "info" | "warn" | "error";

/**
 * 双入口共用输入。调用方按 capability.requestGraph 选择
 * [runDeclarativeAdapter] / [runImperativeAdapter]（本结构不携带 requestGraph 字段）。
 */
export interface AdapterRunInput {
  source: string;
  capability: string;
  params: unknown;
  /** declarative 路径：宿主代取后的脱敏响应 map */
  responses?: Record<string, { status: number; headers: Record<string, string>; body: string }>;
  nowMs?: number;
  onLog?: (level: LogLevel, message: string) => void;
}

export interface AdapterRunResult {
  data: unknown;
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared helpers
// ═══════════════════════════════════════════════════════════════════════════

interface RuntimeContext {
  runtime: QuickJSRuntime;
  ctx: QuickJSContext;
  deadline: number;
}

/** Shared QuickJS-wasm initialization for both declarative and imperative paths. */
async function createRuntime(limits: SandboxLimits): Promise<RuntimeContext> {
  const QuickJS = await getQuickJS();
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(limits.memoryBytes);

  const deadline = Date.now() + limits.timeoutMs;
  runtime.setInterruptHandler(shouldInterruptAfterDeadline(deadline));
  runtime.setModuleLoader((moduleName) => {
    if (moduleName === "elecon:html") return HTML_STDLIB_SOURCE;
    throw new Error(`Module not found: ${moduleName}`);
  });

  const ctx = runtime.newContext();
  return { runtime, ctx, deadline };
}

// ═══════════════════════════════════════════════════════════════════════════
// Declarative requestGraph（同步纯解析；无 ctx.fetch）
// ═══════════════════════════════════════════════════════════════════════════

/** declarative capability：宿主已代取 → 同步 handler(ctx, params, responses)。 */
export async function runDeclarativeAdapter(
  input: AdapterRunInput,
  limits: SandboxLimits = DEFAULT_LIMITS,
): Promise<AdapterRunResult> {
  const { runtime, ctx, deadline } = await createRuntime(limits);
  try {
    return Scope.withScope((scope): AdapterRunResult => {
      const nsHandle = scope.manage(
        unwrap(ctx, ctx.evalCode(input.source, "adapter.js", { type: "module" }), deadline),
      );
      runtime.executePendingJobs();

      const capsHandle = scope.manage(ctx.getProp(nsHandle, "capabilities"));
      if (ctx.typeof(capsHandle) !== "object") {
        throw new SandboxError("bad_export", "adapter 未导出 'capabilities' 对象");
      }
      const handlerHandle = scope.manage(ctx.getProp(capsHandle, input.capability));
      if (ctx.typeof(handlerHandle) !== "function") {
        throw new SandboxError("capability_missing", `capability '${input.capability}' 不在 adapter 内`);
      }

      const ctxArg = buildDeclarativeCtx(ctx, scope, input);
      const paramsArg = marshal(ctx, scope, input.params ?? null);
      const responsesArg = marshal(ctx, scope, input.responses ?? {});

      const retHandle = scope.manage(
        unwrap(
          ctx,
          ctx.callFunction(handlerHandle, ctx.undefined, ctxArg, paramsArg, responsesArg),
          deadline,
        ),
      );
      runtime.executePendingJobs();

      if (isThenable(ctx, scope, retHandle)) {
        throw new SandboxError(
          "async_in_declarative",
          "declarative capability 返回了 Promise；declarative 模式必须同步（无 I/O）",
        );
      }

      return { data: ctx.dump(retHandle) };
    });
  } finally {
    ctx.dispose();
    runtime.dispose();
  }
}

function buildDeclarativeCtx(ctx: QuickJSContext, scope: Scope, input: AdapterRunInput): QuickJSHandle {
  const obj = scope.manage(ctx.newObject());
  const logFn = scope.manage(
    ctx.newFunction("log", (levelH, msgH) => {
      const level = levelH && ctx.typeof(levelH) === "string" ? (ctx.getString(levelH) as LogLevel) : "info";
      const message = msgH && ctx.typeof(msgH) === "string" ? ctx.getString(msgH) : "";
      input.onLog?.(level, message);
    }),
  );
  ctx.setProp(obj, "log", logFn);
  const nowMs = input.nowMs ?? Date.now();
  const nowFn = scope.manage(ctx.newFunction("now", () => ctx.newNumber(nowMs)));
  ctx.setProp(obj, "now", nowFn);
  return obj;
}

// ═══════════════════════════════════════════════════════════════════════════
// Imperative requestGraph（ctx.fetch 自编排；入场前信任闸门）
// ═══════════════════════════════════════════════════════════════════════════

export interface FetchLimits {
  perRequestTimeoutMs: number;
  totalNetworkMs: number;
  maxRequests: number;
  maxHopsPerRequest: number;
}

export const DEFAULT_FETCH_LIMITS: FetchLimits = {
  perRequestTimeoutMs: envLimit("FETCH_PER_REQUEST_TIMEOUT_MS", 10_000, 60_000),
  totalNetworkMs: envLimit("FETCH_TOTAL_NETWORK_MS", 30_000, 300_000),
  maxRequests: envLimit("FETCH_MAX_REQUESTS", 20, 100),
  maxHopsPerRequest: envLimit("FETCH_MAX_HOPS_PER_REQUEST", 5, 20),
};

export interface ImperativeAdapterDeps {
  /**
   * 信任裁定凭据（ADR-002 §2.6 · #79 P0-1）：必填，只能经核心裁定路径构造
   * （`TrustedAdapterContext`，见 trusted-context.ts）。入口在触达引擎/host-fn
   * 之前校验档位 × 环境 + instanceof（防字面量伪造），不满足即 fail-closed。
   */
  trust: TrustedAdapterContext;
  view: BrokerManifestView;
  resolver: CredentialResolver;
  transport: Transport;
  harvest?: { sink: HarvestSink; schoolId: string };
  /**
   * ⑦ Response Masker 交付策略（C1 firewall，ADR-026）。每次 `ctx.fetch` 交回 adapter 的响应
   * 强制经 firewall；此处提供命中规则 + 落库目标。**seam（人工主导）**：`rules` 由签名
   * `masker.json` 的 match 块按响应解析选出（本层不含匹配逻辑）、`sink`/`ctx` 接真实 Store。
   * 缺省 = 无策略：仍经 firewall（空规则 no-op），无旁路。🔒 装配须人工、不得 AI 独自闭环。
   */
  masker?: { rules: readonly MaskerRule[]; sink: MaskerCommitSink; ctx: MaskerCommitContext };
}

/** imperative 执行内状态。 */
interface ImperativeExecState {
  jar: CookieJar;
  requestCount: number;
  networkMs: number;
  fatal: SandboxError | null;
  nowMs: number;
  abortControllers: Set<AbortController>;
  bridgeSettlements: Set<Promise<void>>;
}

function abortInFlight(state: ImperativeExecState): void {
  for (const controller of state.abortControllers) {
    controller.abort();
  }
  state.abortControllers.clear();
}

/**
 * Bridge a host-side Promise into the QuickJS VM as a deferred promise.
 * Safely handles rejection and disposal so that errors in the `.then`
 * callbacks do not become unhandled promise rejections.
 */
function bridgeHostPromise(
  ctx: QuickJSContext,
  hostPromise: Promise<QuickJSHandle>,
  runtime: QuickJSRuntime,
  settlements: Set<Promise<void>>,
): QuickJSHandle {
  const deferred = ctx.newPromise();
  hostPromise.then(
    (respHandle) => {
      try {
        deferred.resolve(respHandle);
      } catch {
        /* already settled */
      }
      respHandle.dispose();
    },
    (err: unknown) => {
      const msg = err instanceof Error ? err.message : String(err);
      try {
        const errH = ctx.newString(msg);
        deferred.reject(errH);
        errH.dispose();
      } catch {
        /* ctx may be disposed; best effort */
      }
    },
  );
  const settlement = deferred.settled.then(() => {
    try {
      runtime.executePendingJobs();
    } catch {
      /* runtime may already be disposed (e.g. timeout during in-flight fetch) */
    }
  });
  settlements.add(settlement);
  void settlement.then(
    () => settlements.delete(settlement),
    () => settlements.delete(settlement),
  );
  return deferred.handle;
}

/**
 * Create the per-execution imperative ctx object (log, now, fetch, setEphemeralCookie).
 */
function buildImperativeCtx(
  ctx: QuickJSContext,
  runtime: QuickJSRuntime,
  deps: ImperativeAdapterDeps,
  input: AdapterRunInput,
  state: ImperativeExecState,
  fetchLimits: FetchLimits,
  deadline: number,
  disposables: QuickJSHandle[],
): QuickJSHandle {
  const track = (h: QuickJSHandle): QuickJSHandle => {
    disposables.push(h);
    return h;
  };

  const ctxObj = track(ctx.newObject());

  // log
  const logFn = ctx.newFunction("log", (levelH, msgH) => {
    const level = levelH && ctx.typeof(levelH) === "string" ? (ctx.getString(levelH) as LogLevel) : "info";
    const message = msgH && ctx.typeof(msgH) === "string" ? ctx.getString(msgH) : "";
    input.onLog?.(level, message);
  });
  ctx.setProp(ctxObj, "log", logFn);
  logFn.dispose();

  // now
  const nowFn = ctx.newFunction("now", () => ctx.newNumber(state.nowMs));
  ctx.setProp(ctxObj, "now", nowFn);
  nowFn.dispose();

  // Restricted ctx.fetch
  const fetchFn = ctx.newFunction("fetch", (urlH, initH) => {
    const url = ctx.typeof(urlH) === "string" ? ctx.getString(urlH) : "";
    const init: BrokerRequestInit =
      initH && ctx.typeof(initH) === "object" ? (ctx.dump(initH) as BrokerRequestInit) : {};

    const hostPromise: Promise<QuickJSHandle> = (async () => {
      if (state.fatal) throw state.fatal;
      const start = Date.now();
      const controller = new AbortController();
      state.abortControllers.add(controller);
      let outcome: FetchProxyOutcome;
      try {
        outcome = await withTimeout(
          proxyFetch(url, init, {
            view: deps.view,
            resolver: deps.resolver,
            jar: state.jar,
            transport: deps.transport,
            maxHops: fetchLimits.maxHopsPerRequest,
            signal: controller.signal,
            reserveRequest: () => {
              if (state.fatal) throw state.fatal;
              if (state.requestCount >= fetchLimits.maxRequests) {
                state.fatal = new SandboxError(
                  "fetch_limit",
                  `单次执行请求数超限（>${fetchLimits.maxRequests}）`,
                );
                abortInFlight(state);
                throw state.fatal;
              }
              state.requestCount++;
            },
            ...(deps.harvest
              ? {
                  queryHarvest: {
                    view: deps.view,
                    sink: deps.harvest.sink,
                    schoolId: deps.harvest.schoolId,
                    now: () => state.nowMs,
                  },
                }
              : {}),
            ...(deps.masker ? { masker: deps.masker } : {}),
          }),
          fetchLimits.perRequestTimeoutMs,
          () => {
            // 单请求超时同为硬终止：置 fatal，adapter catch 也无法把执行洗成成功（镜像 Dart 侧）
            state.fatal = new SandboxError(
              "fetch_limit",
              `单请求超时（>${fetchLimits.perRequestTimeoutMs}ms）`,
            );
            abortInFlight(state);
            return state.fatal;
          },
        );
      } catch (err) {
        if (err instanceof TransportBodyLimitExceeded) {
          state.fatal = new SandboxError("fetch_limit", err.message);
          abortInFlight(state);
          throw state.fatal;
        }
        throw err;
      } finally {
        state.abortControllers.delete(controller);
      }
      state.networkMs += Date.now() - start;
      if (state.networkMs > fetchLimits.totalNetworkMs) {
        state.fatal = new SandboxError("fetch_limit", `累计网络耗时超限（>${fetchLimits.totalNetworkMs}ms）`);
        abortInFlight(state);
        throw state.fatal;
      }
      const payload: Record<string, unknown> = { status: outcome.status, headers: outcome.headers };
      if (outcome.body !== undefined) payload.body = outcome.body;
      return jsonToHandle(ctx, payload);
    })();

    return bridgeHostPromise(ctx, hostPromise, runtime, state.bridgeSettlements);
  });

  // wrap raw fetch into Response-like interface for adapter ergonomics
  // shim 源码见 ./fetch-response-shim.js（契约面：adapter 依赖其 Response shape）。
  const wrapFactory = track(
    unwrap(ctx, ctx.evalCode(FETCH_RESPONSE_SHIM_SOURCE, "fetch-response-shim.js"), deadline),
  );
  const wrappedFetch = track(unwrap(ctx, ctx.callFunction(wrapFactory, ctx.undefined, fetchFn), deadline));
  ctx.setProp(ctxObj, "fetch", wrappedFetch);
  fetchFn.dispose();

  // ctx.setEphemeralCookie
  const setEphFn = ctx.newFunction("setEphemeralCookie", (nameH, valueH, optsH) => {
    const name = ctx.typeof(nameH) === "string" ? ctx.getString(nameH) : "";
    const value = ctx.typeof(valueH) === "string" ? ctx.getString(valueH) : "";
    const opts =
      optsH && ctx.typeof(optsH) === "object"
        ? (ctx.dump(optsH) as { domain: string; path?: string })
        : { domain: "" };
    const writeInput =
      opts.path !== undefined
        ? { name, value, domain: opts.domain, path: opts.path }
        : { name, value, domain: opts.domain };
    state.jar.writeEphemeral(writeInput, deps.view, (m) => input.onLog?.("warn", m));
  });
  ctx.setProp(ctxObj, "setEphemeralCookie", setEphFn);
  setEphFn.dispose();

  return ctxObj;
}

/**
 * Evaluate the adapter module, locate the capability handler, invoke it,
 * and await the result (async handler support).
 */
async function invokeImperativeHandler(
  ctx: QuickJSContext,
  runtime: QuickJSRuntime,
  input: AdapterRunInput,
  ctxObj: QuickJSHandle,
  deadline: number,
  state: ImperativeExecState,
  disposables: QuickJSHandle[],
): Promise<unknown> {
  const track = (h: QuickJSHandle): QuickJSHandle => {
    disposables.push(h);
    return h;
  };

  const nsHandle = track(unwrap(ctx, ctx.evalCode(input.source, "adapter.js", { type: "module" }), deadline));
  runtime.executePendingJobs();

  const capsHandle = track(ctx.getProp(nsHandle, "capabilities"));
  if (ctx.typeof(capsHandle) !== "object") {
    throw new SandboxError("bad_export", "adapter 未导出 'capabilities' 对象");
  }
  const handlerHandle = track(ctx.getProp(capsHandle, input.capability));
  if (ctx.typeof(handlerHandle) !== "function") {
    throw new SandboxError("capability_missing", `capability '${input.capability}' 不在 adapter 内`);
  }

  const paramsArg = track(jsonToHandle(ctx, input.params ?? null));
  const retHandle = track(
    unwrap(ctx, ctx.callFunction(handlerHandle, ctx.undefined, ctxObj, paramsArg), deadline),
  );
  runtime.executePendingJobs();

  let dataHandle: QuickJSHandle;
  if (isThenableHandle(ctx, retHandle)) {
    const settledResult = await withTimeout(
      ctx.resolvePromise(retHandle),
      Math.max(0, deadline - Date.now()),
      () => {
        state.fatal = new SandboxError("timeout", "imperative handler 未在墙钟内完成");
        abortInFlight(state);
        return state.fatal;
      },
    );
    runtime.executePendingJobs();
    if (state.fatal) {
      // fatal 抛出前须先释放 settle 结果，否则 runtime.dispose 触发 QuickJS gc_obj_list 断言
      if ("value" in settledResult) settledResult.value.dispose();
      else settledResult.error.dispose();
      throw state.fatal;
    }
    dataHandle = track(unwrap(ctx, settledResult, deadline));
  } else {
    if (state.fatal) throw state.fatal;
    dataHandle = retHandle;
  }

  return ctx.dump(dataHandle);
}

/**
 * imperative capability：ctx.fetch 自编排。入场前 fail-closed 信任闸门
 * （ADR-002 §2.6；非 official 永不触达凭证注入）。
 */
export async function runImperativeAdapter(
  input: AdapterRunInput,
  deps: ImperativeAdapterDeps,
  limits: SandboxLimits = DEFAULT_LIMITS,
  fetchLimits: FetchLimits = DEFAULT_FETCH_LIMITS,
): Promise<AdapterRunResult> {
  // 信任闸门：在触达引擎、注册任何 host function 之前 fail-closed（ADR-002 §2.6）。
  // 签发登记校验防运行时伪造（cast / 直接 new / Object.create，见 trusted-context.ts）；
  // production 硬接 NODE_ENV——不提供注入点。
  if (!isTrustedAdapterContext(deps.trust)) {
    throw new SandboxError(
      "trust_rejected",
      "trust 不是核心签发的 TrustedAdapterContext 实例（伪造/误接线，fail-closed）",
    );
  }
  if (!fetchTrustPermitted(deps.trust.tier, { production: process.env.NODE_ENV === "production" })) {
    throw new SandboxError(
      "trust_rejected",
      `非 official adapter 无 imperative（ctx.fetch）权限（档位 ${deps.trust.tier}，生产环境）——ADR-002 §2.6 结构化权限错误，凭证注入路径不可达`,
    );
  }

  const { runtime, ctx, deadline } = await createRuntime(limits);

  const state: ImperativeExecState = {
    jar: new CookieJar(),
    requestCount: 0,
    networkMs: 0,
    fatal: null,
    nowMs: input.nowMs ?? Date.now(),
    abortControllers: new Set(),
    bridgeSettlements: new Set(),
  };
  const disposables: QuickJSHandle[] = [];

  try {
    const ctxObj = buildImperativeCtx(ctx, runtime, deps, input, state, fetchLimits, deadline, disposables);
    const data = await invokeImperativeHandler(ctx, runtime, input, ctxObj, deadline, state, disposables);

    if (deps.harvest) {
      const plan = decideHarvest([...state.jar.harvestView()], deps.view);
      harvestInto(plan, deps.view, deps.harvest.sink, {
        schoolId: deps.harvest.schoolId,
        now: () => state.nowMs,
      });
    }

    return { data };
  } catch (err) {
    if (err instanceof BrokerFetchRejected) {
      throw new SandboxError("adapter_threw", err.message);
    }
    throw err;
  } finally {
    abortInFlight(state);
    // 并发 fatal 后，已创建的 QuickJS deferred 仍须完成 settle，再释放 runtime。
    // 否则未决 Promise 会触发 QuickJS gc_obj_list 断言；预算已在 transport 前封死，不会新增出网。
    await Promise.allSettled([...state.bridgeSettlements]);
    for (const h of disposables) {
      try {
        h.dispose();
      } catch {
        /* already freed */
      }
    }
    ctx.dispose();
    runtime.dispose();
  }
}
