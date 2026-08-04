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

import {
  FORBIDDEN_CREDENTIAL_HEADER_NAMES,
  RESPONSE_HEADER_ALLOWLIST,
  scopeMatches,
  scopePrefix,
  urlCoveredByAllow,
} from "@elecon/broker-primitives";

export type CredentialVia = "cookie" | "header" | "query";

/** manifest `credentials.<ref>` 的注入相关声明（ADR-013）。**不含凭证值**（红线 #1）。 */
export interface CredentialDecl {
  scope: string[];
  type: CredentialVia;
  /** type=query 时的参数名；参数名来自已验签 manifest，凭证值仍只在 Broker 内（ADR-020 §2.2）。 */
  queryParam?: string;
  /** type=header 时的注入头名（ADR-029 §2.1）；缺省 Authorization。静态已验签字面量，禁凭证 / hop-by-hop 头（validator CH1–CH3）。 */
  headerName?: string;
}

/** Broker 决策所需的 manifest 视图（仅注入相关字段；绝不含凭证值）。 */
export interface BrokerManifestView {
  allow: string[];
  credentials?: Record<string, CredentialDecl>;
}

export type RejectReason = "outside_allow" | "ambiguous_scope" | "invalid_credential_decl";

export type InjectionDecision =
  | { kind: "reject"; reason: RejectReason }
  | { kind: "passthrough" }
  | { kind: "inject"; ref: string; via: CredentialVia; queryParam?: string; headerName?: string };

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
  const hits: Array<{
    ref: string;
    via: CredentialVia;
    queryParam: string | undefined;
    headerName: string | undefined;
    prefixLen: number;
  }> = [];
  for (const [ref, decl] of Object.entries(view.credentials ?? {})) {
    const validQueryParam = decl.queryParam !== undefined && /^[A-Za-z0-9_.-]+$/.test(decl.queryParam);
    if (
      (decl.type === "query" && !validQueryParam) ||
      (decl.type !== "query" && decl.queryParam !== undefined)
    ) {
      return { kind: "reject", reason: "invalid_credential_decl" };
    }
    if (decl.headerName !== undefined) {
      const normalized = decl.headerName.toLowerCase();
      // Broker 不信任发布期 validator：运行时独立复核 ADR-029 CH1–CH3。
      if (
        decl.type !== "header" ||
        !/^[A-Za-z][A-Za-z0-9-]*$/.test(decl.headerName) ||
        FORBIDDEN_CREDENTIAL_HEADER_NAMES.has(normalized) ||
        RESPONSE_HEADER_ALLOWLIST.has(normalized)
      ) {
        return { kind: "reject", reason: "invalid_credential_decl" };
      }
    }
    let bestLen = -1;
    for (const pattern of decl.scope) {
      if (scopeMatches(url, pattern)) {
        bestLen = Math.max(bestLen, scopePrefix(pattern).length);
      }
    }
    if (bestLen >= 0) {
      hits.push({
        ref,
        via: decl.type,
        queryParam: decl.queryParam,
        headerName: decl.headerName,
        prefixLen: bestLen,
      });
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

  const decision: Extract<InjectionDecision, { kind: "inject" }> = {
    kind: "inject",
    ref: best.ref,
    via: best.via,
  };
  if (best.queryParam !== undefined) decision.queryParam = best.queryParam;
  if (best.headerName !== undefined) decision.headerName = best.headerName;
  return decision;
}
