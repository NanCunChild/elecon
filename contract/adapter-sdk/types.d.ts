/**
 * Adapter SDK 类型声明（供 adapter 编写者参考，非运行期依赖）
 *
 * 同一份 adapter 在客户端（QuickJS）与服务端（QuickJS-wasm）以相同语义被调用——
 * 两端是同一个 QuickJS 引擎，零语义漂移（见 docs/adr/adr_005_runtime.md）。
 * 请求图由每 capability 的 `requestGraph` 决定（declarative | imperative；ADR-022）。
 */

/// <reference lib="dom" />
// ^ CtxImperative.fetch 复用 DOM 标准的 RequestInit / Response 类型（受限 fetch 的语义子集，
//   见 ADR-009 §2.1）；引入 dom lib 使本参考声明在严格 TS 下可独立编译。

// ---- imperative requestGraph 的 ctx ----

interface CtxImperative {
  /**
   * 受限 fetch（语义见 ADR-009，2026-06-13 修订）：
   * - 出口 fail-closed：URL 必须命中 manifest `network.allow`，否则直接拒绝。
   * - **命中白名单 ≠ 注入凭证**：仅当 URL 命中某 `credentials.<name>.scope` 时
   *   broker 才注入对应凭证（inject）；白名单内但未被任何 scope 覆盖的 URL 放行
   *   但不注入（passthrough，用于反爬挑战端点 / 公开 CDN / OAuth 中间端点等）。
   * - adapter 永不接触凭证值，也拿不到带 token 的 URL / Set-Cookie / 重定向中间 token。
   */
  fetch(url: string, init?: RequestInit): Promise<Response>;
  /**
   * 执行内 ephemeral cookie 写回（语义见 ADR-009 §2.4，2026-06-15 rev-3）。
   *
   * 用途：解多步握手中「origin 不经 `Set-Cookie`、而把会话 token 放响应 body、
   * 由页面 JS `document.cookie` 写入」这类缺口（实测见 XJT 教务挑战页的
   * `client_id`）。adapter 经 §2.5 body 透传本就能读到该值，此 API 允许把它写回
   * **同源 passthrough** cookie，使后续 `ctx.fetch` 自动携带——不新增任何超出
   * body 透传既有面的外泄面。
   *
   * 写入 per-execution jar 的独立 **ephemeral 分区**，由 Broker 强制四重栅栏
   * （adapter 自律不算数）：
   * 1. **仅 passthrough origin**：`opts.domain` 须 domain-match 某 `network.allow`
   *    条目、且**不**落在任何 `credentials.<name>.scope` 内——永不能写到凭证域。
   *    `opts.path`（缺省 `/`）须为对应 allow 条目 path 的子路径。
   * 2. **不覆盖 broker 注入**：请求拼装时优先级低于 broker 注入分区与 origin
   *    `Set-Cookie`，同名以后两者为准。
   * 3. **永不收割**：ephemeral 分区不参与 §2.4 收割，绝不进核心凭证库（ADR-012）。
   * 4. **执行即弃**：随 per-execution jar 在执行结束时整体丢弃，不跨执行、不持久化。
   *
   * 越栅栏的调用由 Broker 静默丢弃并 `ctx.log("warn")`，不抛错、不给 adapter
   * 探测栅栏边界的异常信号。adapter 永不接触任何凭证值。
   */
  setEphemeralCookie(
    name: string,
    value: string,
    opts: { domain: string; path?: string },
  ): void;
  log(level: "debug" | "info" | "warn" | "error", message: string): void;
  now(): number;
}

type ImperativeCapabilityHandler<Params, Result> = (
  ctx: CtxImperative,
  params: Params,
) => Promise<Result>;

// ---- declarative requestGraph 的 ctx ----

interface ParserResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

interface CtxDeclarative {
  /** 无 fetch —— declarative requestGraph 的 adapter 无网络能力 */
  log(level: "debug" | "info" | "warn" | "error", message: string): void;
  now(): number;
}

type DeclarativeCapabilityHandler<Params, Result> = (
  ctx: CtxDeclarative,
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
  capabilities: Record<
    string,
    | ImperativeCapabilityHandler<unknown, unknown>
    | DeclarativeCapabilityHandler<unknown, unknown>
  >;
};
