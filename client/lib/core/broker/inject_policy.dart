/// Broker 注入策略核心（Gate A · B1，Dart 侧）—— ADR-009 §2.1 数据流第 1–2 步。
///
/// 与 TS 侧 `server/src/runtime/broker/inject-policy.ts` **语义对齐**，由
/// `contract/golden/broker/inject-policy.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 纯函数决策：不发请求、不取凭证值、不拼 HTTP 头。「取凭证值 → 拼头」属凭证存储
/// （ADR-012）+ 后续运行时接线，不在 B1。
///
/// 🔒 安全敏感（红线 #1 凭证注入决策）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

import 'url_match.dart';

/// manifest `credentials.<ref>` 的注入相关声明（ADR-013）。**不含凭证值**（红线 #1）。
class CredentialDecl {
  const CredentialDecl({
    required this.scope,
    required this.type,
    this.queryParam,
    this.headerName,
    this.role,
  });

  final List<String> scope;

  /// 注入方式：`cookie` | `header` | `query`。
  final String type;

  /// `type=query` 时由 Broker 注入/收割的参数名（ADR-020 §2.2）。
  final String? queryParam;

  /// `type=header` 时的注入头名（ADR-029 §2.1）；缺省 Authorization。静态已验签字面量，禁凭证 / hop-by-hop 头（validator CH1–CH3）。
  final String? headerName;

  /// 凭证角色（ADR-017）。`sso-master`=CAS 母凭证；缺省=普通下游。
  /// **不影响注入决策**（[decideInjection] 忽略之），只驱动收割时的敏感度标注（ADR-012 §2.8）。
  final String? role;
}

/// Broker 决策所需的 manifest 视图（仅注入相关字段；绝不含凭证值）。
class BrokerManifestView {
  const BrokerManifestView({required this.allow, this.credentials = const {}});

  final List<String> allow;
  final Map<String, CredentialDecl> credentials;
}

/// 注入决策结果。`toJson()` 与 `contract/golden/broker/inject-policy.json` 的
/// `expected` 同形，供双跑断言。
sealed class InjectionDecision {
  const InjectionDecision();

  Map<String, Object?> toJson();
}

/// 拒绝（fail-closed）。`reason` ∈ {`outside_allow`, `ambiguous_scope`}。
class RejectDecision extends InjectionDecision {
  const RejectDecision(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'kind': 'reject', 'reason': reason};
}

/// 放行但不注入凭证（在 allow 内、未命中任何 scope）。
class PassthroughDecision extends InjectionDecision {
  const PassthroughDecision();

  @override
  Map<String, Object?> toJson() => {'kind': 'passthrough'};
}

/// 注入指定 ref 的凭证（`via` ∈ {`cookie`, `header`}）。
class InjectDecision extends InjectionDecision {
  const InjectDecision({
    required this.ref,
    required this.via,
    this.queryParam,
    this.headerName,
  });

  final String ref;
  final String via;
  final String? queryParam;

  /// `via=header` 时的注入头名（ADR-029 §2.1）；缺省时拼装层用 Authorization。
  final String? headerName;

  @override
  Map<String, Object?> toJson() {
    final result = <String, Object?>{'kind': 'inject', 'ref': ref, 'via': via};
    if (queryParam != null) result['queryParam'] = queryParam;
    if (headerName != null) result['headerName'] = headerName;
    return result;
  }
}

/// 决定对某出站 url 的凭证注入策略。
///
/// 1. **fail-closed**：url 不在 allow → reject(outside_allow)。
/// 2. 收集命中 url 的 credential ref（取各 ref 命中 scope 中最长前缀）；无 → passthrough。
/// 3. **最长前缀胜出** → inject(ref, via)。
/// 4. **纵深防御**：最长前缀等长且分属不同 ref → reject(ambiguous_scope)，绝不猜。
///    校验器 C7 应已静态拦截等长重叠 scope；Broker 作为安全边界**不信任上游校验**，
///    运行时再次 fail-closed——宁可拒绝取数，绝不注错凭证（红线 #1）。
InjectionDecision decideInjection(String url, BrokerManifestView view) {
  // ① 出口闸门
  if (!urlCoveredByAllow(url, view.allow)) {
    return const RejectDecision('outside_allow');
  }

  // ② 收集命中的 ref（每 ref 取其命中 scope 的最长前缀长度）
  final invalidDecl = view.credentials.values.any((decl) {
    final valid =
        decl.queryParam != null &&
        RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(decl.queryParam!);
    // headerName 仅 type=header 合法（纵深防御，validator CH1 亦拦）——Broker 不信任上游已校验。
    final headerNameMisplaced =
        decl.type != 'header' && decl.headerName != null;
    return (decl.type == 'query' && !valid) ||
        (decl.type != 'query' && decl.queryParam != null) ||
        headerNameMisplaced;
  });
  if (invalidDecl) {
    return const RejectDecision('invalid_credential_decl');
  }

  final hits =
      <
        ({
          String ref,
          String via,
          String? queryParam,
          String? headerName,
          int prefixLen,
        })
      >[];
  view.credentials.forEach((ref, decl) {
    var bestLen = -1;
    for (final pattern in decl.scope) {
      if (scopeMatches(url, pattern)) {
        final len = scopePrefix(pattern).length;
        if (len > bestLen) bestLen = len;
      }
    }
    if (bestLen >= 0) {
      hits.add((
        ref: ref,
        via: decl.type,
        queryParam: decl.queryParam,
        headerName: decl.headerName,
        prefixLen: bestLen,
      ));
    }
  });
  if (hits.isEmpty) {
    return const PassthroughDecision();
  }

  // ③ 最长前缀胜出
  var best = hits.first;
  for (final h in hits) {
    if (h.prefixLen > best.prefixLen) best = h;
  }

  // ④ 纵深防御：等长且不同 ref → 歧义 → fail-closed
  final ambiguous = hits.any(
    (h) => h.prefixLen == best.prefixLen && h.ref != best.ref,
  );
  if (ambiguous) {
    return const RejectDecision('ambiguous_scope');
  }

  return InjectDecision(
    ref: best.ref,
    via: best.via,
    queryParam: best.queryParam,
    headerName: best.headerName,
  );
}
