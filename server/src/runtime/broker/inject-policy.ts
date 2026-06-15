/**
 * Broker 注入策略核心（Gate A · B1）—— ADR-009 §2.1 数据流的第 1–2 步，且**仅**这两步。
 *
 *   ctx.fetch(url, init)
 *     → ① url 命中 network.allow？否 → 拒绝（fail-closed）
 *     → ② url 命中某 credentials.<ref>.scope？命中 → INJECT(ref, via)；未命中 → PASSTHROUGH
 *
 * 本模块是**纯函数决策**：不发请求、不取凭证值、不拼 HTTP 头、不碰 jar/重定向。
 * 「取凭证值 → 拼头」属 B2/B6 + 凭证存储（端口见 ./ports.ts，B1 不实现）。
 * 这样 B1 可穷举 golden 测试、可独立人工审，且不被尚未落地的凭证存储阻塞。
 *
 * 🔒 安全敏感（红线 #1 凭证注入决策）：AI 起草，须人工 + 安全清单复核（AGENTS.md §1）。
 */

import { scopeMatches, scopePrefix, urlCoveredByAllow } from "./url-match.js";

export type CredentialVia = "cookie" | "header";

/** manifest `credentials.<ref>` 的注入相关声明（ADR-013）。**不含凭证值**（红线 #1）。 */
export interface CredentialDecl {
  scope: string[];
  type: CredentialVia;
}

/** Broker 决策所需的 manifest 视图（仅注入相关字段；绝不含凭证值）。 */
export interface BrokerManifestView {
  allow: string[];
  credentials?: Record<string, CredentialDecl>;
}

export type RejectReason = "outside_allow" | "ambiguous_scope";

export type InjectionDecision =
  | { kind: "reject"; reason: RejectReason }
  | { kind: "passthrough" }
  | { kind: "inject"; ref: string; via: CredentialVia };

/**
 * 决定对某出站 url 的凭证注入策略。
 *
 * 1. **fail-closed**：url 不在 allow → reject(outside_allow)。
 * 2. 收集命中 url 的 credential ref（取各 ref 命中 scope 中最长前缀）；无命中 → passthrough。
 * 3. **最长前缀胜出** → inject(ref, via)。
 * 4. **纵深防御**：最长前缀等长且分属不同 ref → reject(ambiguous_scope)，绝不猜。
 *    校验器 C7 应已静态拦截「等长重叠 scope」，但 Broker 作为安全边界**不信任上游已校验**，
 *    运行时再次 fail-closed——宁可拒绝取数，绝不注错凭证（红线 #1）。
 */
export function decideInjection(url: string, view: BrokerManifestView): InjectionDecision {
  // ① 出口闸门
  if (!urlCoveredByAllow(url, view.allow)) {
    return { kind: "reject", reason: "outside_allow" };
  }

  // ② 收集命中的 ref（每 ref 取其命中 scope 的最长前缀长度）
  const hits: Array<{ ref: string; via: CredentialVia; prefixLen: number }> = [];
  for (const [ref, decl] of Object.entries(view.credentials ?? {})) {
    let bestLen = -1;
    for (const pattern of decl.scope) {
      if (scopeMatches(url, pattern)) {
        bestLen = Math.max(bestLen, scopePrefix(pattern).length);
      }
    }
    if (bestLen >= 0) {
      hits.push({ ref, via: decl.type, prefixLen: bestLen });
    }
  }
  if (hits.length === 0) {
    return { kind: "passthrough" };
  }

  // ③ 最长前缀胜出
  let best = hits[0]!;
  for (const h of hits) {
    if (h.prefixLen > best.prefixLen) best = h;
  }

  // ④ 纵深防御：等长且不同 ref → 歧义 → fail-closed
  const ambiguous = hits.some((h) => h.prefixLen === best.prefixLen && h.ref !== best.ref);
  if (ambiguous) {
    return { kind: "reject", reason: "ambiguous_scope" };
  }

  return { kind: "inject", ref: best.ref, via: best.via };
}
