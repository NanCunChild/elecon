/// Broker HTTP 头净化（Gate A · B2，Dart 侧）—— ADR-009 §2.3（请求）/ §2.5（响应）。
///
/// 与 TS 侧 `server/src/runtime/broker/header-sanitize.ts` **语义对齐**，由
/// `contract/golden/broker/header-sanitize.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 出站请求：无条件剥除 Cookie/Authorization/Proxy-Authorization（deny 优先于 allowlist，
///   纵深防御）+ 其余按 allowlist 保留；adapter 永不能经 init.headers 自带凭证（红线 #1）。
/// 响应：按 allowlist 保留，其余（含 Set-Cookie / Authorization 回显）一律丢弃。
/// 头名大小写不敏感匹配；保留被放行头的原始大小写。
///
/// 🔒 红线 #1 凭证边界：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

/// 请求头 allowlist（ADR-009 §2.3 默认集）。
const Set<String> requestHeaderAllowlist = {
  'content-type',
  'accept',
  'accept-language',
};

/// 无条件剥除的凭证头（ADR-009 §2.3）。deny 优先于 allowlist（纵深防御）。
const Set<String> requestHeaderDenylist = {
  'cookie',
  'authorization',
  'proxy-authorization',
};

/// 响应头 allowlist（ADR-009 §2.5 默认集）。其余（含 Set-Cookie）一律丢弃。
const Set<String> responseHeaderAllowlist = {
  'content-type',
  'content-length',
  'content-encoding',
  'date',
  'cache-control',
  'etag',
  'last-modified',
};

/// 出站请求头净化：deny 优先剥除凭证头 → allowlist 保留 → 其余丢弃。
Map<String, String> sanitizeRequestHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  headers.forEach((name, value) {
    final key = name.toLowerCase();
    if (requestHeaderDenylist.contains(key)) return; // 无条件剥除凭证头（红线 #1）
    if (requestHeaderAllowlist.contains(key)) out[name] = value;
  });
  return out;
}

/// 响应头脱敏：allowlist 保留，其余（含 Set-Cookie / Authorization 回显）一律丢弃。
Map<String, String> sanitizeResponseHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  headers.forEach((name, value) {
    if (responseHeaderAllowlist.contains(name.toLowerCase())) out[name] = value;
  });
  return out;
}
