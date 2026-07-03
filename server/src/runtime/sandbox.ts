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
  type Transport,
  type FetchProxyOutcome,
} from "./broker/fetch-proxy.js";
import type { RequestInit as BrokerRequestInit } from "./broker/assemble.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const HTML_STDLIB_SOURCE = readFileSync(
  resolve(__dirname, "../../../adapters/_stdlib/html.bundle.js"),
  "utf-8",
);

export interface SandboxLimits {
  /** 单次执行墙钟超时（毫秒） */
  timeoutMs: number;
  /** wasm 线性内存上限（字节） */
  memoryBytes: number;
}

export const DEFAULT_LIMITS: SandboxLimits = {
  timeoutMs: 5_000,
  memoryBytes: 64 * 1024 * 1024,
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

export type SandboxFailureReason =
  | "bad_export"
  | "capability_missing"
  | "async_in_parser"
  | "adapter_threw"
  | "timeout"
  | "memory"
  | "fetch_limit";

export class SandboxError extends Error {
  constructor(
    readonly reason: SandboxFailureReason,
    message: string,
  ) {
    super(message);
    this.name = "SandboxError";
  }
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

function unwrap(ctx: QuickJSContext, result: ReturnType<QuickJSContext["evalCode"]>, deadline: number): QuickJSHandle {
  if ("value" in result) return result.value;
  const dumped = ctx.dump(result.error);
  result.error.dispose();
  const message = errorMessage(dumped);
  if (Date.now() >= deadline || /interrupted/i.test(message)) {
    throw new SandboxError("timeout", `adapter 执行超时被中断：${message}`);
  }
  if (/out of memory|memory/i.test(message)) {
    throw new SandboxError("memory", `adapter 触碰内存上限：${message}`);
  }
  throw new SandboxError("adapter_threw", message);
}

function errorMessage(dumped: unknown): string {
  if (dumped && typeof dumped === "object" && "message" in dumped) {
    const name = "name" in dumped ? String((dumped as Record<string, unknown>).name) : "Error";
    return `${name}: ${String((dumped as Record<string, unknown>).message)}`;
  }
  return String(dumped);
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

function marshal(ctx: QuickJSContext, scope: Scope, value: unknown): QuickJSHandle {
  const json = JSON.stringify(value);
  if (json === undefined) return ctx.undefined;
  const strHandle = scope.manage(ctx.newString(json));
  const jsonObj = scope.manage(ctx.getProp(ctx.global, "JSON"));
  const parseFn = scope.manage(ctx.getProp(jsonObj, "parse"));
  return scope.manage(unwrap(ctx, ctx.callFunction(parseFn, jsonObj, strHandle), Number.POSITIVE_INFINITY));
}

function isThenable(ctx: QuickJSContext, scope: Scope, handle: QuickJSHandle): boolean {
  const t = ctx.typeof(handle);
  if (t !== "object" && t !== "function") return false;
  const thenHandle = scope.manage(ctx.getProp(handle, "then"));
  return ctx.typeof(thenHandle) === "function";
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
  perRequestTimeoutMs: 10_000,
  totalNetworkMs: 30_000,
  maxRequests: 20,
  maxHopsPerRequest: 5,
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
}

function jsonToHandle(ctx: QuickJSContext, value: unknown): QuickJSHandle {
  const json = JSON.stringify(value) ?? "null";
  const strH = ctx.newString(json);
  const jsonObj = ctx.getProp(ctx.global, "JSON");
  const parseFn = ctx.getProp(jsonObj, "parse");
  const res = ctx.callFunction(parseFn, jsonObj, strH);
  strH.dispose();
  parseFn.dispose();
  jsonObj.dispose();
  if ("value" in res) return res.value;
  const dumped = ctx.dump(res.error);
  res.error.dispose();
  throw new SandboxError("adapter_threw", `marshal 失败：${JSON.stringify(dumped)}`);
}

function isThenableHandle(ctx: QuickJSContext, handle: QuickJSHandle): boolean {
  const t = ctx.typeof(handle);
  if (t !== "object" && t !== "function") return false;
  const thenH = ctx.getProp(handle, "then");
  const isFn = ctx.typeof(thenH) === "function";
  thenH.dispose();
  return isFn;
}

function withTimeout<T>(p: Promise<T>, ms: number, onTimeout: () => Error): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(onTimeout()), ms);
    (timer as { unref?: () => void }).unref?.();
    p.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e: unknown) => { clearTimeout(timer); reject(e as Error); },
    );
  });
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
  deferred.settled.then(
    () => { runtime.executePendingJobs(); },
  );
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
        throw state.fatal;
      }
      const start = Date.now();
      const outcome: FetchProxyOutcome = await withTimeout(
        proxyFetch(url, init, {
          view: deps.view,
          resolver: deps.resolver,
          jar: state.jar,
          transport: deps.transport,
          maxHops: fetchLimits.maxHopsPerRequest,
        }),
        fetchLimits.perRequestTimeoutMs,
        () => new SandboxError("fetch_limit", `单请求超时（>${fetchLimits.perRequestTimeoutMs}ms）`),
      );
      state.networkMs += Date.now() - start;
      state.requestCount += outcome.requestCount;
      if (state.networkMs > fetchLimits.totalNetworkMs) {
        state.fatal = new SandboxError("fetch_limit", `累计网络耗时超限（>${fetchLimits.totalNetworkMs}ms）`);
        throw state.fatal;
      }
      if (state.requestCount > fetchLimits.maxRequests) {
        state.fatal = new SandboxError("fetch_limit", `单次执行请求数超限（>${fetchLimits.maxRequests}）`);
        throw state.fatal;
      }
      const payload: Record<string, unknown> = { status: outcome.status, headers: outcome.headers };
      if (outcome.body !== undefined) payload.body = outcome.body;
      return jsonToHandle(ctx, payload);
    })();

    return bridgeHostPromise(ctx, hostPromise, runtime);
  });

  // wrap raw fetch into Response-like interface for adapter ergonomics
  const wrapFactory = track(
    unwrap(
      ctx,
      ctx.evalCode(
        `(raw) => (url, init) => raw(url, init).then((r) => ({
           status: r.status,
           ok: r.status >= 200 && r.status < 300,
           headers: r.headers,
           text: () => Promise.resolve(r.body === undefined ? "" : r.body),
           json: () => Promise.resolve(JSON.parse(r.body === undefined ? "null" : r.body)),
         }))`,
        "fetch-response-shim.js",
      ),
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
      () => new SandboxError("timeout", "fetch handler 未在墙钟内完成"),
    );
    runtime.executePendingJobs();
    if (state.fatal) throw state.fatal;
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
    for (const h of disposables) {
      try { h.dispose(); } catch { /* already freed */ }
    }
    ctx.dispose();
    runtime.dispose();
  }
}
