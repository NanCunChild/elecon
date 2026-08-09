/// 耐久 cookie 收割桥接（Dart 侧，Gate A · B5）—— ADR-009 §2.4 / ADR-012 §2.4。
///
/// 与 TS 侧 `server/src/runtime/broker/harvest.ts` **语义镜像**，`decideHarvest` 由
/// `contract/golden/broker/harvest.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 判据 b：只收 manifest `credentials.<ref>`（`type: cookie`）声明 ref 命中 scope 的
/// origin cookie；瞬态 / ephemeral 一律丢弃。**路线 a**：ref 值 = scope 命中全部 origin
/// cookie 序列化串（`n1=v1; n2=v2`，RFC 6265 §5.4 发送序），注入时（B6）原样附加。
///
/// **expiresAt（P1-06 起不再恒 null）**：B4 jar 现已捕获 `Max-Age`/`Expires`，故收割项带
/// 真实过期时刻。一个 ref 的值是**一束** cookie（路线 a），其整体有效期取束内**最早**的
/// 非 null 过期时刻——束里任一条死掉，这串序列化值就不再是完整会话，按最早者失效是
/// 唯一 fail-closed 的取法（取 max 会把已残缺的凭证当有效用，换回 401 且掩盖重登信号）。
/// 束内全为 session cookie ⟹ `null`，维持原语义（靠 ADR-012 §2.5 401-重登兜底）。
///
/// 🔒 红线 #1 承重路径（凭证入核心库）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
library;

import '../credential/types.dart';
import 'cookie_jar.dart';
import 'cookie_match.dart';
import 'inject_policy.dart';
import 'url_match.dart';

/// 收割计划项：一个凭证 ref 及其序列化后的 cookie 值。
class HarvestEntry {
  const HarvestEntry({
    required this.ref,
    required this.value,
    this.expiresAt,
  });

  final String ref;

  /// scope 命中的全部 origin cookie 序列化串（路线 a）：`n1=v1; n2=v2`。
  final String value;

  /// 束内最早的非 null 过期时刻（ms epoch）；全为 session cookie ⟹ null。见文件头。
  final int? expiresAt;

  Map<String, Object?> toJson() => {
    'ref': ref,
    'value': value,
    'expiresAt': expiresAt,
  };
}

/// URL query 收割目标；注入 view 与收割 view 可分离（ADR-020 §2.3，SSO mint 必需）。
class QueryHarvestTarget {
  const QueryHarvestTarget({
    required this.view,
    required this.put,
    required this.schoolId,
    required this.now,
  });

  final BrokerManifestView view;
  final void Function(CredentialEntry entry) put;
  final String schoolId;
  final int Function() now;
}

/// 某 scope 模板的代表性 URL（scheme 不影响 domain/path 匹配，取 https）。
String? scopeReprUrl(String scope) {
  final p = parseTemplateHostPath(scope);
  if (p == null) return null;
  return 'https://${p.host}${p.pathPrefix}';
}

/// 序列化命中 cookie（RFC 6265 §5.4：path 长者先，同长按名升序），`n=v` 以 `; ` 连。
String _serialize(List<JarCookie> cookies) {
  final sorted = [...cookies]..sort(compareCookiePathName);
  return sorted.map((c) => '${c.name}=${c.value}').join('; ');
}

/// 束内最早的非 null 过期时刻；全为 session cookie ⟹ null（见文件头 fail-closed 论据）。
int? _earliestExpiry(List<JarCookie> cookies) {
  int? earliest;
  for (final c in cookies) {
    final e = c.expiresAt;
    if (e == null) continue;
    if (earliest == null || e < earliest) earliest = e;
  }
  return earliest;
}

/// 决定 origin 区哪些 cookie 收割、归属哪个 ref（纯，judge b + 收割方向匹配）。
///
/// 对每个 `type: "cookie"` 的 ref：其 scope 任一前缀的代表 URL 被某 origin cookie
/// `matchCookieForSend` 命中 → 归此 ref。`type: "header"` ref 不参与。未命中 → 丢弃。
/// 父域共享 cookie 落多个 ref 时**分别**收割进各 ref。计划项按 ref 名升序。
List<HarvestEntry> decideHarvest(
  List<JarCookie> originCookies,
  BrokerManifestView view,
  int nowMs,
) {
  // 纵深防御（栅栏 3）：只收 origin 区。正常输入是 jar.harvestView()（已仅 origin），
  // 但本函数不信任上游——即便误传入 ephemeral cookie，也在此丢弃，绝不入库。
  // [nowMs] 同理是纵深防御：jar.harvestView() 已滤过期，此处按同一时钟再滤一次
  // （P1-06——绝不把已死会话写进持久 Store）。
  final harvestable = originCookies.where((c) => c.source == 'origin').toList();

  final plan = <HarvestEntry>[];
  view.credentials.forEach((ref, decl) {
    if (decl.type != 'cookie') return;

    final reprUrls = decl.scope.map(scopeReprUrl).whereType<String>().toList();
    // 整条 cookie 直接喂匹配器：secure/expiresAt 不会被漏传。scope 代表 URL 恒 https，
    // 故 Secure 判据在收割方向天然满足。
    final matched = harvestable
        .where((c) => reprUrls.any((u) => matchCookieForSend(c, u, nowMs)))
        .toList();
    if (matched.isEmpty) return;

    plan.add(
      HarvestEntry(
        ref: ref,
        value: _serialize(matched),
        expiresAt: _earliestExpiry(matched),
      ),
    );
  });

  plan.sort((a, b) => a.ref.compareTo(b.ref));
  return plan;
}

/// 从核心已接受的 URL 收割 query credential（ADR-020 §2.3）。
/// 重复同名参数拒绝收割，避免两端首/末值差异；fragment 不参与 [Uri.queryParametersAll]。
List<HarvestEntry> decideQueryHarvest(String url, BrokerManifestView view) {
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasAuthority) return const [];

  final plan = <HarvestEntry>[];
  view.credentials.forEach((ref, decl) {
    if (decl.type != 'query' || decl.queryParam == null) return;
    if (!decl.scope.any((scope) => scopeMatches(url, scope))) return;
    final values = parsed.queryParametersAll[decl.queryParam];
    if (values == null || values.length != 1 || values.single.isEmpty) return;
    // query 凭证无 cookie 属性面，无从得知生命周期 ⟹ session 语义（同 P1-06 前行为）。
    plan.add(HarvestEntry(ref: ref, value: values.single, expiresAt: null));
  });
  plan.sort((a, b) => a.ref.compareTo(b.ref));
  return plan;
}

/// 收割一个核心已接受的 URL；不保存完整 URL，只把裸凭证值写入核心 store。
void harvestQueryUrl(String url, QueryHarvestTarget target) {
  harvestInto(
    decideQueryHarvest(url, target.view),
    target.view,
    target.put,
    schoolId: target.schoolId,
    now: target.now,
  );
}

/// 把收割计划写入凭证库（薄桥接）。type/scope 以 manifest 为准、store 防御性副本
/// （ADR-012 §2.4）；同 ref 已存在 → put 覆盖（会话轮换）。`expiresAt` 取自计划项
/// （P1-06，见文件头；null = session）。
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
    put(
      CredentialEntry(
        ref: e.ref,
        schoolId: schoolId,
        type: decl.type,
        scope: List.of(decl.scope), // 防御性副本
        value: e.value,
        acquiredAt: now(),
        expiresAt: e.expiresAt,
        status: CredentialStatus.active,
        // 敏感度按 manifest role 标注（ADR-017 / ADR-012 §2.8），驱动保护策略与 UI。
        sensitivity: decl.role == 'sso-master'
            ? CredentialSensitivity.master
            : CredentialSensitivity.standard,
      ),
    );
  }
}
