/// 耐久 cookie 收割桥接（Dart 侧，Gate A · B5）—— ADR-009 §2.4 / ADR-012 §2.4。
///
/// 与 TS 侧 `server/src/runtime/broker/harvest.ts` **语义镜像**，`decideHarvest` 由
/// `contract/golden/broker/harvest.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 判据 b：只收 manifest `credentials.<ref>`（`type: cookie`）声明 ref 命中 scope 的
/// origin cookie；瞬态 / ephemeral 一律丢弃。**路线 a**：ref 值 = scope 命中全部 origin
/// cookie 序列化串（`n1=v1; n2=v2`，RFC 6265 §5.4 发送序），注入时（B6）原样附加。
///
/// expiresAt 一律 null（session 语义）——精确生命周期须 Max-Age/Expires（B4 未捕获），
/// 见 b5 计划 §8 #2（跑通优先，靠 §2.5 401-重登兜底）。
///
/// 🔒 红线 #1 承重路径（凭证入核心库）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

import '../credential/types.dart';
import 'cookie_jar.dart';
import 'cookie_match.dart';
import 'inject_policy.dart';

/// 收割计划项：一个凭证 ref 及其序列化后的 cookie 值。
class HarvestEntry {
  const HarvestEntry({required this.ref, required this.value});

  final String ref;

  /// scope 命中的全部 origin cookie 序列化串（路线 a）：`n1=v1; n2=v2`。
  final String value;

  Map<String, Object?> toJson() => {'ref': ref, 'value': value};
}

/// 某 scope 模板的代表性 URL（scheme 不影响 domain/path 匹配，取 https）。
String? scopeReprUrl(String scope) {
  final p = parseTemplateHostPath(scope);
  if (p == null) return null;
  return 'https://${p.host}${p.pathPrefix}';
}

/// 序列化命中 cookie（RFC 6265 §5.4：path 长者先，同长按名升序），`n=v` 以 `; ` 连。
String _serialize(List<JarCookie> cookies) {
  final sorted = [...cookies]..sort((a, b) {
      final byLen = b.path.length - a.path.length;
      if (byLen != 0) return byLen;
      return a.name.compareTo(b.name);
    });
  return sorted.map((c) => '${c.name}=${c.value}').join('; ');
}

/// 决定 origin 区哪些 cookie 收割、归属哪个 ref（纯，judge b + 收割方向匹配）。
///
/// 对每个 `type: "cookie"` 的 ref：其 scope 任一前缀的代表 URL 被某 origin cookie
/// `matchCookieForSend` 命中 → 归此 ref。`type: "header"` ref 不参与。未命中 → 丢弃。
/// 父域共享 cookie 落多个 ref 时**分别**收割进各 ref。计划项按 ref 名升序。
List<HarvestEntry> decideHarvest(
  List<JarCookie> originCookies,
  BrokerManifestView view,
) {
  // 纵深防御（栅栏 3）：只收 origin 区。正常输入是 jar.harvestView()（已仅 origin），
  // 但本函数不信任上游——即便误传入 ephemeral cookie，也在此丢弃，绝不入库。
  final harvestable =
      originCookies.where((c) => c.source == 'origin').toList();

  final plan = <HarvestEntry>[];
  view.credentials.forEach((ref, decl) {
    if (decl.type != 'cookie') return;

    final reprUrls = decl.scope.map(scopeReprUrl).whereType<String>().toList();
    final matched = harvestable
        .where((c) => reprUrls.any(
            (u) => matchCookieForSend((domain: c.domain, path: c.path), u)))
        .toList();
    if (matched.isEmpty) return;

    plan.add(HarvestEntry(ref: ref, value: _serialize(matched)));
  });

  plan.sort((a, b) => a.ref.compareTo(b.ref));
  return plan;
}

/// 把收割计划写入凭证库（薄桥接）。type/scope 以 manifest 为准、store 防御性副本
/// （ADR-012 §2.4）；同 ref 已存在 → put 覆盖（会话轮换）。expiresAt=null（见文件头）。
void harvestInto(
  List<HarvestEntry> plan,
  BrokerManifestView view,
  void Function(CredentialEntry entry) put, {
  required String schoolId,
  required int Function() now,
}) {
  for (final e in plan) {
    final decl = view.credentials[e.ref];
    if (decl == null) continue; // 计划只来自 decideHarvest，理论上恒有；防御性跳过
    put(CredentialEntry(
      ref: e.ref,
      schoolId: schoolId,
      type: decl.type,
      scope: List.of(decl.scope), // 防御性副本
      value: e.value,
      acquiredAt: now(),
      expiresAt: null,
      status: CredentialStatus.active,
    ));
  }
}
