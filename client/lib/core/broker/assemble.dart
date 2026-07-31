/// Broker 请求拼装 / 响应脱敏（Gate A · B6a 的 Dart 镜像 = B6c）—— ADR-009 §2.1。
///
/// 与 TS 侧 `server/src/runtime/broker/assemble.ts` **语义对齐**，由
/// `contract/golden/broker/assemble.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 纯函数：入参为已算好的 decision（B1）+ resolved 凭证值（resolver）+ jarCookies（B4
/// selectCookies），不发请求、不碰 async、不碰 jar 内部态。有态驱动（decideInjection→
/// resolver.get→selectForSend→transport→redirect→capture）属运行时接线（B6b，
/// `adapter_runtime.dart`），不在本镜像。
///
/// **拼装次序（安全要点，同 TS）**：
///   ① sanitizeRequestHeaders 先剥 adapter 自设 Cookie/Authorization（纵深防御，红线 #1）。
///   ② broker 凭证在净化后底座之上叠加（颠倒则被 §① denylist 剥掉）。
///   ③ Cookie 合流 broker 注入 > origin > ephemeral（jar 内 origin>ephemeral 已由 selectCookies 落实）。
///
/// 🔒 红线 #1 凭证注入承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'header_sanitize.dart';
import 'inject_policy.dart';
import 'ports.dart';

export 'ports.dart' show ResolvedCredential, CookiePair;

/// adapter 经 `ctx.fetch(url, init)` 传入的请求意图（host 侧已把 headers 归一）。
class RequestInit {
  const RequestInit({this.method, this.headers, this.body});

  final String? method;
  final Map<String, String>? headers;
  final String? body;
}

class AssembleRequestInput {
  const AssembleRequestInput({
    this.url,
    required this.init,
    required this.decision,
    required this.resolved,
    required this.jarCookies,
  });

  /// 仅 query credential 注入需要；旧 cookie/header golden 可缺省。
  final String? url;

  final RequestInit init;

  /// B1 decideInjection(url, view) 的结果。
  final InjectionDecision decision;

  /// resolver.get(ref) 的结果；仅 inject 时有值。null = 非 inject 或凭证缺失/失效。
  final ResolvedCredential? resolved;

  /// B4 `jar.selectForSend(url)` 的输出（origin+ephemeral 已合并去重）。
  final List<CookiePair> jarCookies;
}

/// 拼装结果。`toJson()` 与 `contract/golden/broker/assemble.json` 的 `expected` 同形。
sealed class AssembleResult {
  const AssembleResult();

  Map<String, Object?> toJson();
}

/// url 不在 allow（B1 reject）→ fail-closed，凭证一律不附。
class RejectResult extends AssembleResult {
  const RejectResult(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'kind': 'reject', 'reason': reason};
}

class OkResult extends AssembleResult {
  const OkResult({
    required this.method,
    required this.headers,
    this.body,
    this.url,
  });

  final String method;
  final Map<String, String> headers;
  final String? body;
  final String? url;

  @override
  Map<String, Object?> toJson() {
    final m = <String, Object?>{
      'kind': 'ok',
      'method': method,
      'headers': headers,
    };
    if (body != null) m['body'] = body;
    if (url != null) m['url'] = url;
    return m;
  }
}

/// 解析序列化 cookie 串（`A=1; B=2`）为有序对。空段/无 `=` 段跳过。
List<CookiePair> _parseCookieString(String s) {
  final out = <CookiePair>[];
  for (final seg in s.split(';')) {
    final part = seg.trim();
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    out.add(
      CookiePair(part.substring(0, eq).trim(), part.substring(eq + 1).trim()),
    );
  }
  return out;
}

/// 拼装出站请求（纯）。语义见文件头与 TS `assembleRequest`。
///
/// **凭证缺失（inject 但 resolved==null）→ fail-closed（reject `credential_unavailable`）。**
/// B1 判 inject = manifest 显式声明该 URL 需登录态；凭证取不到却照发只会换回 401/登录
/// 重定向，拿不到正确数据还把「过期/吊销/未登录」压成模糊 401。故拒发，给宿主确定信号 →
/// 触发 ADR-012 §2.5 续期 / §2.2 重登。不发凭证永不泄露（红线 #1），此为健壮性裁定。
/// （2026-06-18 人工采纳 fail-closed；此前为「不伪造 + 照发」。与 TS assemble.ts 对齐。）
AssembleResult assembleRequest(AssembleRequestInput input) {
  final decision = input.decision;
  if (decision is RejectDecision) {
    return RejectResult(decision.reason);
  }

  // 凭证缺失 fail-closed：声明要注入但 resolver 未命中 → 拒发（见上方文档）。
  if (decision is InjectDecision && input.resolved == null) {
    return const RejectResult('credential_unavailable');
  }
  if (decision is InjectDecision &&
      input.resolved != null &&
      input.resolved!.via != decision.via) {
    return const RejectResult('credential_type_mismatch');
  }

  // ① 净化 adapter 自设头。
  final headers = sanitizeRequestHeaders(input.init.headers ?? const {});

  // ② broker 凭证在干净底座上叠加（仅 inject 且 resolver 命中）。
  var injectCookie = const <CookiePair>[];
  if (decision is InjectDecision &&
      decision.via == 'cookie' &&
      input.resolved != null) {
    injectCookie = _parseCookieString(input.resolved!.value);
  }
  if (decision is InjectDecision &&
      decision.via == 'header' &&
      input.resolved != null) {
    // ADR-029 §2.1 命名 header：缺省 Authorization，可由已验签 headerName 指定。
    // 先按名（大小写不敏感）剥除 adapter 自设同名头，再由 broker 注入其值——即便该头名
    // 落在请求 allowlist 内（如 content-type）也不让 adapter 值残留（纵深防御）。
    final headerName = decision.headerName ?? 'Authorization';
    final wanted = headerName.toLowerCase();
    headers.removeWhere((key, _) => key.toLowerCase() == wanted);
    headers[headerName] = input.resolved!.value;
  }

  var url = input.url;
  if (decision is InjectDecision &&
      decision.via == 'query' &&
      input.resolved != null) {
    if (url == null || decision.queryParam == null) {
      return const RejectResult('invalid_url');
    }
    url = _injectQueryParam(url, decision.queryParam!, input.resolved!.value);
  }

  // ③ Cookie 合流：broker 注入名优先，其后补 jar。
  final seen = <String>{};
  final cookiePairs = <CookiePair>[];
  for (final p in injectCookie) {
    if (seen.add(p.name)) cookiePairs.add(p);
  }
  for (final p in input.jarCookies) {
    if (seen.add(p.name)) cookiePairs.add(p);
  }
  if (cookiePairs.isNotEmpty) {
    headers['Cookie'] = cookiePairs
        .map((p) => '${p.name}=${p.value}')
        .join('; ');
  }

  final method = (input.init.method ?? 'GET').toUpperCase();
  return OkResult(
    method: method,
    headers: headers,
    body: input.init.body,
    url: url,
  );
}

/// 覆盖全部同名参数后追加唯一凭证参数；仅 query 注入分支调用，不改写普通 URL。
String _injectQueryParam(String url, String name, String value) {
  final hashAt = url.indexOf('#');
  final fragment = hashAt >= 0 ? url.substring(hashAt) : '';
  final withoutFragment = hashAt >= 0 ? url.substring(0, hashAt) : url;
  final queryAt = withoutFragment.indexOf('?');
  final base = queryAt >= 0
      ? withoutFragment.substring(0, queryAt)
      : withoutFragment;
  final rawQuery = queryAt >= 0 ? withoutFragment.substring(queryAt + 1) : '';
  final kept = rawQuery.isEmpty
      ? <String>[]
      : rawQuery.split('&').where((part) => _queryKey(part) != name).toList();
  kept.add('${Uri.encodeComponent(name)}=${Uri.encodeComponent(value)}');
  return '$base?${kept.join('&')}$fragment';
}

String? _queryKey(String part) {
  final equalsAt = part.indexOf('=');
  final raw = equalsAt >= 0 ? part.substring(0, equalsAt) : part;
  try {
    return Uri.decodeQueryComponent(raw);
  } on FormatException {
    return null;
  }
}

/// 从 URL 中删除全部指定 query 参数；供核心日志/诊断剥离凭证等价物（ADR-020 §2.5）。
String stripQueryParam(String url, String name) {
  final hashAt = url.indexOf('#');
  final fragment = hashAt >= 0 ? url.substring(hashAt) : '';
  final withoutFragment = hashAt >= 0 ? url.substring(0, hashAt) : url;
  final queryAt = withoutFragment.indexOf('?');
  if (queryAt < 0) return url;
  final base = withoutFragment.substring(0, queryAt);
  final kept = withoutFragment
      .substring(queryAt + 1)
      .split('&')
      .where((part) => part.isNotEmpty && _queryKey(part) != name)
      .toList();
  return kept.isEmpty ? '$base$fragment' : '$base?${kept.join('&')}$fragment';
}

class RawResponse {
  const RawResponse({required this.status, required this.headers, this.body});

  final int status;
  final Map<String, String> headers;
  final String? body;
}

class ProcessedResponse {
  const ProcessedResponse({
    required this.status,
    required this.headers,
    this.body,
  });

  final int status;
  final Map<String, String> headers;
  final String? body;

  Map<String, Object?> toJson() {
    final m = <String, Object?>{'status': status, 'headers': headers};
    if (body != null) m['body'] = body;
    return m;
  }
}

/// 响应脱敏（纯，交回 adapter 前）。响应头按 allowlist 保留——Set-Cookie / Authorization
/// 回显 / Location（含 token）一律丢弃（红线 #1）。status 原样透传（含 401）；body 透传为
/// §2.5 已接受风险。
ProcessedResponse processResponse(RawResponse resp) {
  return ProcessedResponse(
    status: resp.status,
    headers: sanitizeResponseHeaders(resp.headers),
    body: resp.body,
  );
}
