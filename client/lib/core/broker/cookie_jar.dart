/// 执行内 cookie jar（Dart 侧，Gate A · B4）—— ADR-009 §2.4 / §2.8。
///
/// 与 TS 侧 `server/src/runtime/broker/cookie-jar.ts` **语义镜像**，纯决策
/// （`decideEphemeralWrite` / `parseSetCookie` / `matchCookieForSend` / `selectCookies`）由
/// `contract/golden/broker/cookie-jar.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 两分区严格隔离、对 adapter 全程不可见、不跨执行：
///   - **origin 区**：捕获 origin `Set-Cookie`（含重定向跳），收割权威（B5）。
///   - **ephemeral 区**：`ctx.setEphemeralCookie` 写入，四重栅栏由 Broker 强制。
///
/// **cookie 属性面（P1-05 / P1-06，2026-08-07）**：`Secure` 只随 https 发出；`Max-Age` /
/// `Expires` 决定生命周期（Max-Age 优先），到期不发、不收割，`Max-Age=0` / 过期 `Expires`
/// 从 jar **删除**该条；覆盖键是 `(name, domain, path)`——同名不同 Path **并存**而非折叠。
///
/// 不含 B5 收割桥接 / B6 请求拼装（划走，见计划 §1）。
///
/// 🔒 红线 #1 写入面（adapter→jar）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

import 'cookie_match.dart';
import 'inject_policy.dart';
import 'ports.dart';

/// jar 内 cookie 表示（仅 host 侧可见；adapter 永不接触）。`source` ∈ {origin, ephemeral}。
class JarCookie {
  const JarCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.hostOnly = false,
    required this.path,
    required this.source,
    this.secure = false,
    this.expiresAt,
  });

  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final String source;

  /// `Secure` 属性（P1-06）。为 true 时**只随 https 请求发出**——见 [matchCookieForSend]。
  final bool secure;

  /// 过期时刻（ms epoch）。`null` = **session cookie**（无 `Max-Age`/`Expires`，随执行
  /// 结束消亡）。已到期的 cookie 不发送、不收割，并在下次捕获时从 jar 删除。
  final int? expiresAt;

  /// 与 golden `parseSetCookie[].expected` 同形（键序无关，双跑按 Map 比较）。
  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'hostOnly': hostOnly,
    'path': path,
    'source': source,
    'secure': secure,
    'expiresAt': expiresAt,
  };
}

/// `setEphemeralCookie` 入参（契约面 `ctx.setEphemeralCookie` 的 host 侧归一形）。
class EphemeralWriteInput {
  const EphemeralWriteInput({
    required this.name,
    required this.value,
    required this.domain,
    this.path,
  });

  final String name;
  final String value;
  final String domain;
  final String? path;
}

/// 写回决策。`toJson()` 与 golden `decideEphemeralWrite[].expected` 同形。
sealed class EphemeralWriteDecision {
  const EphemeralWriteDecision();

  Map<String, Object?> toJson();
}

/// 接受：写入 ephemeral 区。
class EphemeralAccept extends EphemeralWriteDecision {
  const EphemeralAccept({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
  });

  final String name;
  final String value;
  final String domain;
  final String path;

  @override
  Map<String, Object?> toJson() => {
    'ok': true,
    'cookie': {'name': name, 'value': value, 'domain': domain, 'path': path},
  };
}

/// 拒绝（fail-closed）。`reason` ∈ {domain_not_passthrough, domain_is_credential, path_too_wide}。
class EphemeralReject extends EphemeralWriteDecision {
  const EphemeralReject(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'ok': false, 'reason': reason};
}

/// 最小 public-suffix 护栏（#79 P0-4）：完整 PSL 需新依赖与更新机制；本阶段先
/// fail-closed 拒绝单标签 TLD 与校园场景/常见 ccTLD 的二级公共后缀，封堵
/// `dean.xjtu.edu.cn` 设置 `Domain=edu.cn` 这类过宽父域污染面。
///
/// 单一事实源在 `contract/broker/public-suffixes.json`（TS 侧运行时直接加载）；
/// 客户端运行时无仓库文件，故此处为编译期常量，由
/// `test/broker_cookie_jar_test.dart` 与 contract JSON 做集合相等断言钉死——
/// 单边增删条目即 CI 红。公开仅为供该测试比对，非 API 面。
const Set<String> knownMultiLabelPublicSuffixes = {
  'ac.cn',
  'com.cn',
  'edu.cn',
  'gov.cn',
  'net.cn',
  'org.cn',
  'ac.uk',
  'co.uk',
  'gov.uk',
  'org.uk',
  'ac.jp',
  'co.jp',
  'go.jp',
  'ne.jp',
  'or.jp',
  'com.au',
  'edu.au',
  'gov.au',
  'net.au',
  'org.au',
};

bool _isPublicSuffixLike(String domain) {
  final d = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (d.isEmpty || !d.contains('.')) return true;
  return knownMultiLabelPublicSuffixes.contains(d);
}

/// cookie path 是否「等于或深于」allow path 前缀（allowPath 为其前缀）——即不更宽。
bool _pathNotWiderThan(String cookiePath, String allowPathPrefix) {
  final a = allowPathPrefix.endsWith('/')
      ? allowPathPrefix
      : '$allowPathPrefix/';
  final c = cookiePath.endsWith('/') ? cookiePath : '$cookiePath/';
  return c.startsWith(a);
}

/// 四重栅栏之栅栏 1（写入校验，ADR-009 §2.4 第 143 行）。fail-closed：
///   1.2 先查——domain 与**任何** credentials.scope 域有 domain-match 关系（双向）→ 拒；
///   1.1 ——domain 须 domain-match **某** allow 条目 host；
///   1.3 ——该 allow 条目 path 须是 cookie path 前缀（不更宽）；path 缺省 `/`。
EphemeralWriteDecision decideEphemeralWrite(
  EphemeralWriteInput input,
  BrokerManifestView view,
) {
  final domain = input.domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  final path = input.path ?? '/';

  // 栅栏 1.2：永不写凭证域（双向 domain-match，fail-closed 优先）。
  for (final decl in view.credentials.values) {
    for (final scope in decl.scope) {
      final p = parseTemplateHostPath(scope);
      if (p == null) continue;
      if (domainMatch(p.host, domain) || domainMatch(domain, p.host)) {
        return const EphemeralReject('domain_is_credential');
      }
    }
  }

  // 栅栏 1.1 + 1.3：须存在某 allow 条目，domain 可发往其 host 且 path 不更宽。
  var domainOk = false;
  for (final a in view.allow) {
    final p = parseTemplateHostPath(a);
    if (p == null) continue;
    if (!domainMatch(p.host, domain)) continue;
    domainOk = true;
    if (_pathNotWiderThan(path, p.pathPrefix)) {
      return EphemeralAccept(
        name: input.name,
        value: input.value,
        domain: domain,
        path: path,
      );
    }
  }
  return EphemeralReject(domainOk ? 'path_too_wide' : 'domain_not_passthrough');
}

/// RFC 6265 §5.4 排序（path 长者先，同长按名升序）+ 确定性 tie-break（domain、value 升序）。
/// tie-break 使比较器成为 total order：同名同 path 不同 domain 的 cookie（harvest 可同时命中）
/// 在不稳定 sort 实现（Dart List.sort 不保证稳定）间、以及 TS/Dart 双实现间序一致。
int compareCookiePathName(JarCookie a, JarCookie b) {
  final byLen = b.path.length - a.path.length;
  if (byLen != 0) return byLen;
  final byName = a.name.compareTo(b.name);
  if (byName != 0) return byName;
  final byDomain = a.domain.compareTo(b.domain);
  if (byDomain != 0) return byDomain;
  return a.value.compareTo(b.value);
}

/// 到期判据的单一事实源：`null` = session cookie，永不因时间失效。
bool isExpired(int? expiresAt, int nowMs) =>
    expiresAt != null && expiresAt <= nowMs;

/// 单个 cookie 是否会被发往 requestUrl —— RFC 6265 §5.4 的四条判据全过才为真：
///   ① domain-match（hostOnly 时须精确等于响应 host）；
///   ② path-match；
///   ③ **`Secure` ⟹ 请求 scheme 必须是 https**（P1-06；http/其它一律不发。刻意不给
///      `http://localhost` 开浏览器式「可信本地源」豁免——校园场景无此需求，放宽只会
///      给明文回落留缺口）；
///   ④ **未过期**：`expiresAt != null && expiresAt <= nowMs` ⟹ 不发（P1-06）。
///
/// [nowMs] **必填**，不设缺省：缺省值只会在某个调用点悄悄退化成「永不过期」。
bool matchCookieForSend(JarCookie cookie, String requestUrl, int nowMs) {
  final u = parseUrlHostPath(requestUrl);
  if (u == null) return false;
  if (cookie.secure && u.scheme != 'https') return false;
  if (isExpired(cookie.expiresAt, nowMs)) return false;
  final domainMatches = cookie.hostOnly
      ? u.host == cookie.domain
      : domainMatch(u.host, cookie.domain);
  return domainMatches && pathMatch(u.path, cookie.path);
}

/// 为出站请求选 cookie（纯）。
///   ① 过 [matchCookieForSend]（domain/path/Secure/过期）；
///   ② 栅栏 2（ADR-009 §2.4）——**某名字只要有任一 origin cookie 命中，该名下的
///      ephemeral cookie 全部丢弃**。ephemeral 永不能遮盖或「补充」origin 会话名；
///   ③ 同 `(name,domain,path)` 去重（jar 内已唯一，纯函数侧再兜一层）；
///   ④ 排序：path 长者先（RFC 6265 §5.4），同长按名、domain、value 升序。
///
/// **P1-05（同名不同 Path 不再折叠）**：此前按 `name` 收进 Map，`sid=/` 与 `sid=/api`
/// 只活一条——与浏览器行为不符，且会**静默丢失**深路径下的会话态。现按浏览器语义
/// **全部带上**，长 Path 在前；栅栏 2 的信任边界改由「按名压制 ephemeral」表达。
///
/// 返回 `{name,value}` 序列——**不外泄 domain/path/source/secure/expiresAt**。
List<Map<String, String>> selectCookies(
  List<JarCookie> cookies,
  String requestUrl,
  int nowMs,
) {
  final matched = cookies
      .where((c) => matchCookieForSend(c, requestUrl, nowMs))
      .toList();
  // 栅栏 2 的判据是「本次请求实际命中的 origin 名字集」——不是全 jar 的 origin 名字：
  // 一条 path/域/过期上不参与本请求的 origin cookie，不该连带压掉可用的 ephemeral。
  final originNames = matched
      .where((c) => c.source == 'origin')
      .map((c) => c.name)
      .toSet();
  final seen = <String>{};
  final kept = <JarCookie>[];
  for (final c in matched) {
    if (c.source == 'ephemeral' && originNames.contains(c.name)) {
      continue; // 栅栏 2
    }
    if (!seen.add('${c.name} ${c.domain} ${c.path}')) continue;
    kept.add(c);
  }
  kept.sort(compareCookiePathName);
  return kept.map((c) => {'name': c.name, 'value': c.value}).toList();
}

/// 解析单条 `Set-Cookie` 头为 JarCookie（origin 区）。缺省 domain/path 按 RFC 6265 §5.3；
/// `Secure` / `Max-Age` / `Expires` 按 §5.2.1–§5.2.5 解析（P1-06）。
///
/// 生命周期（§5.2.2 优先级）：**`Max-Age` 压过 `Expires`**；两者皆无/皆非法 ⟹ session
/// cookie（`expiresAt: null`）。`Max-Age=0`、负 `Max-Age`、过去的 `Expires` 都产出一个
/// 已过期的 `expiresAt`——由 [CookieJar.captureSetCookie] 翻译成**删除**语义。
///
/// 公开仅为 golden 双跑（`parseSetCookie` 组）钉两端一致，不是 adapter 可见面。
JarCookie? parseSetCookie(String header, String requestUrl, int nowMs) {
  final u = parseUrlHostPath(requestUrl);
  if (u == null) return null;
  final parts = header.split(';');
  final first = parts.isEmpty ? '' : parts.first;
  final eq = first.indexOf('=');
  if (eq <= 0) return null;
  final name = first.substring(0, eq).trim();
  final value = first.substring(eq + 1).trim();
  if (name.isEmpty) return null;

  var domain = u.host; // 缺省 host-only
  var hasDomainAttr = false;
  String? path;
  var secure = false;
  int? maxAgeExpiry;
  int? expiresExpiry;
  for (final attr in parts.skip(1)) {
    final i = attr.indexOf('=');
    final key = (i == -1 ? attr : attr.substring(0, i)).trim().toLowerCase();
    final val = i == -1 ? '' : attr.substring(i + 1).trim();
    if (key == 'domain' && val.isNotEmpty) {
      domain = val.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      hasDomainAttr = true;
    } else if (key == 'path' && val.startsWith('/')) {
      path = val;
    } else if (key == 'secure') {
      // §5.2.5：属性名出现即置位，值被忽略（`Secure` 与 `Secure=xxx` 同义）。
      secure = true;
    } else if (key == 'max-age') {
      final delta = parseMaxAge(val);
      if (delta != null) maxAgeExpiry = expiryFromMaxAge(delta, nowMs);
    } else if (key == 'expires') {
      // 非法日期 ⟹ 忽略该属性（§5.2.1），退化为 session——**不是**立刻过期。
      expiresExpiry = parseCookieDate(val);
    }
    // HttpOnly 无意义：本 jar 不暴露给任何脚本环境（adapter 全程看不到 cookie）。
  }
  // RFC 6265 §5.3 step 6（#79 P0-4）：显式 Domain 属性必须 domain-match 响应 host，
  // 且不得是 public suffix / 过宽父域；否则整条 Set-Cookie **丢弃**（fail-closed）。
  // 封堵「allow 集内某 host 为不属于自己的域或过宽父域伪造 cookie、经后续请求发往
  // 他域」的污染面。缺省 host-only（无 Domain 属性）不受限。
  if (hasDomainAttr &&
      (!domainMatch(u.host, domain) || _isPublicSuffixLike(domain))) {
    return null;
  }
  return JarCookie(
    name: name,
    value: value,
    domain: domain,
    hostOnly: !hasDomainAttr,
    path: path ?? defaultPath(u.path),
    source: 'origin',
    secure: secure,
    expiresAt: maxAgeExpiry ?? expiresExpiry, // Max-Age 优先（§5.2.2）
  );
}

/// 有态 jar —— 随单次执行存活。两分区隔离；执行结束整体丢弃（栅栏 4：无持久化路径）。
class CookieJar {
  /// [now] 可注入仅为测试可确定化；生产恒 `DateTime.now()`。
  CookieJar([int Function()? now])
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final List<JarCookie> _origin = [];
  final List<JarCookie> _ephemeral = [];
  final int Function() _now;

  /// 捕获一次响应的 `Set-Cookie`（含重定向跳）。
  ///
  /// 覆盖键 = `(name, domain, path)`（RFC 6265 §5.3 step 11）：**同名 + 同域 + 同 Path
  /// 新值替换旧值**（会话轮换）；`name` 相同但 Path 不同 ⟹ **两条并存**，各自独立
  /// （P1-05——此前折叠导致深路径 cookie 被根路径同名覆盖而丢失）。
  ///
  /// **删除语义（P1-06）**：解析出的 cookie 若已过期（`Max-Age=0`、负 `Max-Age`、
  /// 过去的 `Expires`），不入 jar，并把 jar 内同 `(name,domain,path)` 的旧条目**删掉**
  /// ——这是 origin 主动登出/失效会话的唯一表达方式，必须真删而非留一条死 cookie。
  void captureSetCookie(List<String> setCookieHeaders, String requestUrl) {
    for (final h in setCookieHeaders) {
      final now = _now();
      final c = parseSetCookie(h, requestUrl, now);
      if (c == null) continue;
      final idx = _origin.indexWhere(
        (e) => e.name == c.name && e.domain == c.domain && e.path == c.path,
      );
      if (isExpired(c.expiresAt, now)) {
        // 删除语义：Max-Age=0 / 过期 Expires
        if (idx >= 0) _origin.removeAt(idx);
        continue;
      }
      if (idx >= 0) {
        _origin[idx] = c;
      } else {
        _origin.add(c);
      }
    }
  }

  /// adapter 经 `ctx.setEphemeralCookie` 写入。过栅栏 1；**违例静默丢弃 + warn**
  /// （拍板 #3，不抛错）。返回是否实际写入（供测试断言；adapter 侧拿不到此返回）。
  bool writeEphemeral(
    EphemeralWriteInput input,
    BrokerManifestView view,
    void Function(String message) warn,
  ) {
    final d = decideEphemeralWrite(input, view);
    if (d is EphemeralReject) {
      warn(
        'setEphemeralCookie 被拒（${d.reason}）：name=${input.name} domain=${input.domain}',
      );
      return false;
    }
    final accept = d as EphemeralAccept;
    // ephemeral 恒为 session、恒非 Secure：adapter 不得给自己写的 cookie 设生命周期或
    // 传输限制——那是 origin 属性面，ephemeral 只在本次执行内存活（栅栏 4）。
    final entry = JarCookie(
      name: accept.name,
      value: accept.value,
      domain: accept.domain,
      hostOnly: false,
      path: accept.path,
      source: 'ephemeral',
      secure: false,
      expiresAt: null,
    );
    final idx = _ephemeral.indexWhere(
      (e) =>
          e.name == entry.name &&
          e.domain == entry.domain &&
          e.path == entry.path,
    );
    if (idx >= 0) {
      _ephemeral[idx] = entry;
    } else {
      _ephemeral.add(entry);
    }
    return true;
  }

  /// 出站请求选 cookie 对（两分区合并 + selectCookies；origin>ephemeral 已落实）。
  /// B6 拼装（assemble）在此输出之上叠加 broker 注入凭证（broker>origin>ephemeral）。
  /// 返回 typed `CookiePair`（不外泄 domain/path/source；与 TS selectForSend 的 `{name,value}` 对齐）。
  List<CookiePair> selectForSend(String requestUrl) => selectCookies([
    ..._origin,
    ..._ephemeral,
  ], requestUrl, _now()).map((m) => CookiePair(m['name']!, m['value']!)).toList();

  /// 出站请求的 `Cookie` 头值（空则 ""）。两分区合并后过 selectCookies。
  String cookieHeader(String requestUrl) =>
      selectForSend(requestUrl).map((p) => '${p.name}=${p.value}').join('; ');

  /// 收割视图（B5 用）：**仅 origin 区**。ephemeral 区结构上不在此返回 →「永不收割」
  /// （栅栏 3）由数据流保证，非靠调用方自律。
  ///
  /// 同时**滤掉已过期条目**（P1-06）：捕获时的删除只在「又收到一条 Set-Cookie」时触发，
  /// 一条在捕获后自然到点的 cookie 仍会留在 origin 区；收割是它进入持久凭证库的入口，
  /// 故在此按当前时钟再滤一次，绝不把死会话写进 Store。
  List<JarCookie> harvestView() {
    final now = _now();
    return List.unmodifiable(
      _origin.where((c) => !isExpired(c.expiresAt, now)),
    );
  }
}
