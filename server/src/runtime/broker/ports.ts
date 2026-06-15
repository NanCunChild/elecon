/**
 * Broker 端口（seam）声明 —— B1 只定义接口，**不实现**。
 *
 * `decideInjection`（./inject-policy.ts）产出「注入哪个 ref / via」后，由 B2/B6 经
 * `CredentialResolver` 取凭证值并拼 HTTP 头。Resolver 的实现属**核心凭证存储**
 * （issue #17 §C，ADR-012，尚未落地）。在此声明端口，使 B1 与凭证存储解耦：
 * B1 测试用 fake resolver，真实实现随凭证存储 PR 落地。
 *
 * 🔒 凭证值仅在可信核心内流转，**绝不回交 adapter / UI / 公网服务端**（红线 #1）。
 */

import type { CredentialVia } from "./inject-policy.js";

/** 已解析的凭证（核心内部表示）。`value` 是凭证明文/会话值，仅核心可见。 */
export interface ResolvedCredential {
  via: CredentialVia;
  value: string;
}

/** 据 manifest 声明的 ref 取凭证值。未命中（无此凭证 / 已失效）返回 null。 */
export interface CredentialResolver {
  get(ref: string): Promise<ResolvedCredential | null>;
}
