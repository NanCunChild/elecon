/// Cookie 匹配原语（Dart 侧，Gate A · B4）—— RFC 6265 §5.1.3 domain-match /
/// §5.1.4 path-match。与 TS 侧 `server/src/runtime/broker/cookie-match.ts`
/// **语义逐字对齐**，由 `contract/golden/broker/cookie-jar.json` 共享向量钉死
/// 两端一致（ADR-001 §8）。
///
/// **不复用 `url_match.dart`**：那是 allow/scope 的 uri-template 前缀语义；cookie 的
/// 域/路径匹配是 RFC 6265 的后缀域 + 路径前缀语义，方向与含义都不同。
///
/// 本模块提供 domain / path 匹配 + **cookie 属性解析原语**（`Secure` 由 [parseUrlHostPath]
/// 暴露的 scheme 判定；生命周期由 [parseCookieDate] / [parseMaxAge]）。`__Host-` /
/// `__Secure-` 前缀仍不校验（B4 范围，见 docs/reference/b4_cookie_jar_plan.md §8 拍板 #1）。
///
/// 🔒 安全敏感（红线 #1）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _paramPlaceholder = RegExp(r'\{[^}]+\}');

/// 模板（allow / scope）解析出的 host + 字面 path 前缀。
typedef TemplateHostPath = ({String host, String pathPrefix});

/// 出站请求 URL 解析出的 scheme + host + path。`scheme` 小写、不含 `:`，是
/// `Secure` cookie 的发送判据。
typedef UrlHostPath = ({String host, String path, String scheme});

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

/// 解析具体出站 URL 的 scheme + host + path（无 query/fragment）。无 host → null。
UrlHostPath? parseUrlHostPath(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return null;
  return (
    host: u.host.toLowerCase(),
    path: u.path.isEmpty ? '/' : u.path,
    scheme: u.scheme.toLowerCase(),
  );
}

/// RFC 6265 §5.1.4 default-path：path 为空 / 不以 `/` 开头 → `/`；否则取最后一个 `/`
/// 前的部分，为空 → `/`。
String defaultPath(String requestPath) {
  if (!requestPath.startsWith('/')) return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  if (lastSlash <= 0) return '/';
  return requestPath.substring(0, lastSlash);
}

/// cookie 过期时刻的可表示上界（ms epoch，= JS `Date` 的最大值 ±8.64e15）。
///
/// 存在理由是**跨端确定性**：`Max-Age=<30 位数字>` 在 JS 里是有限 float、在 Dart 里溢出
/// 64 位 int，直接算会两端分叉。故一切换算先夹到本上界，两端得同一个「远期」时刻。
const int maxCookieExpiryMs = 8640000000000000;

/// `Max-Age` 的 delta-seconds 夹取上界（10^18，绝对值超此按上界处理；见 [parseMaxAge]）。
const int _maxDeltaSeconds = 1000000000000000000;

const List<String> _months = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

final RegExp _timeToken = RegExp(r'^(\d{1,2}):(\d{1,2}):(\d{1,2})(?!\d)');
final RegExp _dayToken = RegExp(r'^(\d{1,2})(?!\d)');
final RegExp _yearToken = RegExp(r'^(\d{2,4})(?!\d)');
final RegExp _digitsOnly = RegExp(r'^\d+$');
final RegExp _leadingZeros = RegExp(r'^0+(?=\d)');

/// RFC 6265 §5.1.1 date-token 分隔符：%x09 / %x20-2F / %x3B-40 / %x5B-60 / %x7B-7E。
/// 注意 `:`（%x3A）**不是**分隔符——时间 `hh:mm:ss` 须留在同一 token 内。
bool _isCookieDateDelimiter(int code) =>
    code == 0x09 ||
    (code >= 0x20 && code <= 0x2f) ||
    (code >= 0x3b && code <= 0x40) ||
    (code >= 0x5b && code <= 0x60) ||
    (code >= 0x7b && code <= 0x7e);

/// 按 §5.1.1 分隔符切 date-token，丢弃空段。
List<String> _splitCookieDateTokens(String value) {
  final tokens = <String>[];
  final buf = StringBuffer();
  for (final rune in value.runes) {
    if (rune < 0x80 && _isCookieDateDelimiter(rune)) {
      if (buf.isNotEmpty) tokens.add(buf.toString());
      buf.clear();
    } else {
      buf.writeCharCode(rune);
    }
  }
  if (buf.isNotEmpty) tokens.add(buf.toString());
  return tokens;
}

/// 解析 `Expires` 属性值为 ms epoch（RFC 6265 §5.1.1 的**逐 token 算法**，非依赖宿主
/// `DateTime.parse`）。返回 null = 该属性不可解析 ⟹ **整条属性忽略**（cookie 退化为
/// session，§5.2.1），不是「立刻过期」。
///
/// 为什么自己写：`DateTime.parse`（Dart）与 `Date.parse`（JS）对 RFC 850 两位年、asctime
/// 无时区、非法日期 rollover 的处理各不相同——照抄宿主即两端语义漂移。本算法逐 token、
/// 与宿主日历实现无关，两端逐字镜像，并由 `contract/golden/broker/cookie-jar.json`
/// 的 `parseCookieDate` 组钉死。
///
/// 与 RFC 一致的刻意行为：年 70–99 ⟹ +1900，0–69 ⟹ +2000；年 < 1601 判失败；
/// 日 1–31 之外判失败（**但** 2 月 31 日这类「合法数字、非法日历日」按宿主日历自然进位，
/// 两端一致，golden 有例）。
int? parseCookieDate(String value) {
  var foundTime = false;
  var foundDay = false;
  var foundMonth = false;
  var foundYear = false;
  var hour = 0;
  var minute = 0;
  var second = 0;
  var day = 0;
  var month = 0;
  var year = 0;

  for (final token in _splitCookieDateTokens(value)) {
    if (!foundTime) {
      final t = _timeToken.firstMatch(token);
      if (t != null) {
        foundTime = true;
        hour = int.parse(t.group(1)!);
        minute = int.parse(t.group(2)!);
        second = int.parse(t.group(3)!);
        continue;
      }
    }
    if (!foundDay) {
      final d = _dayToken.firstMatch(token);
      if (d != null) {
        foundDay = true;
        day = int.parse(d.group(1)!);
        continue;
      }
    }
    if (!foundMonth) {
      final head = token.length >= 3 ? token.substring(0, 3) : token;
      final idx = _months.indexOf(head.toLowerCase());
      if (idx >= 0) {
        foundMonth = true;
        month = idx + 1;
        continue;
      }
    }
    if (!foundYear) {
      final y = _yearToken.firstMatch(token);
      if (y != null) {
        foundYear = true;
        year = int.parse(y.group(1)!);
        continue;
      }
    }
  }

  if (year >= 70 && year <= 99) {
    year += 1900;
  } else if (year >= 0 && year <= 69) {
    year += 2000;
  }

  if (!foundTime || !foundDay || !foundMonth || !foundYear) return null;
  if (day < 1 || day > 31) return null;
  if (year < 1601) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  return DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
  ).millisecondsSinceEpoch;
}

/// 解析 `Max-Age` 属性值为 delta-seconds（RFC 6265 §5.2.2）。返回 null = 属性非法
/// ⟹ **忽略该属性**（不是「立刻过期」）。
///
/// §5.2.2 原文：首字符须是 DIGIT 或 `-`，其余须全是 DIGIT，否则忽略整条属性。
/// 结果 ≤ 0 ⟹ 调用方按「最早可表示时刻」处理（即立刻过期 ⟹ 删除该 cookie）。
///
/// 位数超 18 时夹到 ±10^18：防 JS（有限 float）与 Dart（int 溢出）在超长数字上分叉。
int? parseMaxAge(String value) {
  final s = value.trim();
  if (s.isEmpty) return null;
  final negative = s.startsWith('-');
  final digits = negative ? s.substring(1) : s;
  if (digits.isEmpty || !_digitsOnly.hasMatch(digits)) return null;
  final trimmed = digits.replaceFirst(_leadingZeros, '');
  final magnitude = trimmed.length > 18
      ? _maxDeltaSeconds
      : int.parse(trimmed);
  return negative ? -magnitude : magnitude;
}

/// 由 `Max-Age` delta-seconds 与 `now` 算过期时刻（ms epoch），夹到 [maxCookieExpiryMs]。
int expiryFromMaxAge(int deltaSeconds, int nowMs) {
  if (deltaSeconds <= 0) return -maxCookieExpiryMs; // 最早可表示时刻 ⟹ 立刻过期
  // 先夹 delta 再乘，避免 64 位溢出把远期算成负数（TS 侧是 float 无此风险，故此处
  // 多一步；结果与 TS 的「乘完再夹」在夹取上界处一致）。
  if (deltaSeconds > maxCookieExpiryMs ~/ 1000) return maxCookieExpiryMs;
  final ms = nowMs + deltaSeconds * 1000;
  return ms > maxCookieExpiryMs ? maxCookieExpiryMs : ms;
}
