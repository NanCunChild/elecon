/**
 * Broker 重定向核心跟随（Gate A · B3）—— ADR-009 §2.1 第 3 步 / §2.5。
 *
 * 核心**自行**跟随重定向；adapter 全程**看不到中间跳转**：
 *   - **每跳须仍在 `network.allow` 内**，越界即停止、交付当前响应（绝不跟随出 allow——
 *     中间 `Location` 可能含 token，跟随出 allow = 数据外泄面，红线 #1）。
 *   - **最多 `maxHops` 跳**（默认 5，ADR-009 §2.5），超限即停。
 *   - **中间 `Location` 绝不外泄**：driver 只返回**最终**响应；中间响应（及其 Location）丢弃。
 *
 * `decideRedirect` 是纯策略（golden 双跑钉两端一致）；`followRedirects` 是异步驱动，
 * 经注入 `RedirectFetcher`（真实发请求属 B6/transport）跟随。
 *
 * 🔒 红线 #1 数据外泄面：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import { urlCoveredByAllow } from "@elecon/broker-primitives";

/** 自动跟随的重定向状态码（300/304/305/306 不在内）。 */
const REDIRECT_STATUSES: ReadonlySet<number> = new Set([301, 302, 303, 307, 308]);

/**
 * URL 重写的会话矩阵参数 `;jsessionid=…`（ADR-027）。跟随前剥离：
 *   1. 红线 #1：会话令牌在 URL 里 = 数据外泄面（Referer/日志/历史泄漏）；
 *   2. 正确性：带 `;jsessionid=` 跟随命中 Tomcat URL-rewrite 分支、不下发 cookie 会话，
 *      后续 clean-URL 请求丢会话（ehall jwapp 403）。剥离后落到干净 URL 触发 Set-Cookie，
 *      会话回归 CookieJar（核心持有，adapter 全程不见）。
 * 只匹配矩阵参数形态（分号前缀），不动查询串 `?jsessionid=`。
 */
const URL_REWRITTEN_SESSION_PARAM = /;jsessionid=[^/?#;]*/gi;

/** 默认最大跳数（ADR-009 §2.5）。 */
export const DEFAULT_MAX_REDIRECTS = 5;

export interface RedirectInput {
  status: number;
  /** 响应的 Location 头；无则 null。 */
  location: string | null;
  /** 当前请求 URL（用于解析相对 Location）。 */
  currentUrl: string;
  allow: string[];
  /** 已跟随的跳数。 */
  hopsSoFar: number;
  maxHops: number;
}

export type RedirectStopReason = "max_hops" | "outside_allow" | "unresolvable_location";

export type RedirectDecision =
  /** 非重定向 / 无 Location → 当前即最终响应，交付 adapter。 */
  | { kind: "deliver" }
  /** 跟随到 nextUrl（已解析为绝对、已过 allow 校验）。 */
  | { kind: "follow"; nextUrl: string; method: "preserve" | "get" }
  /** 想跟随但被策略拦截 → 停止，交付当前响应（其 Location 由 B2 脱敏剥除）。 */
  | { kind: "stop"; reason: RedirectStopReason };

/**
 * 单跳重定向决策（纯函数）。
 * 顺序：非重定向→deliver；超跳数→stop(max_hops)；Location 不可解析→stop；
 * 解析后越 allow→stop(outside_allow)；否则 follow（307/308 保留方法，余者转 GET）。
 */
export function decideRedirect(input: RedirectInput): RedirectDecision {
  const { status, location, currentUrl, allow, hopsSoFar, maxHops } = input;

  if (!REDIRECT_STATUSES.has(status) || location === null || location === "") {
    return { kind: "deliver" };
  }
  if (hopsSoFar >= maxHops) {
    return { kind: "stop", reason: "max_hops" };
  }

  let nextUrl: string;
  try {
    // ADR-027：剥离 URL 重写会话参数（在 allow 校验前，使校验作用于干净 URL）。
    nextUrl = new URL(location, currentUrl).href.replace(URL_REWRITTEN_SESSION_PARAM, "");
  } catch {
    return { kind: "stop", reason: "unresolvable_location" };
  }

  if (!urlCoveredByAllow(nextUrl, allow)) {
    return { kind: "stop", reason: "outside_allow" };
  }

  const method = status === 307 || status === 308 ? "preserve" : "get";
  return { kind: "follow", nextUrl, method };
}

/** 单跳取数结果（driver 内部用；真实实现属 B6/transport）。 */
export interface RedirectHop {
  status: number;
  location: string | null;
}

/** 发一跳请求的 seam。`method`：initial=首跳用原方法；preserve/get=重定向后的方法。 */
export interface RedirectFetcher {
  fetch(url: string, method: "initial" | "preserve" | "get"): Promise<RedirectHop>;
}

/**
 * 跟随结果。**结构上不含任何 Location / 中间 URL**——「中间 Location 不外泄」的体现：
 * 调用方只拿到最终 URL + 状态 + 跳数（+ 停止原因）。
 */
export interface FollowOutcome {
  finalUrl: string;
  status: number;
  hops: number;
  /** null = 正常交付；否则为被拦截的停止原因。 */
  stopReason: RedirectStopReason | null;
}

/**
 * 核心自跟随重定向（异步驱动）。只返回**最终**响应的元信息；中间响应/Location 丢弃。
 * 真实 body/响应头另由 B6 取并经 B2 脱敏后交 adapter——本驱动只负责跟随策略与跳转控制。
 */
export async function followRedirects(
  startUrl: string,
  fetcher: RedirectFetcher,
  opts: { allow: string[]; maxHops?: number },
): Promise<FollowOutcome> {
  const maxHops = opts.maxHops ?? DEFAULT_MAX_REDIRECTS;
  let url = startUrl;
  let hops = 0;
  let method: "initial" | "preserve" | "get" = "initial";

  for (;;) {
    const hop = await fetcher.fetch(url, method);
    const decision = decideRedirect({
      status: hop.status,
      location: hop.location,
      currentUrl: url,
      allow: opts.allow,
      hopsSoFar: hops,
      maxHops,
    });

    if (decision.kind === "deliver") {
      return { finalUrl: url, status: hop.status, hops, stopReason: null };
    }
    if (decision.kind === "stop") {
      return { finalUrl: url, status: hop.status, hops, stopReason: decision.reason };
    }

    url = decision.nextUrl;
    method = decision.method;
    hops++;
  }
}
