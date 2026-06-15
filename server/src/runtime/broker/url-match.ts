/**
 * Broker URL 匹配原语 —— network.allow / credentials.scope 的 uri-template 匹配。
 *
 * 与 tools 校验器（`tools/src/validator/index.ts` 的 C4/C6/C7）**必须语义一致**：
 * 校验器静态保证 scope ⊆ allow、等长重叠 scope 被拒；Broker 运行时据同一约定决定
 * 注入。二者由 `contract/golden/broker/inject-policy.json` 的共享向量钉死行为一致
 * （见 `inject-policy.smoke.ts`）。客户端（Dart `adapter_runtime.dart` 对应件）照同一
 * golden 复刻——钉死的是**行为**，不是源文件（同 ADR-001 §8 两端双跑哲学）。
 *
 * 约定（与校验器同）：白名单 / scope 为「尾随 `*` 的前缀型」模板（`https://host/path/*`），
 * `*` 是唯一通配。多段 `*` / `{+path}` 等复杂模板**不在约定内**——引入须同步重评校验器
 * C6/C7 与本模块（见 ADR-013 §2.4 与校验器文件头）。
 *
 * 🔒 安全敏感（红线 #1 注入决策路径）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
 */

/** 把 `https://h/api/*` 形态模板转成锚定正则；`*` → `.*`，其余字面转义。 */
export function allowToRegex(pattern: string): RegExp {
  const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const withWildcard = escaped.replace(/\\\*/g, ".*");
  return new RegExp("^" + withWildcard + "$");
}

/** 把具体 url 里的 `{param}` 占位中性化，避免占位符干扰匹配（与校验器同一处理）。 */
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
 * 覆盖越窄 = 越精确 = 优先级越高（与校验器 C7 同一约定）。
 */
export function scopePrefix(pattern: string): string {
  const star = pattern.indexOf("*");
  return star === -1 ? pattern : pattern.slice(0, star);
}
