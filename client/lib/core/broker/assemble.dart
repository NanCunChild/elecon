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

export 'ports.dart' show ResolvedCredential;

/// 出站 cookie 对（B4 `selectCookies` 的输出形；不外泄 domain/path/source）。
class CookiePair {
  const CookiePair(this.name, this.value);

  final String name;
  final String value;
}

/// adapter 经 `ctx.fetch(url, init)` 传入的请求意图（host 侧已把 headers 归一）。
class RequestInit {
  const RequestInit({this.method, this.headers, this.body});

  final String? method;
  final Map<String, String>? headers;
  final String? body;
}

class AssembleRequestInput {
  const AssembleRequestInput({
    required this.init,
    required this.decision,
    required this.resolved,
    required this.jarCookies,
  });

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
  const OkResult({required this.method, required this.headers, this.body});

  final String method;
  final Map<String, String> headers;
  final String? body;

  @override
  Map<String, Object?> toJson() {
    final m = <String, Object?>{'kind': 'ok', 'method': method, 'headers': headers};
    if (body != null) m['body'] = body;
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
    out.add(CookiePair(part.substring(0, eq).trim(), part.substring(eq + 1).trim()));
  }
  return out;
}

/// 拼装出站请求（纯）。语义见文件头与 TS `assembleRequest`。
///
/// **凭证缺失（inject 但 resolved==null）**：不附该凭证（不伪造、不外泄），请求照发
/// （jar cookie 仍附），由 origin 返 401 → adapter 按 ADR-009 §2 第 6 条透传处理。
/// 已于 PR #49 经人工确认取此方案（与 broker 不内联重登一致）。
AssembleResult assembleRequest(AssembleRequestInput input) {
  final decision = input.decision;
  if (decision is RejectDecision) {
    return RejectResult(decision.reason);
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
    headers['Authorization'] = input.resolved!.value;
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
    headers['Cookie'] = cookiePairs.map((p) => '${p.name}=${p.value}').join('; ');
  }

  final method = (input.init.method ?? 'GET').toUpperCase();
  return OkResult(method: method, headers: headers, body: input.init.body);
}

class RawResponse {
  const RawResponse({required this.status, required this.headers, this.body});

  final int status;
  final Map<String, String> headers;
  final String? body;
}

class ProcessedResponse {
  const ProcessedResponse({required this.status, required this.headers, this.body});

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
