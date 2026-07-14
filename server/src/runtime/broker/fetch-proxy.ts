/**
 * 受限 `ctx.fetch` 代理驱动（Gate A · B6a）—— ADR-009 §2.1 数据流的**有态编织层**。
 * 把已落地纯零件串成一次真正可跑的出站请求 + 核心自跟随重定向：
 *
 *   ① B1 decideInjection(url, view)         —— reject→fail-closed / passthrough / inject
 *   ② resolver.get(ref)（仅 inject）+ B4 jar.selectForSend(url)
 *   ③ assembleRequest（净化 adapter 头 → 叠 broker 凭证 → 合流 jar cookie）
 *   ④ transport.fetch(req)  [seam]          —— 真实出网属 ADR-003，B6a 经 seam 注入 fake 驱动 smoke
 *   ⑤ jar.captureSetCookie(resp, url)       —— 每跳都吃 Set-Cookie（含重定向链）
 *   ⑥ B3 decideRedirect 自驱跟随            —— 每跳重做 ①–⑤；中间 Location 绝不外泄
 *   ⑦ processResponse（响应脱敏）→ 交回 adapter
 *
 * **为何自驱循环而非复用 B3 followRedirects**：followRedirects 只回元信息（status/finalUrl/hops），
 * 不带 body/响应头，且不在每跳重做注入决策 + 捕获 Set-Cookie。B6a 需「逐跳完整管线」，故复用
 * B3 的**纯决策** decideRedirect 自驱，与「复用 B3 思路」一致（计划 §8 #4）。
 *
 * **限额计量口径（计划 §8 #3 拍板）**：重定向链总耗时计入单请求 10s（墙钟在 B6b 落）；
 * **每跳各计一次请求**（含重定向跳），计入单次执行 ≤20 预算——防重定向放大。本驱动据此
 * 暴露 `requestCount`（=transport.fetch 调用数），由 B6b 运行时累加并硬执行 30s/20-req/10s。
 * B6a 只硬执行**单请求内的跳数上限**（maxHops，默认 5，复用 B3）。
 *
 * 不含（划到 B6b）：异步 handler（job queue pump/await）、累计 30s/单次≤20 的执行级硬执行、
 * 墙钟超时、执行结束 B5 收割钩子。本驱动是同步可测的「单次 ctx.fetch」管线。
 *
 * 🔒 红线 #1 凭证注入 + 出网承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import { assembleRequest, type ProcessedResponse, processResponse, type RequestInit } from "./assemble.js";
import type { CookieJar } from "./cookie-jar.js";
import type { HeaderMap } from "./header-sanitize.js";
import { type BrokerManifestView, decideInjection } from "./inject-policy.js";
import type { CredentialResolver } from "./ports.js";
import { DEFAULT_MAX_REDIRECTS, decideRedirect } from "./redirect.js";

/** 统一 transport seam（复用 B3 RedirectFetcher 思路）。真实实现属 ADR-003，另件注入。 */
export interface TransportRequest {
  url: string;
  method: string;
  headers: HeaderMap;
  body?: string;
}

export interface TransportResponse {
  status: number;
  headers: HeaderMap;
  /** origin 下发的 `Set-Cookie`（每跳，含重定向）。host 侧捕获，绝不交 adapter。 */
  setCookie: string[];
  /** 响应 `Location` 头（重定向用）；无则 null。绝不外泄给 adapter（脱敏剥除）。 */
  location: string | null;
  body?: string;
}

export interface Transport {
  fetch(req: TransportRequest, signal?: AbortSignal): Promise<TransportResponse>;
}

export class TransportBodyLimitExceeded extends Error {
  constructor(public readonly maxBytes: number) {
    super(`transport response body exceeds limit (${maxBytes} bytes)`);
    this.name = "TransportBodyLimitExceeded";
  }
}

/** url 不在 allow → fail-closed 受控错误（绝不附凭证、绝不发请求）。 */
export class BrokerFetchRejected extends Error {
  constructor(public readonly reason: string) {
    super(`ctx.fetch 被 broker 拒绝（${reason}）`);
    this.name = "BrokerFetchRejected";
  }
}

export interface FetchProxyDeps {
  view: BrokerManifestView;
  resolver: CredentialResolver;
  jar: CookieJar;
  transport: Transport;
  /** 单请求内最大重定向跳数（默认 5，ADR-009 §2.5）。 */
  maxHops?: number;
  /** 单次 ctx.fetch 的取消信号；运行时在超时/fatal 时主动中止上游。 */
  signal?: AbortSignal;
}

export interface FetchProxyOutcome extends ProcessedResponse {
  /** 实际 transport.fetch 调用次数（含重定向跳）；B6b 据此累加 ≤20 执行预算（计划 §8 #3）。 */
  requestCount: number;
}

/**
 * 驱动一次 `ctx.fetch(url, init)`。reject → 抛 {@link BrokerFetchRejected}（fail-closed）。
 * 重定向由核心自跟随（每跳重做注入决策 + 捕获 Set-Cookie + allow 校验）；交回 adapter 的
 * 响应已脱敏（Set-Cookie/Authorization/Location 剥除），中间跳转对 adapter 全程不可见。
 */
export async function proxyFetch(
  url: string,
  init: RequestInit,
  deps: FetchProxyDeps,
): Promise<FetchProxyOutcome> {
  const { view, resolver, jar, transport } = deps;
  const maxHops = deps.maxHops ?? DEFAULT_MAX_REDIRECTS;

  let currentUrl = url;
  let method = (init.method ?? "GET").toUpperCase();
  let body = init.body;
  // 仅首跳带 adapter 自设头/ body；重定向跳由核心控制，不回灌 adapter 头（防中间态外泄）。
  let headers: HeaderMap | undefined = init.headers;
  let hops = 0;
  let requestCount = 0;

  for (;;) {
    // ①–③ 每跳重做注入决策 + 取值 + 选 jar cookie + 拼装（每跳须仍在 allow 内，由 ① 守）。
    const decision = decideInjection(currentUrl, view);
    if (decision.kind === "reject") {
      throw new BrokerFetchRejected(decision.reason);
    }
    const resolved = decision.kind === "inject" ? await resolver.get(decision.ref) : null;
    const jarCookies = jar.selectForSend(currentUrl);
    const reqInit: RequestInit = { method };
    if (headers !== undefined) reqInit.headers = headers;
    if (body !== undefined) reqInit.body = body;
    const assembled = assembleRequest({ init: reqInit, decision, resolved, jarCookies });
    // 拼装层也可 fail-closed：inject 但 resolver 未命中 → reject(credential_unavailable)。
    // 任一 reject 都转受控错误（绝不发请求、绝不附凭证）。
    if (assembled.kind === "reject") {
      throw new BrokerFetchRejected(assembled.reason);
    }

    // ④ 出网（seam）+ ⑤ 吃 Set-Cookie。
    const treq: TransportRequest = {
      url: currentUrl,
      method: assembled.method,
      headers: assembled.headers,
    };
    if (assembled.body !== undefined) treq.body = assembled.body;
    const resp = await transport.fetch(treq, deps.signal);
    requestCount++;
    jar.captureSetCookie(resp.setCookie, currentUrl);

    // ⑥ 重定向决策（纯，复用 B3）。deliver/stop → 交付当前响应；follow → 续跳。
    const rd = decideRedirect({
      status: resp.status,
      location: resp.location,
      currentUrl,
      allow: view.allow,
      hopsSoFar: hops,
      maxHops,
    });
    if (rd.kind === "deliver" || rd.kind === "stop") {
      // ⑦ 脱敏后交回 adapter（含 stop：越界/超跳时交付当前响应，其 Location 由脱敏剥除）。
      return { ...processResponse(resp), requestCount };
    }

    // 续跳：307/308 保留方法+ body，余者转 GET 且弃 body；重定向跳不回灌 adapter 头。
    currentUrl = rd.nextUrl;
    if (rd.method === "get") {
      method = "GET";
      body = undefined;
    }
    headers = undefined;
    hops++;
  }
}
