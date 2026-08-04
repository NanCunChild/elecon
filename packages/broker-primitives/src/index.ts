/**
 * Broker URL 匹配原语 —— network.allow / credentials.scope 的 uri-template 匹配。
 *
 * **TS 侧单一实现**（审阅 P2-4）：此前 server broker 与 tools validator 各持一份
 * 内联拷贝、靠共享 golden 事后钉死；现收敛为本包，二者 import 之，结构上消除
 * TS 内漂移面。客户端 Dart 镜像（`client/lib/core/broker/url_match.dart`）照同一
 * golden（`contract/golden/broker/url-match.json`）复刻——钉死的是**行为**，不是
 * 源文件（ADR-001 §8 两端双跑哲学）。
 *
 * 约定（broker 运行时与校验器 C4/C6/C7 同一套）：白名单 / scope 为「尾随 `*` 的
 * 前缀型」模板（`https://host/path/*`），`*` 是唯一通配。多段 `*` / `{+path}` 等
 * 复杂模板**不在约定内**——引入须同步重评校验器 C6/C7 与本模块（ADR-013 §2.4）。
 *
 * 🔒 安全敏感（红线 #1 注入决策路径）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
 */

export * from "./linear-regex.js";

/**
 * 响应头 allowlist（ADR-009 §2.5 默认集，小写）——**单一数据源**。
 *
 * 运行时 `sanitizeResponseHeaders`（server broker）据此决定哪些响应头能交回 adapter；
 * 校验器 CH3（tools validator）据此禁止命名凭证头（ADR-029 §2.1 `headerName`）落在其中。
 *
 * 🔒 **两处必须同源**：若命名凭证头名与响应 allowlist 名相同，上游一旦把凭证值回显在同名
 * 响应头上，`sanitizeResponseHeaders` 会当作合法头**保留**，凭证值直达 adapter（破红线 #1）。
 * 命名头注入的「回显必被丢弃」由此成为**结构保证**（CH3 拦在声明期），而非「所选名恰好不在
 * allowlist」的巧合。故此集与 CH3 denylist 同源，防两表漂移。
 */
export const RESPONSE_HEADER_ALLOWLIST: ReadonlySet<string> = new Set([
  "content-type",
  "content-length",
  "content-encoding",
  "date",
  "cache-control",
  "etag",
  "last-modified",
]);

/**
 * ADR-029 §2.1 命名 credential header 固定禁集（小写）。
 *
 * CH3 的完整禁集是本集合与 [RESPONSE_HEADER_ALLOWLIST] 的并集。validator 与 TS Broker
 * runtime 必须共用这份定义；Dart 侧由 inject-policy golden 镜像锁定（ADR-001 §8）。
 */
export const FORBIDDEN_CREDENTIAL_HEADER_NAMES: ReadonlySet<string> = new Set([
  "cookie",
  "set-cookie",
  "host",
  "content-length",
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

/** 把 `https://h/api/*` 形态模板转成锚定正则；`*` → `.*`，其余字面转义。 */
export function allowToRegex(pattern: string): RegExp {
  const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const withWildcard = escaped.replace(/\\\*/g, ".*");
  return new RegExp("^" + withWildcard + "$");
}

/** 把具体 url 里的 `{param}` 占位中性化，避免占位符干扰匹配。 */
function concretize(url: string): string {
  return url.replace(/\{[^}]+\}/g, "_");
}

/** 具体 url 是否被某白名单项覆盖（fail-closed 出口判定）。 */
export function urlCoveredByAllow(url: string, allow: readonly string[]): boolean {
  const concrete = concretize(url);
  return allow.some((p) => allowToRegex(p).test(concrete));
}

/** 单个 scope 模式是否命中具体 url（与 allow 同一匹配语义）。 */
export function scopeMatches(url: string, pattern: string): boolean {
  return allowToRegex(pattern).test(concretize(url));
}

/**
 * 取模板第一个 `*` 前的字面前缀（无 `*` 取全串）。用于最长前缀消歧——前缀越长 =
 * 覆盖越窄 = 越精确 = 优先级越高（broker 运行时与校验器 C7 同一约定）。
 */
export function scopePrefix(pattern: string): string {
  const star = pattern.indexOf("*");
  return star === -1 ? pattern : pattern.slice(0, star);
}
