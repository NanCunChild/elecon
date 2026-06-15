/// Broker URL 匹配原语（Dart 侧）—— network.allow / credentials.scope 的 uri-template 匹配。
///
/// 与 TS 侧 `server/src/runtime/broker/url-match.ts` **语义逐字对齐**（含正则转义集合），
/// 并与 tools 校验器（C4/C6/C7）同约定。三方行为由
/// `contract/golden/broker/inject-policy.json` 的共享向量钉死（见
/// `test/broker_inject_policy_test.dart`）——钉死的是**行为**，不是源文件
/// （ADR-001 §8 两端双跑哲学）。
///
/// 约定：白名单 / scope 为「尾随 `*` 的前缀型」模板（`https://host/path/*`），`*` 为唯一
/// 通配。多段 `*` / `{+path}` 不在约定内——引入须同步重评校验器 C6/C7 与本模块
/// （见 ADR-013 §2.4）。
///
/// 🔒 安全敏感（红线 #1 注入决策路径）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

/// 转义正则元字符——字符集与 TS `url-match.ts` 完全一致：`. * + ? ^ $ { } ( ) | [ ] \`。
final RegExp _metaChars = RegExp(r'[.*+?^${}()|[\]\\]');

/// 具体 url 里的 `{param}` 占位中性化，避免占位符干扰匹配（与 TS / 校验器同一处理）。
final RegExp _paramPlaceholder = RegExp(r'\{[^}]+\}');

String _concretize(String url) => url.replaceAll(_paramPlaceholder, '_');

/// 把 `https://h/api/*` 形态模板转成锚定正则；`*` → `.*`，其余字面转义。
RegExp allowToRegex(String pattern) {
  final escaped = pattern.replaceAllMapped(_metaChars, (m) => '\\${m[0]}');
  final withWildcard = escaped.replaceAll(r'\*', '.*');
  return RegExp('^$withWildcard\$');
}

/// 具体 url 是否被某白名单项覆盖（fail-closed 出口判定）。
bool urlCoveredByAllow(String url, List<String> allow) {
  final concrete = _concretize(url);
  return allow.any((p) => allowToRegex(p).hasMatch(concrete));
}

/// 单个 scope 模式是否命中具体 url（与 allow 同一匹配语义）。
bool scopeMatches(String url, String pattern) =>
    allowToRegex(pattern).hasMatch(_concretize(url));

/// 取模板第一个 `*` 前的字面前缀（无 `*` 取全串）。用于最长前缀消歧——前缀越长 =
/// 覆盖越窄 = 越精确 = 优先级越高（与校验器 C7 同一约定）。
String scopePrefix(String pattern) {
  final star = pattern.indexOf('*');
  return star == -1 ? pattern : pattern.substring(0, star);
}
