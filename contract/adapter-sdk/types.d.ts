/**
 * Adapter SDK 类型声明（供 adapter 编写者参考，非运行期依赖）
 *
 * 同一份 adapter 在客户端（QuickJS）与服务端（QuickJS-wasm）以相同语义被调用——
 * 两端是同一个 QuickJS 引擎，零语义漂移（见 docs/adr/adr_005_runtime.md）。
 * 模式由 manifest 的 `mode` 决定（fetch | parser）。
 */

// ---- fetch 模式的 ctx ----

interface CtxFetch {
  /**
   * 受限 fetch（语义见 ADR-009，2026-06-13 修订）：
   * - 出口 fail-closed：URL 必须命中 manifest `network.allow`，否则直接拒绝。
   * - **命中白名单 ≠ 注入凭证**：仅当 URL 命中某 `credentials.<name>.scope` 时
   *   broker 才注入对应凭证（inject）；白名单内但未被任何 scope 覆盖的 URL 放行
   *   但不注入（passthrough，用于反爬挑战端点 / 公开 CDN / OAuth 中间端点等）。
   * - adapter 永不接触凭证值，也拿不到带 token 的 URL / Set-Cookie / 重定向中间 token。
   */
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
