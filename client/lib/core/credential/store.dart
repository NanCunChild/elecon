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

import 'package:flutter/foundation.dart' show kReleaseMode;

import '../broker/ports.dart';
import 'secure_store.dart';
import 'types.dart';

/// [CredentialStore] 省略 store 时的默认后端裁定（#79 P0-2）。**release 下禁止**
/// 静默回退到 [InMemorySecureStore]（明文内存，绝不可存真实凭证，红线 #1/#8；
/// secure_store.dart 文件头 + ADR-012 §3.7）——release 缺省即 fail-closed 抛错，
/// 安全性不依赖「生产代码记得注入真实 store」的调用约定。真实 OS keystore +
/// at-rest 加密仍是上线前硬门槛（ADR-012 §2.1，platform 实现待落地）：就位前
/// release 无合法默认后端 → 凭证存储整体 fail-closed。debug/test 下得 InMemory。
///
/// `releaseMode` 参数化编译期常量 [kReleaseMode]（生产接线固定传它），使 release
/// 语义可被单测覆盖。
SecureStore defaultSecureStore({required bool releaseMode}) {
  if (releaseMode) {
    throw StateError(
      'release 下不得默认使用 InMemorySecureStore（明文内存，红线 #1/#8）——'
      '须显式注入真实 OS keystore 后端；platform 实现落地前凭证存储 fail-closed'
      '（#79 P0-2，ADR-012 §2.1/§3.7）',
    );
  }
  return InMemorySecureStore();
}

class CredentialStore implements CredentialResolver {
  /// [store] 省略时的默认后端裁定（#79 P0-2）：**release 下禁止**静默回退到
  /// [InMemorySecureStore]（明文内存，绝不可存真实凭证，红线 #1/#8；secure_store.dart
  /// 文件头 + ADR-012 §3.7）。安全性不依赖「生产代码记得注入真实 store」的调用约定——
  /// release 构造缺省 store 即 fail-closed 抛错。真实 OS keystore + at-rest 加密仍是
  /// 上线前硬门槛（ADR-012 §2.1，platform 实现待落地）：在它就位前，release 无合法
  /// 默认后端 → 凭证存储整体 fail-closed，与「无真实 secure store 就不该假装能存凭证」
  /// 一致。debug/test 下省略 store 仍得 InMemory（原型/集成/单测用）。
  CredentialStore({SecureStore? store, int Function()? now})
      : _store = store ?? defaultSecureStore(releaseMode: kReleaseMode),
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

  /// 是否有指定学校下有效的 [ref]（**仅元数据**，不返回凭证值，红线 #1）。
  /// 供 [ensureCredential] / 能力闸门：缺则 mint 或可见登录（ADR-017 / mint 闭环 §4.2）。
  bool hasActive({required String schoolId, required String ref}) {
    final e = _store.get(ref);
    if (e == null) return false;
    if (e.schoolId != schoolId) return false;
    return _effectiveStatus(e) == CredentialStatus.active;
  }

  /// 该校是否有有效母凭证（[CredentialSensitivity.master]，收割时按 `role: sso-master` 标注）。
  /// **仅元数据**，不返回值（红线 #1）。
  bool hasActiveSsoMaster(String schoolId) {
    for (final e in _store.list()) {
      if (e.schoolId != schoolId) continue;
      if (e.sensitivity != CredentialSensitivity.master) continue;
      if (_effectiveStatus(e) == CredentialStatus.active) return true;
    }
    return false;
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
