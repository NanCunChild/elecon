/**
 * sandbox QuickJS 底层工具 —— 从 sandbox.ts 抽出的**通用引擎/错误 plumbing**。
 *
 * 抽出动机（审阅：sandbox.ts 569 行 God File）：这些是**不含凭证语义**的 QuickJS handle
 * 编解码与错误归一化，与 declarative/imperative requestGraph 两路径共用。抽出后单向依赖
 * （本文件不 import sandbox.ts），无循环。**凭证承重逻辑（buildImperativeCtx /
 * invokeImperativeHandler）仍留在 sandbox.ts**，其进一步拆分是 🔒 承重路径，须人工主导。
 */

import type { QuickJSContext, QuickJSHandle, Scope } from "quickjs-emscripten";

export type SandboxFailureReason =
  | "bad_export"
  | "capability_missing"
  | "async_in_declarative"
  | "adapter_threw"
  | "timeout"
  | "memory"
  | "fetch_limit"
  // 信任闸门拒绝：档位 × 环境不满足入场条件（ADR-002 §2.6 结构化权限错误）。
  | "trust_rejected";

export class SandboxError extends Error {
  constructor(
    readonly reason: SandboxFailureReason,
    message: string,
  ) {
    super(message);
    this.name = "SandboxError";
  }
}

export function errorMessage(dumped: unknown): string {
  if (dumped && typeof dumped === "object" && "message" in dumped) {
    const name = "name" in dumped ? String((dumped as Record<string, unknown>).name) : "Error";
    return `${name}: ${String((dumped as Record<string, unknown>).message)}`;
  }
  return String(dumped);
}

export function unwrap(
  ctx: QuickJSContext,
  result: ReturnType<QuickJSContext["evalCode"]>,
  deadline: number,
): QuickJSHandle {
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

/** scope 托管版 JSON marshal（declarative 路径）。 */
export function marshal(ctx: QuickJSContext, scope: Scope, value: unknown): QuickJSHandle {
  const json = JSON.stringify(value);
  if (json === undefined) return ctx.undefined;
  const strHandle = scope.manage(ctx.newString(json));
  const jsonObj = scope.manage(ctx.getProp(ctx.global, "JSON"));
  const parseFn = scope.manage(ctx.getProp(jsonObj, "parse"));
  return scope.manage(unwrap(ctx, ctx.callFunction(parseFn, jsonObj, strHandle), Number.POSITIVE_INFINITY));
}

/** scope 托管版 thenable 判定（declarative 路径）。 */
export function isThenable(ctx: QuickJSContext, scope: Scope, handle: QuickJSHandle): boolean {
  const t = ctx.typeof(handle);
  if (t !== "object" && t !== "function") return false;
  const thenHandle = scope.manage(ctx.getProp(handle, "then"));
  return ctx.typeof(thenHandle) === "function";
}

/** 手动 dispose 版 JSON marshal（imperative 路径，无 Scope）。 */
export function jsonToHandle(ctx: QuickJSContext, value: unknown): QuickJSHandle {
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

/** 手动 dispose 版 thenable 判定（imperative 路径）。 */
export function isThenableHandle(ctx: QuickJSContext, handle: QuickJSHandle): boolean {
  const t = ctx.typeof(handle);
  if (t !== "object" && t !== "function") return false;
  const thenH = ctx.getProp(handle, "then");
  const isFn = ctx.typeof(thenH) === "function";
  thenH.dispose();
  return isFn;
}

export function withTimeout<T>(p: Promise<T>, ms: number, onTimeout: () => Error): Promise<T> {
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
