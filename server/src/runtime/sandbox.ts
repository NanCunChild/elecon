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

import {
  getQuickJS,
  Scope,
  shouldInterruptAfterDeadline,
  type QuickJSContext,
  type QuickJSHandle,
} from "quickjs-emscripten";

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
  | "memory"; // 触碰内存上限

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
