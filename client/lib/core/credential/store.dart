/// 凭证存储（Dart 侧）—— mirror `server/src/runtime/credential/store.ts`（ADR-012 §2.4/§2.5）。
///
/// 与 B1 broker 闭合：`decideInjection` 据**已验签 manifest** 判 inject(ref, via) → 调本
/// store `get(ref)` 取值。**注入权威唯一在 manifest**；store 的 type/scope 是防御性副本，
/// 不一致以 manifest 为准并告警（漂移检测见测试）。
///
/// 收割来源（§2.2）：WebView 登录收割 / fetch 握手结束收割——本原型由 `put` 直接写入，
/// 真实收割逻辑随客户端 WebView 落地（不在原型）。
///
/// 🔒 红线 #1 承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import '../broker/ports.dart';
import 'secure_store.dart';
import 'types.dart';

class CredentialStore implements CredentialResolver {
  CredentialStore({SecureStore? store, int Function()? now})
      : _store = store ?? InMemorySecureStore(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SecureStore _store;
  final int Function() _now;

  /// 收割/续期写入（§2.2 收割动作的落点）。
  void put(CredentialEntry entry) => _store.put(entry);

  /// 登出 = **立即抹除**（§2.5），不是标记。
  void delete(String ref) => _store.delete(ref);

  List<CredentialEntry> list() => _store.list();

  /// 实时有效状态：revoked 优先（吊销不因时间复活）；否则按 expiresAt 判过期。
  CredentialStatus _effectiveStatus(CredentialEntry e) {
    if (e.status == CredentialStatus.revoked) return CredentialStatus.revoked;
    final exp = e.expiresAt;
    if (exp != null && _now() >= exp) return CredentialStatus.expired;
    return e.status;
  }

  /// `CredentialResolver.get`：仅返回**当前有效**（active 且未过期）凭证的值。
  /// 不存在 / 过期 / 吊销 → null——broker 据此 fail，触发 §2.3 续期或 §2.2 重新登录。
  /// 返回 via = store 记录的 type（防御性副本）；注入权威仍是 manifest（§2.4）。
  @override
  Future<ResolvedCredential?> get(String ref) async {
    final e = _store.get(ref);
    if (e == null) return null;
    if (_effectiveStatus(e) != CredentialStatus.active) return null;
    return ResolvedCredential(via: e.type, value: e.value);
  }
}
