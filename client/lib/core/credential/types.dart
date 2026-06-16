/// 凭证条目数据模型（Dart 侧）—— mirror `server/src/runtime/credential/types.ts`（ADR-012 §2.4）。
///
/// 🔒 红线 #1：`value` 是凭证值，仅存于可信核心、at-rest 加密、注入瞬间解密用完即弃。
/// 本目录为客户端核心实现的原型形态；at-rest 加密 + OS keystore 是上线前硬门槛（见 secure_store.dart）。
library;

enum CredentialStatus { active, expired, revoked }

class CredentialEntry {
  const CredentialEntry({
    required this.ref,
    required this.schoolId,
    required this.type,
    required this.scope,
    required this.value,
    required this.acquiredAt,
    required this.expiresAt,
    required this.status,
  });

  /// 稳定引用名；manifest `credentials.<name>` 指向它（ADR-013）。
  final String ref;
  final String schoolId;

  /// 注入方式（cookie|header）。**防御性副本**——注入权威以已验签 manifest 为准（§2.4）。
  final String type;

  /// URL 前缀。**防御性副本 + 一致性基准**——非注入依据（§2.4）。
  final List<String> scope;

  /// 凭证值。**原型为明文**；真实须 at-rest 加密。注入瞬间解密用完即弃。
  final String value;

  final int acquiredAt;
  final int? expiresAt;
  final CredentialStatus status;
}
