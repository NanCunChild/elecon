/// 安全存储抽象（Dart 侧）—— mirror `server/src/runtime/credential/secure-store.ts`（ADR-012 §2.1）。
///
/// 真实实现：iOS Keychain / Android Keystore / 桌面 Secret Service + at-rest 加密。
///
/// 🔒🔴 `InMemorySecureStore` 是**原型后端**：明文存内存、**无加密、无 OS keystore**。
///   - **绝不可存真实学生凭证**（红线 #1/#8）——仅供模型验证 + B1 集成 + 测试。
///   - at-rest 加密 + keystore 密钥托管是**上线前硬门槛**；桌面 Linux 无统一 keyring 时的
///     回退**不得降级为明文落盘**（ADR-012 §3.7）。key custody 仍是开放问题。
library;

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'types.dart';

abstract interface class SecureStore {
  void put(CredentialEntry entry);
  CredentialEntry? get(String ref);
  void delete(String ref);
  List<CredentialEntry> list();
}

/// 原型后端：内存 Map。CredentialEntry 不可变（final 字段），按值语义对待。
/// ⚠️ 真实实现须替换为 OS keystore + at-rest 加密（见文件头）。
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
