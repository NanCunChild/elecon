/**
 * Adapter SDK 类型声明（供 adapter 编写者参考，非运行期依赖）
 *
 * 同一份 adapter 在客户端（QuickJS）与服务端（QuickJS-wasm）以相同语义被调用——
 * 两端是同一个 QuickJS 引擎，零语义漂移（见 docs/adr/adr_005_runtime.md）。
 * 模式由 manifest 的 `mode` 决定（fetch | parser）。
 */

// ---- fetch 模式的 ctx ----

interface CtxFetch {
  /** 受限 fetch：仅命中 manifest 白名单的域名会被注入凭证 */
  fetch(url: string, init?: RequestInit): Promise<Response>;
  log(level: "debug" | "info" | "warn" | "error", message: string): void;
  now(): number;
}

type FetchCapabilityHandler<Params, Result> = (
  ctx: CtxFetch,
  params: Params,
) => Promise<Result>;

// ---- parser 模式的 ctx ----

interface ParserResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

interface CtxParser {
  /** 无 fetch —— parser 模式 adapter 无网络能力 */
  log(level: "debug" | "info" | "warn" | "error", message: string): void;
  now(): number;
}

type ParserCapabilityHandler<Params, Result> = (
  ctx: CtxParser,
  params: Params,
  responses: Record<string, ParserResponse>,
) => Result;

// ---- 公共 ----

interface EnvelopeSource {
  schoolId: string;
  adapterId: string;
  adapterVersion: string;
  origin: "client-direct" | "campus-relay" | "public-cache";
}

interface EnvelopeFreshness {
  fetchedAt: string;
  ttlSeconds: number;
  stale: boolean;
}

interface Envelope<T> {
  schema: string;
  schemaVersion: string;
  source: EnvelopeSource;
  freshness: EnvelopeFreshness;
  data: T;
}

// Capability 导出约定
type CapabilityModule = {
  capabilities: Record<string, FetchCapabilityHandler<unknown, unknown> | ParserCapabilityHandler<unknown, unknown>>;
};
