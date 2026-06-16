/**
 * 凭证存储（ADR-012 §2.4/§2.5）—— 按 ref 存/取/删 + 生命周期 + 实现 B1 的 `CredentialResolver`。
 *
 * 与 B1 broker 的闭合（ADR-012 §2.4）：
 *   broker `decideInjection` 据 **已验签 manifest** 决定 inject(ref, via) → 调本 store `get(ref)`
 *   取值。**注入权威唯一在 manifest**；store 记录的 `type`/`scope` 是防御性副本 + 一致性基准，
 *   不一致时以 manifest 为准并告警（漂移检测见 store.smoke.ts 集成例）。
 *
 * 收割来源（§2.2）：WebView 登录收割 / fetch 握手结束收割——本原型由 `put` 直接写入，
 * 真实收割逻辑是承重 + 安全敏感代码，随客户端 WebView 落地（不在本原型）。
 *
 * 🔒 红线 #1 承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import type { CredentialResolver, ResolvedCredential } from "../broker/ports.js";
import { InMemorySecureStore, type SecureStore } from "./secure-store.js";
import type { CredentialEntry, CredentialStatus } from "./types.js";

export class CredentialStore implements CredentialResolver {
  readonly #store: SecureStore;
  readonly #now: () => number;

  constructor(store: SecureStore = new InMemorySecureStore(), now: () => number = Date.now) {
    this.#store = store;
    this.#now = now;
  }

  /** 收割/续期写入（§2.2 收割动作的落点）。 */
  put(entry: CredentialEntry): void {
    this.#store.put(entry);
  }

  /** 登出 = **立即抹除**（§2.5），不是标记。 */
  delete(ref: string): void {
    this.#store.delete(ref);
  }

  /** 列出当前条目（含失效；管理/调试用，不返回解密注入值的承诺由 get 负责）。 */
  list(): CredentialEntry[] {
    return this.#store.list();
  }

  /**
   * 实时有效状态：按 `expiresAt` 判过期（不改写存储——过期标记/续期由生命周期任务做，§2.5）。
   * revoked 优先（吊销不可因时间"复活"）。
   */
  #effectiveStatus(e: CredentialEntry): CredentialStatus {
    if (e.status === "revoked") return "revoked";
    if (e.expiresAt !== null && this.#now() >= e.expiresAt) return "expired";
    return e.status;
  }

  /**
   * `CredentialResolver.get`：仅返回**当前有效**（active 且未过期）凭证的值。
   * 不存在 / 过期 / 吊销 → `null`——broker 据此 fail，触发 §2.3 续期或 §2.2 重新登录。
   * 返回 `via` = store 记录的 `type`（防御性副本）；注入权威仍是 manifest（§2.4）。
   */
  async get(ref: string): Promise<ResolvedCredential | null> {
    const e = this.#store.get(ref);
    if (!e) return null;
    if (this.#effectiveStatus(e) !== "active") return null;
    return { via: e.type, value: e.value };
  }
}
