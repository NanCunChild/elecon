/// 安全存储抽象（Dart 侧）—— mirror `server/src/runtime/credential/secure-store.ts`（ADR-012 §2.1）。
///
/// 真实实现：iOS Keychain / Android Keystore / 桌面 Secret Service + at-rest 加密。
///
/// 🔒 `InMemorySecureStore` 不落盘，也不提供持久化或 OS keystore 保护。
/// ADR-012 §2.8 / ADR-034 §3 允许后端工厂显式选择 M 档用于当前真实会话；
/// release 的缺省构造仍拒绝，避免把未裁定后端误当成持久存储。
/// H/S 持久化后端另有加密与密钥策略；测试夹具始终只使用合成凭据。
library;

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'types.dart';

abstract interface class SecureStore {
  void put(CredentialEntry entry);
  CredentialEntry? get(String ref);
  void delete(String ref);
  List<CredentialEntry> list();
}

/// 内存档 Map。是否选择此档由可信工厂/会话决定，不承诺跨重启保存。
class InMemorySecureStore implements SecureStore {
  InMemorySecureStore({bool releaseMode = kReleaseMode}) {
    if (releaseMode) {
      throw StateError(
        'release 下不得构造 InMemorySecureStore（明文内存原型后端，红线 #1/#8）——'
        '测试/dev 可用；生产须显式注入真实 OS secure store 后端',
      );
    }
  }

  final Map<String, CredentialEntry> _entries = {};

  @override
  void put(CredentialEntry entry) => _entries[entry.ref] = entry;

  @override
  CredentialEntry? get(String ref) => _entries[ref];

  @override
  void delete(String ref) => _entries.remove(ref);

  @override
  List<CredentialEntry> list() => _entries.values.toList();
}
