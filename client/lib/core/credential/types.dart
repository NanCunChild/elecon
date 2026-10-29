/// 凭证条目数据模型（Dart 侧）—— mirror `server/src/runtime/credential/types.ts`（ADR-012 §2.4）。
///
/// 🔒 ADR-012/034/035：持久化由 H/S 后端处理，M 档只存内存。
/// 新受信脚本可读取当前学校的 value；V1 adapter 仍仅经 Broker 使用。
/// 加密主密钥不开放，平台可用性与用户同意由后端工厂裁定。
library;

enum CredentialStatus { active, expired, revoked }

/// 凭证敏感度分级（ADR-012 §2.8 / ADR-017）。**非密元数据**，不作注入权威
/// （权威在 manifest，§2.4）；用于驱动保护策略与 UI 呈现。
/// - [master]：CAS 母凭证（可静默换任意下游 session，最高价值目标）。
/// - [standard]：普通下游 session。
enum CredentialSensitivity { standard, master }

/// 凭证的 at-rest 保护档位（ADR-012 §2.8）。**非密元数据**（「登记为加密」）。
/// - [hardware]：DEK 由硬件 KEK 包裹（TEE/SE/StrongBox/Keystore），私钥永不出硬件。
/// - [software]：无硬件，DEK 明文与密文并存落盘（经用户 5 秒警示知情同意，≈明文）。
/// - [memory]：仅内存、不落盘（无硬件且用户取消 / 未同意，= §2.7 决策 E 旧 fail-closed）。
enum CredentialProtection { hardware, software, memory }

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
    this.sensitivity = CredentialSensitivity.standard,
    this.protection = CredentialProtection.memory,
  });

  /// 稳定物理键：V1 为原始 manifest ref；新脚本包含学校/namespace/key。
  /// 底层按 ref 索引，不自动将旧 raw ref 变成多校复合键（ADR-035 §2）。
  final String ref;
  final String schoolId;

  /// 注入方式（cookie|header|query）。**防御性副本**——注入权威以已验签 manifest 为准（ADR-012 §2.4 / ADR-020）。
  final String type;

  /// URL 前缀。**防御性副本 + 一致性基准**——非注入依据（§2.4）。
  final List<String> scope;

  /// 内存中的凭据值。H/S 落盘加密，M 不落盘；新受信脚本可直接访问。
  final String value;

  final int acquiredAt;
  final int? expiresAt;
  final CredentialStatus status;

  /// 敏感度分级（非密；§2.8 保护策略 + UI 依据）。收割时按 manifest `role` 标注。
  final CredentialSensitivity sensitivity;

  /// 实际落地的保护档（非密；由 store 后端按硬件可用性 + 用户同意裁定，§2.8）。
  final CredentialProtection protection;
}
