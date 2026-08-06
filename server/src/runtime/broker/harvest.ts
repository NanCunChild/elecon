/**
 * 耐久 cookie 收割桥接（Gate A · B5）—— ADR-009 §2.4（判据 b + 收割方向匹配）/ ADR-012 §2.4。
 *
 * 单次执行结束时，把 B4 jar **origin 区**里「manifest 显式声明为凭证」的耐久 cookie
 * 收割进 ADR-012 凭证库，供后续执行注入复用。瞬态 cookie（挑战 nonce、握手中途 token、
 * ephemeral 区）一律丢弃——**判据 b**：只收 manifest `credentials.<ref>`（`type: cookie`）
 * 声明 ref 命中 scope 的 cookie。
 *
 * **ref ↔ cookie 名映射（路线 a，2026-06-16 拍板）**：manifest credentials 不含 cookie 名；
 * 一个 ref 的值 = 其 scope 命中的**全部** origin cookie 序列化串（`n1=v1; n2=v2`，
 * RFC 6265 §5.4 发送序：path 长者先，同长按名）。注入时（B6）原样附加为 Cookie 头。
 *
 * `decideHarvest` 纯（golden 双跑钉两端）；`harvestInto` 薄桥接到 CredentialStore。
 *
 * 不含（划走）：收割**触发时机**（执行结束调用点属 B6）；ephemeral 区（结构上不可达，
 * 输入仅 `harvestView()` origin 区）；WebView 收割（ADR-012 §2.2）。
 *
 * expiresAt：本件一律 `null`（session 语义）——精确生命周期须 Max-Age/Expires，但 B4 jar
 * 未捕获该属性（见 b5 计划 §8 #2，路线选 null + 靠 §2.5 401-重登兜底，跑通优先）。
 *
 * 🔒 红线 #1 承重路径（凭证入核心库）：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环。
 */

import { scopeMatches } from "@elecon/broker-primitives";
import type { CredentialEntry } from "../credential/types.js";
import { compareCookiePathName, type JarCookie, matchCookieForSend } from "./cookie-jar.js";
import { parseTemplateHostPath } from "./cookie-match.js";
import type { BrokerManifestView } from "./inject-policy.js";

/** 收割计划项：一个凭证 ref 及其序列化后的 cookie 值。 */
export interface HarvestEntry {
  ref: string;
  /** scope 命中的全部 origin cookie 序列化串（路线 a）：`n1=v1; n2=v2`。 */
  value: string;
}

export type HarvestPlan = HarvestEntry[];

/** 桥接写入目标（CredentialStore 满足之）。 */
export interface HarvestSink {
  put(entry: CredentialEntry): void;
}

/** 桥接所需执行上下文（B6 运行时提供）。 */
export interface HarvestContext {
  schoolId: string;
  now: () => number;
}

/** URL query 收割目标；注入 view 与收割 view 可分离（ADR-020 §2.3，SSO mint 必需）。 */
export interface QueryHarvestTarget extends HarvestContext {
  view: BrokerManifestView;
  sink: HarvestSink;
}

/** 某 scope 模板的代表性 URL（scheme 不影响 domain/path 匹配，取 https）。 */
function scopeReprUrl(scope: string): string | null {
  const p = parseTemplateHostPath(scope);
  if (!p) return null;
  return `https://${p.host}${p.pathPrefix}`;
}

/** 序列化命中 cookie（RFC 6265 §5.4：path 长者先，同长按名升序），`n=v` 以 `; ` 连。 */
function serialize(cookies: JarCookie[]): string {
  return [...cookies]
    .sort(compareCookiePathName)
    .map((c) => `${c.name}=${c.value}`)
    .join("; ");
}

/**
 * 决定 origin 区哪些 cookie 收割、归属哪个 ref（纯，judge b + 收割方向匹配）。
 *
 * 对每个 `type: "cookie"` 的 ref：其 scope 任一前缀的代表 URL 被某 origin cookie
 * `matchCookieForSend` 命中（domainMatch(scopeHost, cookieDomain) ∧ cookiePath 为 scope
 * pathPrefix 前缀，ADR-009 §2.4 第 122–124 行）→ 该 cookie 归此 ref。
 *
 * `type: "header"` ref 不参与 cookie 收割。未被任何 ref 命中的 cookie → 瞬态，丢弃。
 * 一个父域共享 cookie 若同时落在多个 ref 的 scope，会**分别**收割进各 ref（各自的凭证束
 * 都合法含它；下次执行 B1 按最长前缀选 ref 注入，仍带该 cookie）。
 * 计划项按 ref 名升序；无命中的 ref 不产出空项。
 */
export function decideHarvest(originCookies: JarCookie[], view: BrokerManifestView): HarvestPlan {
  const plan: HarvestPlan = [];

  // 纵深防御（栅栏 3）：只收 origin 区。正常输入是 jar.harvestView()（已仅 origin），
  // 但本函数不信任上游——即便误传入 ephemeral cookie，也在此丢弃，绝不入库。
  const harvestable = originCookies.filter((c) => c.source === "origin");

  for (const [ref, decl] of Object.entries(view.credentials ?? {})) {
    if (decl.type !== "cookie") continue;

    const reprUrls = decl.scope.map(scopeReprUrl).filter((u): u is string => u !== null);
    const matched = harvestable.filter((c) =>
      reprUrls.some((u) => matchCookieForSend({ domain: c.domain, path: c.path, hostOnly: c.hostOnly }, u)),
    );
    if (matched.length === 0) continue;

    plan.push({ ref, value: serialize(matched) });
  }

  return plan.sort((a, b) => (a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0));
}

/**
 * 从核心已接受的 URL 收割 query credential（ADR-020 §2.3）。
 * 重复同名参数拒绝收割，避免两端首/末值差异；fragment 由 URL API 天然忽略。
 */
export function decideQueryHarvest(url: string, view: BrokerManifestView): HarvestPlan {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return [];
  }

  const plan: HarvestPlan = [];
  for (const [ref, decl] of Object.entries(view.credentials ?? {})) {
    if (decl.type !== "query" || decl.queryParam === undefined) continue;
    if (!decl.scope.some((scope) => scopeMatches(url, scope))) continue;
    const values = parsed.searchParams.getAll(decl.queryParam);
    if (values.length !== 1 || values[0] === "") continue;
    plan.push({ ref, value: values[0]! });
  }
  return plan.sort((a, b) => (a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0));
}

/** 收割一个核心已接受的 URL；不保存完整 URL，只把裸凭证值写入核心 store。 */
export function harvestQueryUrl(url: string, target: QueryHarvestTarget): void {
  harvestInto(decideQueryHarvest(url, target.view), target.view, target.sink, target);
}

/**
 * 把收割计划写入凭证库（薄桥接）。每项构造 `CredentialEntry`：注入权威字段（type/scope）
 * 以**已验签 manifest**为准、store 仅防御性副本（ADR-012 §2.4）；同 ref 已存在 → put 覆盖
 * （会话轮换）。expiresAt=null（见文件头）。
 */
export function harvestInto(
  plan: HarvestPlan,
  view: BrokerManifestView,
  sink: HarvestSink,
  ctx: HarvestContext,
): void {
  for (const { ref, value } of plan) {
    const decl = view.credentials?.[ref];
    if (!decl) continue; // 计划只来自 decideHarvest，理论上恒有；防御性跳过
    sink.put({
      ref,
      schoolId: ctx.schoolId,
      type: decl.type,
      scope: [...decl.scope], // 防御性副本
      value,
      acquiredAt: ctx.now(),
      expiresAt: null,
      status: "active",
    });
  }
}
