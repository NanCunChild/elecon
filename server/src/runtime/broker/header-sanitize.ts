/**
 * Broker HTTP 头净化（Gate A · B2）—— ADR-009 §2.3（出站请求）/ §2.5（响应脱敏）。
 *
 * 出站请求：**无条件剥除** adapter 自设的凭证头（Cookie / Authorization /
 *   Proxy-Authorization），其余按 allowlist 保留、未放行丢弃。凭证仅由 broker 注入
 *   （B1 决策 + 凭证存储），adapter **永不能**经 `init.headers` 自带凭证
 *   （红线 #1；ADR-009 §2.3 + rev-3 强调「Cookie 剥除规则不松动」）。
 * 响应：按 allowlist 保留，其余一律丢弃——含 `Set-Cookie`（它由 per-execution jar 在
 *   **更上游**捕获，属 B4，绝不回交 adapter）与任何 Authorization 回显（ADR-009 §2.5）。
 *
 * 纯函数；HTTP 头名**大小写不敏感**匹配；保留被放行头的**原始大小写**。两端一致由
 * `contract/golden/broker/header-sanitize.json` 钉死（Dart 后续对齐）。
 *
 * 🔒 红线 #1 凭证边界：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

/** 规范化的头表示（host 侧把 Headers/init.headers 归一为此形再传入）。 */
export type HeaderMap = Record<string, string>;

/** 请求头 allowlist（ADR-009 §2.3 默认集）。 */
export const REQUEST_HEADER_ALLOWLIST: ReadonlySet<string> = new Set([
  "content-type",
  "accept",
  "accept-language",
]);

/**
 * 无条件剥除的凭证头（ADR-009 §2.3）。
 * **纵深防御**：deny 优先于 allowlist——即便将来误把凭证头放进 allowlist，仍被剥除。
 */
export const REQUEST_HEADER_DENYLIST: ReadonlySet<string> = new Set([
  "cookie",
  "authorization",
  "proxy-authorization",
]);

/** 响应头 allowlist（ADR-009 §2.5 默认集）。其余（含 Set-Cookie）一律丢弃。 */
export const RESPONSE_HEADER_ALLOWLIST: ReadonlySet<string> = new Set([
  "content-type",
  "content-length",
  "content-encoding",
  "date",
  "cache-control",
  "etag",
  "last-modified",
]);

/** 出站请求头净化：deny 优先剥除凭证头 → allowlist 保留 → 其余丢弃。 */
export function sanitizeRequestHeaders(headers: HeaderMap): HeaderMap {
  const out: HeaderMap = {};
  for (const [name, value] of Object.entries(headers)) {
    const key = name.toLowerCase();
    if (REQUEST_HEADER_DENYLIST.has(key)) continue; // 无条件剥除凭证头（红线 #1）
    if (REQUEST_HEADER_ALLOWLIST.has(key)) out[name] = value;
  }
  return out;
}

/** 响应头脱敏：allowlist 保留，其余（含 Set-Cookie / Authorization 回显）一律丢弃。 */
export function sanitizeResponseHeaders(headers: HeaderMap): HeaderMap {
  const out: HeaderMap = {};
  for (const [name, value] of Object.entries(headers)) {
    if (RESPONSE_HEADER_ALLOWLIST.has(name.toLowerCase())) out[name] = value;
  }
  return out;
}
