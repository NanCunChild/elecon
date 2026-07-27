/**
 * 凭证条目数据模型（ADR-012 §2.4）。
 *
 * 🔒 红线 #1：`value` 是凭证值，仅存于可信核心、at-rest 加密、注入瞬间解密用完即弃，
 * 永不出核心、永不交 adapter/UI/公网服务端。
 *
 * 本目录为 **TS 参考原型** —— 验证模型 + 与 B1 broker 集成。v1 实际落点是 Dart 客户端
 * 核心（ADR-012 §2.1/§2.6：首版 client-direct，设备 OS 安全存储为权威存储）。后续 Dart 对齐。
 */

export type CredentialVia = "cookie" | "header" | "query";

export type CredentialStatus = "active" | "expired" | "revoked";

export interface CredentialEntry {
  /** 稳定引用名；manifest `credentials.<name>` 指向它（ADR-013）。 */
  ref: string;
  schoolId: string;
  /** 注入方式。**防御性副本**——注入权威以已验签 manifest 为准（ADR-012 §2.4）。 */
  type: CredentialVia;
  /** URL 前缀。**防御性副本 + 一致性基准**——非注入依据（ADR-012 §2.4）。 */
  scope: string[];
  /**
   * 凭证值。**本原型在内存中为明文**；真实实现须 at-rest 加密（见 secure-store.ts）。
   * 注入瞬间在核心内解密、用完即弃（ADR-012 §2.4）。
   */
  value: string;
  acquiredAt: number;
  expiresAt: number | null;
  status: CredentialStatus;
}
