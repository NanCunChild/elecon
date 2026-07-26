// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface Error {
  /** 错误契约的固定 schema id，恒为 elecon.error。 */
  schema: unknown;
  /** 错误 schema 的 MAJOR.MINOR 版本。 */
  schemaVersion: string;
  /** 归一化错误详情，供 UI 和同步层决定重试、登录或降级。 */
  error: ErrorError;
}

export interface ErrorError {
  /** 错误类别：需认证、源站不可用、网络白名单拦截、限流、解析失败或能力不支持。 */
  kind: "auth_required" | "source_unavailable" | "network_blocked" | "rate_limited" | "parse_failed" | "capability_unsupported";
  /** 当前错误是否适合重试。 */
  retriable: boolean;
  /** 发生错误的 capability id。 */
  capability: string;
  /** 可安全展示的错误文案，最长 256 字符；禁止包含凭证、堆栈、内网地址等敏感信息（ADR-001 §7）。 */
  message: string;
}
