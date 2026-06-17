/**
 * adapter 服务端执行沙箱 —— QuickJS-wasm（quickjs-emscripten）。
 *
 * 为什么是 QuickJS-wasm 而不是 Node 的 `vm`：
 *   - Node 的 `vm` **不是安全边界**，半可信/侧载 adapter 在里面等于裸奔。
 *   - QuickJS-wasm 同时给到：真正的沙箱、与客户端**同一个引擎**（零语义漂移）、
 *     纯 JS/wasm 无 cgo。
 * 详见 docs/adr/adr_005_runtime.md。
 *
 * 当前实现：**parser 模式**（无网络、无凭证、纯解析器）。
 * fetch 模式的受限 ctx.fetch（凭证白名单注入）是承重路径，单独作为有人工审阅的
 * PR 落地（红线 #1），此处尚未实现，遇到即拒绝。
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
  /** adapter 源码（同一份脚本，两端共用） */
  source: string;
  /** capability id，如 "grades.list" */
  capability: string;
  /** 入参（已按 params schema 校验） */
  params: unknown;
  /**
   * parser 模式：核心代取并脱敏后的原始响应。
   * fetch 模式下由宿主注入受限 ctx.fetch，不在此处传入。
   */
  responses?: Record<string, { status: number; headers: Record<string, string>; body: string }>;
  /**
   * 注入给 adapter 的 ctx.now() 返回值（毫秒）。
   * 默认 Date.now()；golden 双跑测试应固定它以保证确定性。
   */
  nowMs?: number;
  /** adapter 调用 ctx.log 的回流；默认丢弃。 */
  onLog?: (level: LogLevel, message: string) => void;
}

export interface AdapterRunResult {
  /** adapter 归一化产出；由宿主据 emits.schema 校验后才被接受 */
  data: unknown;
}

/**
 * 沙箱层面的失败。**不携带契约的 error.kind**——契约错误词表是领域概念，
 * 由宿主层据 `reason` 映射（建议：adapter_threw/async_in_parser → parse_failed，
 * capability_missing/bad_export → capability_unsupported，timeout/memory →
 * source_unavailable）。沙箱只负责诚实地报告底层原因。
 */
export type SandboxFailureReason =
  | "bad_export" // adapter 未导出 capabilities 对象
  | "capability_missing" // 指定 capability 不在 adapter 内
  | "async_in_parser" // parser capability 返回了 Promise（parser 必须同步）
  | "adapter_threw" // adapter 执行期抛错
  | "timeout" // 超过墙钟超时被中断
  | "memory" // 触碰内存上限
  | "fetch_limit"; // fetch 模式：单请求 10s / 累计 30s / 单次 ≤20 请求任一超限（ADR-009 §2.7）

export class SandboxError extends Error {
  constructor(
    readonly reason: SandboxFailureReason,
    message: string,
  ) {
    super(message);
    this.name = "SandboxError";
  }
}

/**
 * 在 QuickJS-wasm 沙箱内执行一次 adapter capability（parser 模式）。
 *
 * 不变量（实现保证）：
 *  - 默认无网络、无凭证：parser 模式的 ctx 只有 log/now，不存在 fetch。
 *  - 交给 adapter 的 responses 由宿主在调用前剥除 Set-Cookie / Authorization
 *    回显 / 中间 token（沙箱不做剥离，只消费已脱敏的输入）。
 *  - 超时与内存按 limits 强制；越界即中断并抛 SandboxError。
 *  - 产出**不在此处按 schema 校验**——校验在宿主侧，校验不过返回 parse_failed。
 */
export async function runAdapter(
  input: AdapterRunInput,
  limits: SandboxLimits = DEFAULT_LIMITS,
): Promise<AdapterRunResult> {
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
  try {
    return Scope.withScope((scope): AdapterRunResult => {
      // 1) 以 ES module 求值 adapter，取其 namespace（零 transform，两端同一约定）
      const nsHandle = scope.manage(
        unwrap(ctx, ctx.evalCode(input.source, "adapter.js", { type: "module" }), deadline),
      );
      runtime.executePendingJobs();

      // 2) 取 capabilities[capability]，类型门禁
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

      // 3) 组装受限 parser ctx 与入参，调用
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

      // 4) parser 必须同步：拒绝 Promise 返回
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

/**
 * unwrapResult 的包装：把 QuickJS 的失败转成 SandboxError。
 * 超时（被 interrupt）与内存越界在 QuickJS 里都表现为求值错误，
 * 这里据 deadline 与错误文本区分。
 */
function unwrap(ctx: QuickJSContext, result: ReturnType<QuickJSContext["evalCode"]>, deadline: number): QuickJSHandle {
  if ("value" in result) {
    return result.value;
  }
  // 失败分支：result.error 是 VM 内的错误句柄
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

/** 构造 parser 模式的 ctx：只有 log 与 now，**没有 fetch**（无网络）。 */
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

/** 用 VM 自带的 JSON.parse 把宿主 JSON 值搬进 VM（避免逐字段手工 marshal）。 */
function marshal(ctx: QuickJSContext, scope: Scope, value: unknown): QuickJSHandle {
  const json = JSON.stringify(value);
  if (json === undefined) {
    return ctx.undefined;
  }
  const strHandle = scope.manage(ctx.newString(json));
  const jsonObj = scope.manage(ctx.getProp(ctx.global, "JSON"));
  const parseFn = scope.manage(ctx.getProp(jsonObj, "parse"));
  return scope.manage(unwrap(ctx, ctx.callFunction(parseFn, jsonObj, strHandle), Number.POSITIVE_INFINITY));
}

/** duck-typing：值是否 thenable（typeof object/function 且 .then 是函数）。 */
function isThenable(ctx: QuickJSContext, scope: Scope, handle: QuickJSHandle): boolean {
  const t = ctx.typeof(handle);
  if (t !== "object" && t !== "function") {
    return false;
  }
  const thenHandle = scope.manage(ctx.getProp(handle, "then"));
  return ctx.typeof(thenHandle) === "function";
}

// ───────────────────────────────────────────────────────────────────────────
// fetch 模式运行时（Gate A · B6b）—— ADR-009 §2.1/§2.7/§2.8 · 计划 b6_fetch_runtime_plan §3
//
// 把 B6a 拼装管线（proxyFetch）接到 QuickJS 引擎：异步 handler + job queue pump + await，
// 受限 `ctx.fetch` 经 broker 注入凭证、自跟随重定向、脱敏后交回 adapter；执行结束按 B5
// 判据 b 收割耐久 cookie。这是首个真正触引擎（非纯逻辑）的 broker 件，不可纯 golden 化，
// 用 fake transport 驱动端到端集成测试（sandbox.fetch.smoke.ts）。
//
// 🔒 红线 #1 凭证注入 + 出网承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环。
// ───────────────────────────────────────────────────────────────────────────

/** fetch 模式资源限额（ADR-009 §2.7；数值占位，待首个真实 adapter 实测校准 §2.8）。 */
export interface FetchLimits {
  /** 单请求超时（含重定向链总耗时，计划 §8 #3 拍板）。 */
  perRequestTimeoutMs: number;
  /** 单次执行累计网络耗时（跨所有 ctx.fetch）。 */
  totalNetworkMs: number;
  /** 单次执行最大请求数（每跳各计一次，含重定向跳，计划 §8 #3）。 */
  maxRequests: number;
  /** 单请求最大重定向跳数（B3 默认 5）。 */
  maxHopsPerRequest: number;
}

export const DEFAULT_FETCH_LIMITS: FetchLimits = {
  perRequestTimeoutMs: 10_000,
  totalNetworkMs: 30_000,
  maxRequests: 20,
  maxHopsPerRequest: 5,
};

/** fetch 模式运行时依赖（宿主注入；凭证值仅核心可见，红线 #1）。 */
export interface FetchAdapterDeps {
  /** Broker manifest 视图（allow + credentials；绝不含凭证值）。 */
  view: BrokerManifestView;
  /** 凭证 resolver（B1 判 inject 后取值拼头）。 */
  resolver: CredentialResolver;
  /** 出网 seam（真实 transport 属 ADR-003，另件注入；测试用 fake）。 */
  transport: Transport;
  /**
   * 执行结束 B5 收割钩子（可选）。给出则成功执行后按判据 b 收割 origin 区耐久 cookie 入库。
   * **fail 不收割**（计划 §5：避免半截状态入库）。
   */
  harvest?: { sink: HarvestSink; schoolId: string };
}

/** 不经 Scope 的 JSON→VM 句柄搬运（fetch 回调跨 await，不能用同步 Scope）。返回未托管句柄，调用方负责释放/转移。 */
function jsonToHandle(ctx: QuickJSContext, value: unknown): QuickJSHandle {
  const json = JSON.stringify(value) ?? "null";
  const strH = ctx.newString(json);
  const jsonObj = ctx.getProp(ctx.global, "JSON");
  const parseFn = ctx.getProp(jsonObj, "parse");
  const res = ctx.callFunction(parseFn, jsonObj, strH);
  strH.dispose();
  parseFn.dispose();
  jsonObj.dispose();
  if ("value" in res) {
    return res.value;
  }
  const dumped = ctx.dump(res.error);
  res.error.dispose();
  throw new SandboxError("adapter_threw", `marshal 失败：${JSON.stringify(dumped)}`);
}

/** 无 Scope 版 thenable 判定（手动释放探测句柄）。 */
function isThenableHandle(ctx: QuickJSContext, handle: QuickJSHandle): boolean {
  const t = ctx.typeof(handle);
  if (t !== "object" && t !== "function") return false;
  const thenH = ctx.getProp(handle, "then");
  const isFn = ctx.typeof(thenH) === "function";
  thenH.dispose();
  return isFn;
}

/** 给 promise 套超时；超时以 onTimeout() 拒绝（定时器 unref，不阻塞进程退出）。 */
function withTimeout<T>(p: Promise<T>, ms: number, onTimeout: () => Error): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(onTimeout()), ms);
    (timer as { unref?: () => void }).unref?.();
    p.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e: unknown) => {
        clearTimeout(timer);
        reject(e as Error);
      },
    );
  });
}

/**
 * fetch 模式执行一次 adapter capability。与 {@link runAdapter}（parser）并列、互不干扰：
 * parser 已签收，本路径独立新增。
 *
 * 不变量（实现保证，🔒 安全清单逐项）：
 *  - 凭证仅在 proxyFetch 内拼头；adapter 入参/返回/ctx.fetch 响应均无凭证值（Set-Cookie/
 *    Authorization 回显/中间 Location 已由 B2/B3 剥除）。
 *  - 出口 fail-closed：url 不在 allow → ctx.fetch 的 Promise 被拒（adapter 可 catch；不附凭证）。
 *  - 限额硬执行：单请求 10s / 累计 30s / 单次 ≤20 请求，任一超限 → 终止执行（fetch_limit），
 *    **即便 adapter 吞掉拒绝也不放过**（fatal 标记在 await 后再次校验）。
 *  - fail 不收割：仅成功执行后调 B5 收割钩子；任何失败路径都不写库。
 *  - 墙钟/内存按 limits 强制（同 parser）；异步未在墙钟内完成 → timeout。
 */
export async function runFetchAdapter(
  input: AdapterRunInput,
  deps: FetchAdapterDeps,
  limits: SandboxLimits = DEFAULT_LIMITS,
  fetchLimits: FetchLimits = DEFAULT_FETCH_LIMITS,
): Promise<AdapterRunResult> {
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

  // 执行内状态：per-execution jar（两端不可见）+ 限额计量 + fatal 终止标记。
  const jar = new CookieJar();
  let requestCount = 0;
  let networkMs = 0;
  let fatal: SandboxError | null = null;
  const nowMs = input.nowMs ?? Date.now();
  const disposables: QuickJSHandle[] = [];
  const track = (h: QuickJSHandle): QuickJSHandle => {
    disposables.push(h);
    return h;
  };

  try {
    // ── 组装受限 fetch ctx：log / now / fetch / setEphemeralCookie ──
    const ctxObj = track(ctx.newObject());

    const logFn = ctx.newFunction("log", (levelH, msgH) => {
      const level =
        levelH && ctx.typeof(levelH) === "string" ? (ctx.getString(levelH) as LogLevel) : "info";
      const message = msgH && ctx.typeof(msgH) === "string" ? ctx.getString(msgH) : "";
      input.onLog?.(level, message);
    });
    ctx.setProp(ctxObj, "log", logFn);
    logFn.dispose();

    const nowFn = ctx.newFunction("now", () => ctx.newNumber(nowMs));
    ctx.setProp(ctxObj, "now", nowFn);
    nowFn.dispose();

    // 受限 ctx.fetch：返回 VM Promise；宿主侧跑 proxyFetch + 限额计量；settle 后 pump job queue。
    const fetchFn = ctx.newFunction("fetch", (urlH, initH) => {
      const url = ctx.typeof(urlH) === "string" ? ctx.getString(urlH) : "";
      const init: BrokerRequestInit =
        initH && ctx.typeof(initH) === "object" ? (ctx.dump(initH) as BrokerRequestInit) : {};

      const hostPromise: Promise<QuickJSHandle> = (async () => {
        if (fatal) throw fatal;
        if (requestCount >= fetchLimits.maxRequests) {
          fatal = new SandboxError("fetch_limit", `单次执行请求数超限（>${fetchLimits.maxRequests}）`);
          throw fatal;
        }
        const start = Date.now();
        const outcome: FetchProxyOutcome = await withTimeout(
          proxyFetch(url, init, {
            view: deps.view,
            resolver: deps.resolver,
            jar,
            transport: deps.transport,
            maxHops: fetchLimits.maxHopsPerRequest,
          }),
          fetchLimits.perRequestTimeoutMs,
          () => new SandboxError("fetch_limit", `单请求超时（>${fetchLimits.perRequestTimeoutMs}ms）`),
        );
        networkMs += Date.now() - start;
        requestCount += outcome.requestCount;
        if (networkMs > fetchLimits.totalNetworkMs) {
          fatal = new SandboxError("fetch_limit", `累计网络耗时超限（>${fetchLimits.totalNetworkMs}ms）`);
          throw fatal;
        }
        if (requestCount > fetchLimits.maxRequests) {
          fatal = new SandboxError("fetch_limit", `单次执行请求数超限（>${fetchLimits.maxRequests}）`);
          throw fatal;
        }
        // 仅交回脱敏后的 status/headers/body（凭证等价物已剥除）。
        const payload: Record<string, unknown> = { status: outcome.status, headers: outcome.headers };
        if (outcome.body !== undefined) payload.body = outcome.body;
        return jsonToHandle(ctx, payload);
      })();

      // 手动 deferred：resolve 后**显式释放**响应句柄（避免 runtime.dispose 时 GC 残留断言）。
      const deferred = ctx.newPromise();
      void hostPromise.then(
        (respHandle) => {
          deferred.resolve(respHandle);
          respHandle.dispose();
        },
        (err: unknown) => {
          const msg = err instanceof Error ? err.message : String(err);
          const errH = ctx.newString(msg);
          deferred.reject(errH);
          errH.dispose();
        },
      );
      // settle 后 pump，使 adapter 的 await 续跑（job queue 推进）。
      void deferred.settled.then(() => {
        runtime.executePendingJobs();
      });
      return deferred.handle;
    });
    ctx.setProp(ctxObj, "fetch", fetchFn);
    fetchFn.dispose();

    // ctx.setEphemeralCookie：写 jar ephemeral 分区，四重栅栏由 B4 强制（违例静默 warn 不抛）。
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
      jar.writeEphemeral(writeInput, deps.view, (m) => input.onLog?.("warn", m));
    });
    ctx.setProp(ctxObj, "setEphemeralCookie", setEphFn);
    setEphFn.dispose();

    // ── 求值 adapter module，取 capability handler ──
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

    // ── 调用 handler（fetch 模式 = 异步），pump + await ──
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
      // 限额终止优先于产出/adapter 错误：fatal 在 fetch 超限时即置位（早于 handler settle），
      // 必须在 unwrap 之前校验——否则 adapter 未 catch 的拒绝会被 unwrap 归为 adapter_threw 掩盖 fetch_limit。
      if (fatal) throw fatal;
      dataHandle = track(unwrap(ctx, settledResult, deadline));
    } else {
      if (fatal) throw fatal;
      // 同步返回也接受（handler 未真正 await）。
      dataHandle = retHandle;
    }

    const data = ctx.dump(dataHandle);

    // ── 执行结束 B5 收割钩子（仅成功路径；fail 不收割）──
    if (deps.harvest) {
      const plan = decideHarvest([...jar.harvestView()], deps.view);
      harvestInto(plan, deps.view, deps.harvest.sink, {
        schoolId: deps.harvest.schoolId,
        now: () => nowMs,
      });
    }

    return { data };
  } catch (err) {
    // BrokerFetchRejected 若一路冒泡到顶（adapter 未 catch），归类为 adapter_threw（诚实报告）。
    if (err instanceof BrokerFetchRejected) {
      throw new SandboxError("adapter_threw", err.message);
    }
    throw err;
  } finally {
    for (const h of disposables) {
      try {
        h.dispose();
      } catch {
        /* 已释放/无效句柄忽略 */
      }
    }
    ctx.dispose();
    runtime.dispose();
  }
}
