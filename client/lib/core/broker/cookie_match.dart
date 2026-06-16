/// Cookie 匹配原语（Dart 侧，Gate A · B4）—— RFC 6265 §5.1.3 domain-match /
/// §5.1.4 path-match。与 TS 侧 `server/src/runtime/broker/cookie-match.ts`
/// **语义逐字对齐**，由 `contract/golden/broker/cookie-jar.json` 共享向量钉死
/// 两端一致（ADR-001 §8）。
///
/// **不复用 `url_match.dart`**：那是 allow/scope 的 uri-template 前缀语义；cookie 的
/// 域/路径匹配是 RFC 6265 的后缀域 + 路径前缀语义，方向与含义都不同。
///
/// 仅按 domain / path 匹配——**不**校验 `Secure` / `__Host-` / cookie 属性
/// （B4 范围，见 docs/reference/b4_cookie_jar_plan.md §8 拍板 #1）。
///
/// 🔒 安全敏感（红线 #1）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _paramPlaceholder = RegExp(r'\{[^}]+\}');

/// 模板（allow / scope）解析出的 host + 字面 path 前缀。
typedef TemplateHostPath = ({String host, String pathPrefix});

/// 出站请求 URL 解析出的 host + path。
typedef UrlHostPath = ({String host, String path});

/// host 是否为 IP 字面量（IPv4 点分 或 含 `:` 的 IPv6）。IP 不参与后缀域匹配。
bool isIpLiteral(String host) {
  if (host.contains(':')) return true;
  return _ipv4.hasMatch(host);
}

/// RFC 6265 §5.1.3 domain-match：Domain=`cookieDomain` 的 cookie 是否会被发往
/// host=`host` 的请求。真当：① 相等；② `host` 以 `.cookieDomain` 结尾且 host 非 IP
/// （cookieDomain 是 host 父域）。**方向不可写反**（ADR-009 §2.4 第 123 行）。
bool domainMatch(String host, String cookieDomain) {
  final h = host.toLowerCase();
  final d = cookieDomain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (h == d) return true;
  if (isIpLiteral(h)) return false;
  return d.isNotEmpty && h.endsWith('.$d');
}

/// RFC 6265 §5.1.4 path-match：请求 path=`requestPath` 是否匹配 cookie path=`cookiePath`。
/// 真当：① 相等；② `cookiePath` 是 `requestPath` 前缀且（`cookiePath` 以 `/` 结尾，或
/// `requestPath` 在该前缀后紧跟 `/`）。
bool pathMatch(String requestPath, String cookiePath) {
  if (requestPath == cookiePath) return true;
  if (!requestPath.startsWith(cookiePath)) return false;
  if (cookiePath.endsWith('/')) return true;
  return requestPath.length > cookiePath.length &&
      requestPath[cookiePath.length] == '/';
}

/// 解析 allow / scope 模板的 host + 字面 path 前缀。去 `*` 通配、`{param}` 中性化为 `_`
/// 后用 Uri 解析。无 host → null。
TemplateHostPath? parseTemplateHostPath(String template) {
  final neutralized =
      template.replaceAll(_paramPlaceholder, '_').replaceAll('*', '');
  final u = Uri.tryParse(neutralized);
  if (u == null || u.host.isEmpty) return null;
  return (host: u.host.toLowerCase(), pathPrefix: u.path.isEmpty ? '/' : u.path);
}

/// 解析具体出站 URL 的 host + path（无 query/fragment）。无 host → null。
UrlHostPath? parseUrlHostPath(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return null;
  return (host: u.host.toLowerCase(), path: u.path.isEmpty ? '/' : u.path);
}

/// RFC 6265 §5.1.4 default-path：path 为空 / 不以 `/` 开头 → `/`；否则取最后一个 `/`
/// 前的部分，为空 → `/`。
String defaultPath(String requestPath) {
  if (!requestPath.startsWith('/')) return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  if (lastSlash <= 0) return '/';
  return requestPath.substring(0, lastSlash);
}
