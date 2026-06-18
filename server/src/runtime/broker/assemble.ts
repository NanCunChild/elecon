/**
 * Broker 请求拼装 / 响应脱敏（Gate A · B6a）—— ADR-009 §2.1 数据流的「拼头」与「脱敏」两端，
 * 编织已落地零件（B1 决策 / B2 净化 / B4 jar 选 cookie / resolver 取值），但**保持纯函数**：
 * 入参是**已经算好的** decision（B1）+ resolved 凭证值（resolver）+ jarCookies（B4 selectCookies），
 * 不发请求、不碰 async、不碰 jar 内部态——故可 golden 双跑钉两端一致（Dart 后续对齐，ADR-001 §8）。
 * 有态驱动（decideInjection→resolver.get→selectCookies→transport→redirect→capture）属 ./fetch-proxy.ts。
 *
 * **拼装次序（安全要点）**：
 *   ① B2 sanitizeRequestHeaders 先作用于 **adapter 自设头**——无条件剥 adapter 的
 *      Cookie/Authorization（纵深防御，红线 #1：adapter 永不能自带凭证），其余 allowlist。
 *   ② broker 凭证在**净化后的干净底座之上**叠加——若颠倒，broker 注入的 Cookie/Authorization
 *      会被 §① 的 denylist 一并剥掉。故净化在前、注入在后。
 *   ③ Cookie 合流优先级 **broker 注入 > origin > ephemeral**（ADR-009 §2.4 栅栏 2；jar 内部
 *      origin>ephemeral 已由 selectCookies 落实，本模块再让 broker 注入名压过 jar 同名）。
 *
 * `processResponse` = B2 sanitizeResponseHeaders（剥 Set-Cookie/Authorization 回显 + 非 allowlist
 * 头含 Location；body 透传为 ADR-009 §2.5 已接受风险）。
 *
 * 🔒 红线 #1 凭证注入承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import type { CredentialVia, InjectionDecision, RejectReason } from "./inject-policy.js";
import {
  sanitizeRequestHeaders,
  sanitizeResponseHeaders,
  type HeaderMap,
} from "./header-sanitize.js";

/** 出站 cookie 对（B4 `selectCookies` 的输出形；不外泄 domain/path/source）。 */
export interface CookiePair {
  name: string;
  value: string;
}

/** 已解析的凭证（resolver.get 的产出；`value` 仅核心可见，绝不回交 adapter）。 */
export interface ResolvedCredential {
  via: CredentialVia;
  value: string;
}

/** adapter 经 `ctx.fetch(url, init)` 传入的请求意图（host 侧已把 headers 归一为 HeaderMap）。 */
export interface RequestInit {
  method?: string;
  headers?: HeaderMap;
  body?: string;
}

export interface AssembleRequestInput {
  init: RequestInit;
  /** B1 decideInjection(url, view) 的结果。 */
  decision: InjectionDecision;
  /**
   * resolver.get(decision.ref) 的结果；仅 inject 时有值。
   * null 含义：① 非 inject（passthrough）；② inject 但凭证缺失/失效（resolver 未命中）。
   * 后者见下方「凭证缺失」处置（🔒 开放点，PR 待人工拍板）。
   */
  resolved: ResolvedCredential | null;
  /** B4 `jar.selectForSend(url)` 的输出（origin+ephemeral 已合并去重）。 */
  jarCookies: readonly CookiePair[];
}

/**
 * 拼装层的 fail-closed 理由。
 * - `outside_allow` / `ambiguous_scope`：B1 decideInjection 的 reject 透传。
 * - `credential_unavailable`：B1 判 inject 但 resolver 未命中（凭证缺失/过期/吊销）。
 *   非 B1 产物，由本层引入——见 assembleRequest 文档。
 */
export type AssembleRejectReason = RejectReason | "credential_unavailable";

export type AssembleResult =
  /** url 不在 allow（B1 reject）/ 声明要的凭证取不到 → fail-closed，凭证一律不附，驱动层转受控错误。 */
  | { kind: "reject"; reason: AssembleRejectReason }
  | { kind: "ok"; method: string; headers: HeaderMap; body?: string };

/** 解析序列化 cookie 串（`A=1; B=2`）为有序对。空段/无 `=` 段跳过。 */
function parseCookieString(s: string): CookiePair[] {
  const out: CookiePair[] = [];
  for (const seg of s.split(";")) {
    const part = seg.trim();
    if (part === "") continue;
    const eq = part.indexOf("=");
    if (eq <= 0) continue;
    out.push({ name: part.slice(0, eq).trim(), value: part.slice(eq + 1).trim() });
  }
  return out;
}

/**
 * 拼装出站请求（纯）。
 *
 * - reject → 原样回传（驱动层据此 fail-closed，绝不发请求、绝不附凭证）。
 * - 否则：净化 adapter 头 → 据 decision/resolved 叠加 broker 凭证 → 合流 jar cookie。
 *
 * **凭证缺失（inject 但 resolved===null）→ fail-closed（reject `credential_unavailable`）。**
 * B1 判 inject 意味着 manifest 作者**显式声明**该 URL 需登录态；凭证取不到（缺失/过期/吊销）
 * 却照发，大概率换回 401/登录重定向——拿不到正确数据，反而白耗一次请求 + 往返、可能收割
 * 登录页垃圾 cookie，并把「会话过期/被吊销/从未登录」压成 adapter 无从区分的模糊 401。
 * 故拒发，给驱动层/宿主一个**确定、可操作**的信号 → 触发 ADR-012 §2.5 续期 / §2.2 重新登录。
 * 不发凭证永不泄露（红线 #1 两种选择都安全），此为健壮性裁定，非安全裁定。渐进增强端点
 * （无凭证也给公开数据）应在 manifest 不入凭证 scope 来表达，不靠运行时反猜作者意图。
 * （2026-06-18 人工采纳 fail-closed；此前为「不伪造 + 照发」。）
 */
export function assembleRequest(input: AssembleRequestInput): AssembleResult {
  const { init, decision, resolved, jarCookies } = input;

  if (decision.kind === "reject") {
    return { kind: "reject", reason: decision.reason };
  }

  // 凭证缺失 fail-closed：声明要注入但 resolver 未命中 → 拒发（见上方文档）。
  if (decision.kind === "inject" && resolved === null) {
    return { kind: "reject", reason: "credential_unavailable" };
  }

  // ① 净化 adapter 自设头：无条件剥 Cookie/Authorization/Proxy-Authorization，其余 allowlist。
  const headers: HeaderMap = sanitizeRequestHeaders(init.headers ?? {});

  // ② broker 凭证在干净底座上叠加（仅 inject 且 resolver 命中时）。
  const injectCookie =
    decision.kind === "inject" && decision.via === "cookie" && resolved !== null
      ? parseCookieString(resolved.value)
      : [];
  if (decision.kind === "inject" && decision.via === "header" && resolved !== null) {
    headers["Authorization"] = resolved.value;
  }

  // ③ Cookie 合流：broker 注入名优先，其后补 jar（origin>ephemeral 已由 selectCookies 落实）。
  const seen = new Set<string>();
  const cookiePairs: CookiePair[] = [];
  for (const p of injectCookie) {
    if (seen.has(p.name)) continue;
    seen.add(p.name);
    cookiePairs.push(p);
  }
  for (const p of jarCookies) {
    if (seen.has(p.name)) continue;
    seen.add(p.name);
    cookiePairs.push(p);
  }
  if (cookiePairs.length > 0) {
    headers["Cookie"] = cookiePairs.map((p) => `${p.name}=${p.value}`).join("; ");
  }

  const method = (init.method ?? "GET").toUpperCase();
  return init.body === undefined
    ? { kind: "ok", method, headers }
    : { kind: "ok", method, headers, body: init.body };
}

export interface RawResponse {
  status: number;
  headers: HeaderMap;
  body?: string;
}

export interface ProcessedResponse {
  status: number;
  headers: HeaderMap;
  body?: string;
}

/**
 * 响应脱敏（纯，交回 adapter 前）。响应头按 allowlist 保留——`Set-Cookie`（已由 jar 在上游捕获）、
 * `Authorization` 回显、`Location`（可能含 token）一律丢弃（红线 #1）。**status 原样透传**（含 401，
 * ADR-009 §2 第 6 条）；body 透传为 §2.5 已接受风险。
 */
export function processResponse(resp: RawResponse): ProcessedResponse {
  const headers = sanitizeResponseHeaders(resp.headers);
  return resp.body === undefined
    ? { status: resp.status, headers }
    : { status: resp.status, headers, body: resp.body };
}
