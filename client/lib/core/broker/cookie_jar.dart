/// 执行内 cookie jar（Dart 侧，Gate A · B4）—— ADR-009 §2.4 / §2.8。
///
/// 与 TS 侧 `server/src/runtime/broker/cookie-jar.ts` **语义镜像**，纯决策
/// （`decideEphemeralWrite` / `matchCookieForSend` / `selectCookies`）由
/// `contract/golden/broker/cookie-jar.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 两分区严格隔离、对 adapter 全程不可见、不跨执行：
///   - **origin 区**：捕获 origin `Set-Cookie`（含重定向跳），收割权威（B5）。
///   - **ephemeral 区**：`ctx.setEphemeralCookie` 写入，四重栅栏由 Broker 强制。
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
    required this.path,
    required this.source,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final String source;
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
        'cookie': {
          'name': name,
          'value': value,
          'domain': domain,
          'path': path
        },
      };
}

/// 拒绝（fail-closed）。`reason` ∈ {domain_not_passthrough, domain_is_credential, path_too_wide}。
class EphemeralReject extends EphemeralWriteDecision {
  const EphemeralReject(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'ok': false, 'reason': reason};
}

int _sourceRank(String s) => s == 'origin' ? 1 : 0;

// 最小 public-suffix 护栏（#79 P0-4）：完整 PSL 需新依赖与更新机制；本阶段先
// fail-closed 拒绝单标签 TLD 与校园场景/常见 ccTLD 的二级公共后缀，封堵
// `dean.xjtu.edu.cn` 设置 `Domain=edu.cn` 这类过宽父域污染面。
const Set<String> _knownMultiLabelPublicSuffixes = {
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
  return _knownMultiLabelPublicSuffixes.contains(d);
}

/// cookie path 是否「等于或深于」allow path 前缀（allowPath 为其前缀）——即不更宽。
bool _pathNotWiderThan(String cookiePath, String allowPathPrefix) {
  final a =
      allowPathPrefix.endsWith('/') ? allowPathPrefix : '$allowPathPrefix/';
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

/// 单个 cookie 是否会被发往 requestUrl（RFC 6265 domain-match ∧ path-match）。
bool matchCookieForSend(
  ({String domain, String path}) cookie,
  String requestUrl,
) {
  final u = parseUrlHostPath(requestUrl);
  if (u == null) return false;
  return domainMatch(u.host, cookie.domain) && pathMatch(u.path, cookie.path);
}

/// 为出站请求选 cookie（纯）。① 过 matchCookieForSend ② 同名按来源优先级
/// （origin > ephemeral，栅栏 2）③ 稳定排序（path 长者先，同长按名）。
/// 返回 `{name,value}` 序列——**不外泄 domain/path/source**。
List<Map<String, String>> selectCookies(
  List<JarCookie> cookies,
  String requestUrl,
) {
  final byName = <String, JarCookie>{};
  for (final c in cookies) {
    if (!matchCookieForSend((domain: c.domain, path: c.path), requestUrl)) {
      continue;
    }
    final cur = byName[c.name];
    if (cur == null || _sourceRank(c.source) > _sourceRank(cur.source)) {
      byName[c.name] = c;
    }
  }
  final chosen = byName.values.toList()..sort(compareCookiePathName);
  return chosen.map((c) => {'name': c.name, 'value': c.value}).toList();
}

/// 解析单条 `Set-Cookie` 头为 JarCookie（origin 区）。缺省 domain/path 按 RFC 6265 §5.3。
JarCookie? _parseSetCookie(String header, String requestUrl) {
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
  for (final attr in parts.skip(1)) {
    final i = attr.indexOf('=');
    final key = (i == -1 ? attr : attr.substring(0, i)).trim().toLowerCase();
    final val = i == -1 ? '' : attr.substring(i + 1).trim();
    if (key == 'domain' && val.isNotEmpty) {
      domain = val.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      hasDomainAttr = true;
    } else if (key == 'path' && val.startsWith('/')) {
      path = val;
    }
    // Secure / HttpOnly / Max-Age / Expires 等本 jar 不校验（计划 §8 拍板 #1）
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
    path: path ?? defaultPath(u.path),
    source: 'origin',
  );
}

/// 有态 jar —— 随单次执行存活。两分区隔离；执行结束整体丢弃（栅栏 4：无持久化路径）。
class CookieJar {
  final List<JarCookie> _origin = [];
  final List<JarCookie> _ephemeral = [];

  /// 捕获一次响应的 `Set-Cookie`（含重定向跳）。同 (name,domain,path) 以最新值覆盖。
  void captureSetCookie(List<String> setCookieHeaders, String requestUrl) {
    for (final h in setCookieHeaders) {
      final c = _parseSetCookie(h, requestUrl);
      if (c == null) continue;
      final idx = _origin.indexWhere(
        (e) => e.name == c.name && e.domain == c.domain && e.path == c.path,
      );
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
    final entry = JarCookie(
      name: accept.name,
      value: accept.value,
      domain: accept.domain,
      path: accept.path,
      source: 'ephemeral',
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
  List<CookiePair> selectForSend(String requestUrl) =>
      selectCookies([..._origin, ..._ephemeral], requestUrl)
          .map((m) => CookiePair(m['name']!, m['value']!))
          .toList();

  /// 出站请求的 `Cookie` 头值（空则 ""）。两分区合并后过 selectCookies。
  String cookieHeader(String requestUrl) =>
      selectForSend(requestUrl).map((p) => '${p.name}=${p.value}').join('; ');

  /// 收割视图（B5 用）：**仅 origin 区**。ephemeral 区结构上不在此返回 →「永不收割」
  /// （栅栏 3）由数据流保证，非靠调用方自律。
  List<JarCookie> harvestView() => List.unmodifiable(_origin);
}
