/**
 * adapter 服务端执行沙箱 —— QuickJS-wasm（quickjs-emscripten）。
 *
 * 为什么是 QuickJS-wasm 而不是 Node 的 `vm`：
 *   - Node 的 `vm` **不是安全边界**，半可信/侧载 adapter 在里面等于裸奔。
 *   - QuickJS-wasm 同时给到：真正的沙箱、与客户端**同一个引擎**（零语义漂移）、
 *     纯 JS/wasm 无 cgo。
 * 详见 docs/adr/adr_005_runtime.md。
 */

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  getQuickJS,
  Scope,
  shouldInterruptAfterDeadline,
  type QuickJSContext,
  type QuickJSHandle,
  type QuickJSRuntime,
} from "quickjs-emscripten";

import { CookieJar } from "./broker/cookie-jar.js";
import { decideHarvest, harvestInto, type HarvestSink } from "./broker/harvest.js";
import type { BrokerManifestView } from "./broker/inject-policy.js";
import type { CredentialResolver } from "./broker/ports.js";
import {
  proxyFetch,
  BrokerFetchRejected,
  TransportBodyLimitExceeded,
  type Transport,
  type FetchProxyOutcome,
} from "./broker/fetch-proxy.js";
import type { RequestInit as BrokerRequestInit } from "./broker/assemble.js";

import {
  SandboxError,
  unwrap,
  errorMessage,
  marshal,
  isThenable,
  jsonToHandle,
  isThenableHandle,
  withTimeout,
} from "./sandbox-qjs-util.js";
export { SandboxError, type SandboxFailureReason } from "./sandbox-qjs-util.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const HTML_STDLIB_SOURCE = readFileSync(
  resolve(__dirname, "../../../adapters/_stdlib/html.bundle.js"),
  "utf-8",
);
const FETCH_RESPONSE_SHIM_SOURCE = readFileSync(
  resolve(__dirname, "./fetch-response-shim.js"),
  "utf-8",
);

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

export interface AdapterRunInput {
  source: string;
  capability: string;
  params: unknown;
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

/** Shared QuickJS-wasm initialization for both parser and fetch modes. */
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
// Parser mode
// ═══════════════════════════════════════════════════════════════════════════

export async function runAdapter(
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
        throw new SandboxError(
          "capability_missing",
          `capability '${input.capability}' 不在 adapter 内`,
        );
      }

      const ctxArg = buildParserCtx(ctx, scope, input);
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
          "async_in_parser",
          "parser capability 返回了 Promise；parser 模式必须同步（无 I/O）",
        );
      }

      return { data: ctx.dump(retHandle) };
    });
  } finally {
    ctx.dispose();
    runtime.dispose();
  }
}

function buildParserCtx(ctx: QuickJSContext, scope: Scope, input: AdapterRunInput): QuickJSHandle {
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
// Fetch mode
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

export interface FetchAdapterDeps {
  view: BrokerManifestView;
  resolver: CredentialResolver;
  transport: Transport;
  harvest?: { sink: HarvestSink; schoolId: string };
}

/** fetch 模式执行内状态。 */
interface FetchExecState {
  jar: CookieJar;
  requestCount: number;
  networkMs: number;
  fatal: SandboxError | null;
  nowMs: number;
  abortControllers: Set<AbortController>;
}

function abortInFlight(state: FetchExecState): void {
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
): QuickJSHandle {
  const deferred = ctx.newPromise();
  hostPromise.then(
    (respHandle) => {
      try { deferred.resolve(respHandle); } catch { /* already settled */ }
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
  deferred.settled.then(() => {
    try {
      runtime.executePendingJobs();
    } catch {
      /* runtime may already be disposed (e.g. timeout during in-flight fetch) */
    }
  });
  return deferred.handle;
}

/**
 * Create the per-execution fetch-mode ctx object (log, now, fetch, setEphemeralCookie).
 */
function buildFetchCtx(
  ctx: QuickJSContext,
  runtime: QuickJSRuntime,
  deps: FetchAdapterDeps,
  input: AdapterRunInput,
  state: FetchExecState,
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
      if (state.requestCount >= fetchLimits.maxRequests) {
        state.fatal = new SandboxError("fetch_limit", `单次执行请求数超限（>${fetchLimits.maxRequests}）`);
        abortInFlight(state);
        throw state.fatal;
      }
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
          }),
          fetchLimits.perRequestTimeoutMs,
          () => {
            // 单请求超时同为硬终止：置 fatal，adapter catch 也无法把执行洗成成功（镜像 Dart 侧）
            state.fatal = new SandboxError("fetch_limit", `单请求超时（>${fetchLimits.perRequestTimeoutMs}ms）`);
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
      state.requestCount += outcome.requestCount;
      if (state.networkMs > fetchLimits.totalNetworkMs) {
        state.fatal = new SandboxError("fetch_limit", `累计网络耗时超限（>${fetchLimits.totalNetworkMs}ms）`);
        abortInFlight(state);
        throw state.fatal;
      }
      if (state.requestCount > fetchLimits.maxRequests) {
        state.fatal = new SandboxError("fetch_limit", `单次执行请求数超限（>${fetchLimits.maxRequests}）`);
        abortInFlight(state);
        throw state.fatal;
      }
      const payload: Record<string, unknown> = { status: outcome.status, headers: outcome.headers };
      if (outcome.body !== undefined) payload.body = outcome.body;
      return jsonToHandle(ctx, payload);
    })();

    return bridgeHostPromise(ctx, hostPromise, runtime);
  });

  // wrap raw fetch into Response-like interface for adapter ergonomics
  // shim 源码见 ./fetch-response-shim.js（契约面：adapter 依赖其 Response shape）。
  const wrapFactory = track(
    unwrap(
      ctx,
      ctx.evalCode(FETCH_RESPONSE_SHIM_SOURCE, "fetch-response-shim.js"),
      deadline,
    ),
  );
  const wrappedFetch = track(
    unwrap(ctx, ctx.callFunction(wrapFactory, ctx.undefined, fetchFn), deadline),
  );
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
async function invokeFetchHandler(
  ctx: QuickJSContext,
  runtime: QuickJSRuntime,
  input: AdapterRunInput,
  ctxObj: QuickJSHandle,
  deadline: number,
  state: FetchExecState,
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
        state.fatal = new SandboxError("timeout", "fetch handler 未在墙钟内完成");
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

export async function runFetchAdapter(
  input: AdapterRunInput,
  deps: FetchAdapterDeps,
  limits: SandboxLimits = DEFAULT_LIMITS,
  fetchLimits: FetchLimits = DEFAULT_FETCH_LIMITS,
): Promise<AdapterRunResult> {
  const { runtime, ctx, deadline } = await createRuntime(limits);

  const state: FetchExecState = {
    jar: new CookieJar(),
    requestCount: 0,
    networkMs: 0,
    fatal: null,
    nowMs: input.nowMs ?? Date.now(),
    abortControllers: new Set(),
  };
  const disposables: QuickJSHandle[] = [];

  try {
    const ctxObj = buildFetchCtx(ctx, runtime, deps, input, state, fetchLimits, deadline, disposables);
    const data = await invokeFetchHandler(ctx, runtime, input, ctxObj, deadline, state, disposables);

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
    for (const h of disposables) {
      try { h.dispose(); } catch { /* already freed */ }
    }
    ctx.dispose();
    runtime.dispose();
  }
}
