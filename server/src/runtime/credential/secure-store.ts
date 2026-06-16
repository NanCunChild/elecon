/**
 * 安全存储抽象（ADR-012 §2.1）—— 向上只暴露「按 ref 存/取/删」，不暴露明文以外的语义。
 * 真实实现：iOS Keychain / Android Keystore / 桌面 Secret Service（libsecret/keyring）+
 * at-rest 加密。统一封装，UI / adapter / 公网服务端永不接触（红线 #1/#2）。
 *
 * 🔒🔴 `InMemorySecureStore` 是**原型后端**：明文存内存、**无加密、无 OS keystore**。
 *   - **绝不可存真实学生凭证**（红线 #1/#8）——仅供模型验证 + B1 集成 + 测试。
 *   - at-rest 加密 + keystore 密钥托管是**上线前硬门槛**；桌面 Linux 无统一 keyring 时的
 *     回退**不得降级为明文落盘**（ADR-012 §3.7）。密钥托管（key custody）仍是开放问题。
 */

import type { CredentialEntry } from "./types.js";

export interface SecureStore {
  put(entry: CredentialEntry): void;
  get(ref: string): CredentialEntry | null;
  delete(ref: string): void;
  list(): CredentialEntry[];
}

/**
 * 原型后端：明文 Map。返回/写入均深拷贝，避免外部持有内部引用而绕过存储语义。
 * ⚠️ 真实实现须替换为 OS keystore + at-rest 加密（见文件头）。
 */
export class InMemorySecureStore implements SecureStore {
  readonly #entries = new Map<string, CredentialEntry>();

  put(entry: CredentialEntry): void {
    this.#entries.set(entry.ref, structuredClone(entry));
  }

  get(ref: string): CredentialEntry | null {
    const e = this.#entries.get(ref);
    return e ? structuredClone(e) : null;
  }

  delete(ref: string): void {
    this.#entries.delete(ref);
  }

  list(): CredentialEntry[] {
    return [...this.#entries.values()].map((e) => structuredClone(e));
  }
}
