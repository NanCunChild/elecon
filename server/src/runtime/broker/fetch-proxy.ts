/**
 * 受限 `ctx.fetch` 代理驱动（Gate A · B6a）—— ADR-009 §2.1 数据流的**有态编织层**。
 * 把已落地纯零件串成一次真正可跑的出站请求 + 核心自跟随重定向：
 *
 *   ① B1 decideInjection(url, view)         —— reject→fail-closed / passthrough / inject
 *   ② resolver.get(ref)（仅 inject）+ B4 jar.selectForSend(url)
 *   ③ assembleRequest（净化 adapter 头 → 叠 broker 凭证 → 合流 jar cookie）
 *   ④ transport.fetch(req)  [seam]          —— 真实出网属 ADR-003，B6a 经 seam 注入 fake 驱动 smoke
 *   ⑤ 取消检查 + B3 decideRedirect           —— blocked 响应零副作用、不可交付
 *   ⑥ follow/deliver 才 capture Set-Cookie   —— 每跳重做 ①–⑥；中间 Location 绝不外泄
 *   ⑦ deliverThroughFirewall（C1 唯一 choke point）→ 交回 adapter
 *
 * **C1 交付接线（ADR-026 §2.4，checklist C1）**：交回 adapter 的**唯一**出口不再是裸
 * `processResponse`，而是统一 delivery firewall `deliverThroughFirewall`——即便无 Masker 策略命中
 * 也强制经此 choke point（空规则 → Masker no-op + ⑧ header 脱敏，与旧 `processResponse` 逐字节
 * 等价），使 imperative 入口「无策略也无旁路」为**结构**保证。Masker 策略经 `deps.masker`
 * 注入（`policy`/`sink`/`ctx` 三者同在，防「有规则无落点」）；缺省 = 无策略、透明交付——
 * **但 official 装配缺省即拒载**（判定在 sandbox / loader 入口，ADR-026 §2.7）。
 * **owner 决议已处置（2026-08-05）**：① **A3 真实判定已接入**——`transportDecodeOk` 取自
 * `resp.decodeOk ?? true`（生产 transport 按 charset + `fatal` UTF-8 解码给出，见 `transport/direct.ts`；
 * 缺省 fake transport 按 true）；⑦ **注入凭证回显不做反射检测**（owner 拍板：短字符反射误报，交
 * Masker `redact` 承担），故此处**不**传 `injectedValues`、维持不 strip。
 * **② Policy 匹配已接线（2026-09-12，ADR-026 §2.7.1 落地）**：`deps.masker.policy` 为签名
 * `masker.json` 的严格解析结果（`masker-policy.ts`），每次 deliver 按 (capability, 最后一跳 method,
 * 最终 URL, requestKey) 由 `selectMaskerRules` 选出规则再入 firewall。sink/store 装配仍由宿主提供。
 * **P1-04**：传输层折叠前记录的 `repeatedHeaders` 原样送入 firewall（Masker 据此判 `capture_ambiguous`）。
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

import { assembleRequest, type ProcessedResponse, type RequestInit } from "./assemble.js";
import type { CookieJar } from "./cookie-jar.js";
import { deliverThroughFirewall } from "./delivery-firewall.js";
import { harvestQueryUrl, type QueryHarvestTarget } from "./harvest.js";
import type { HeaderMap } from "./header-sanitize.js";
import { type BrokerManifestView, decideInjection } from "./inject-policy.js";
import type { MaskerCommitContext, MaskerCommitSink } from "./masker-commit.js";
import { type MaskerPolicy, selectMaskerRules } from "./masker-policy.js";
import type { CredentialResolver } from "./ports.js";
import { DEFAULT_MAX_REDIRECTS, decideRedirect } from "./redirect.js";

/**
 * 缺省（无 Masker 策略）交付：空规则 → `applyResponseMasker` 无收割，故 sink 永不被调用；
 * 传占位实体仅为满足 firewall 交付事务签名。**绝不**以此占位承接真实收割——真实策略必经
 * `deps.masker` 三件套一并注入（见 {@link FetchProxyDeps.masker}）。
 */
const NOOP_MASKER_SINK: MaskerCommitSink = { put() {} };
const NOOP_MASKER_CTX: MaskerCommitContext = { schoolId: "", now: () => 0 };

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
  /**
   * 传输层**解码后的明文 body**（UTF-8）。Response Masker（ADR-026）只在此明文上运行，
   * **绝不猜测编码**：`Content-Encoding` 解压与字符集解码是传输层职责，非法 / 非 UTF-8 body
   * 必须在此边界 fail-closed 拒交付，不得把原始字节交给 Masker 或 adapter（ADR-026 §2.8 / A3）。
   */
  body?: string;
  /**
   * **A3 明文判定**（ADR-026 §2.8）：传输层是否确认 body 为合法 UTF-8 明文——`content-type`
   * 声明（或默认）UTF-8 且字节通过 `fatal` 解码。非 UTF-8 charset / 非法字节 → `false`（**绝不
   * 猜测转码**）。缺省（`undefined`）由消费方按 `true` 处理（向后兼容 fake transport / 既有测试）；
   * 生产 transport 必置真值，`false` 时 firewall 以 `body_not_plaintext` fail-closed。
   */
  decodeOk?: boolean;
  /**
   * **P1-04 原始基数**：线上出现 ≥2 次的响应头名（小写，不含 Set-Cookie——它单独走 `setCookie`）。
   * `headers` 是按 HTTP 语义折叠后的单值视图；折叠会抹掉「两个同名 token 头」这一歧义证据，
   * 故传输层须在折叠**前**记录。firewall 原样送入 Masker，header 源命中即 `capture_ambiguous`。
   * 仅在 {@link TransportResponse.headerCardinalityAttested} 为 `true` 时有意义。
   */
  repeatedHeaders?: string[];
  /**
   * **P1-04 基数可证明性**：传输层是否能证明每个响应头名在线上出现的次数。
   *
   * `true` → {@link TransportResponse.repeatedHeaders} 是完整的重复名集合（空 = 无重复）。
   * `false` / 缺省 → **无法证明**，firewall 对任何 header 源 Masker 规则 fail-closed
   * （`header_cardinality_unattested`）——绝不拿折叠后的合并值当单值凭证收割。
   *
   * 平台现状：Dart `HttpHeaders.forEach` 逐名给出 `List<String>`，客户端可证明；服务端
   * WHATWG `fetch` 的 `Headers` 在读到之前就已把同名头折叠成 `"a, b"` 且无原始访问，故
   * 服务端 `DirectTransport` 恒为 `false`。要在服务端跑 header 源规则须换传输实现
   * （ADR-003 范畴）或引入可读原始头的 HTTP 客户端（红线 #9），届时另开 ADR。
   */
  headerCardinalityAttested?: boolean;
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
  /** 执行级预算所有者在每次真实 transport hop 前原子预留一个名额（ADR-009 §2.8）。 */
  reserveRequest?: () => void;
  /** 每个通过 allow 校验、确定跟随的重定向目标由核心收割 query credential（ADR-020 §2.3）。 */
  queryHarvest?: QueryHarvestTarget;
  /**
   * ⑦ Response Masker 交付事务（C1 firewall + ② Policy 匹配）。**三件套同在**（`policy`/`sink`/`ctx`）
   * 以防「有规则无落点」漏收割：`policy` = 已验签 `masker.json` 的严格解析（`parseMaskerPolicy`），
   * 每次 deliver 按 `capability` / `requestKey` / 最后一跳 method / 最终 URL 选规则；`sink`/`ctx` = ⑥ Commit
   * 目标（真实 Store 原子性 = C2 seam）。**缺省 = 无策略**：响应仍强制经 firewall（空规则 no-op +
   * header 脱敏）、无旁路；official 装配缺省即由入口拒载（sandbox / loader，ADR-026 §2.7）。
   * 🔒 红线 #1：装配此三件套（含 store）须人工主导、不得 AI 独自闭环。
   */
  masker?: FetchProxyMasker;
}

/** `deps.masker` 三件套 + 选规则上下文。 */
export interface FetchProxyMasker {
  policy: MaskerPolicy;
  /** 本次执行的 capability（manifest 权威能力集内）。 */
  capability: string;
  /** declarative 逻辑请求 key；imperative `ctx.fetch` 缺省（带 requestKey 的规则永不命中）。 */
  requestKey?: string;
  sink: MaskerCommitSink;
  ctx: MaskerCommitContext;
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
    const assembled = assembleRequest({ url: currentUrl, init: reqInit, decision, resolved, jarCookies });
    // 拼装层也可 fail-closed：inject 但 resolver 未命中 → reject(credential_unavailable)。
    // 任一 reject 都转受控错误（绝不发请求、绝不附凭证）。
    if (assembled.kind === "reject") {
      throw new BrokerFetchRejected(assembled.reason);
    }

    // ④ 出网（seam）。
    const treq: TransportRequest = {
      url: assembled.url ?? currentUrl,
      method: assembled.method,
      headers: assembled.headers,
    };
    if (assembled.body !== undefined) treq.body = assembled.body;
    // 预算必须在每个真实 hop 出网前预留；重定向与并发 ctx.fetch 共用宿主执行级计数器。
    deps.reserveRequest?.();
    const resp = await transport.fetch(treq, deps.signal);
    // ADR-009 §2.5 修订：transport 晚到后必须先观察取消；在任何 cookie/query/raw/firewall
    // 副作用之前拒绝，避免已取消的 302 推进核心状态或下一跳（红线 #1）。
    if (deps.signal?.aborted) {
      throw new BrokerFetchRejected("cancelled");
    }
    requestCount++;

    // ⑤ 重定向决策必须先于响应副作用。blocked 的 status/body/header/Location 均不可交付。
    const rd = decideRedirect({
      status: resp.status,
      location: resp.location,
      currentUrl,
      allow: view.allow,
      hopsSoFar: hops,
      maxHops,
    });
    if (rd.kind === "blocked") {
      throw new BrokerFetchRejected(`redirect_${rd.reason}`);
    }

    // ADR-009 §2.5：仅 follow/deliver 响应可影响 jar；blocked 响应的 Set-Cookie 必须丢弃。
    jar.captureSetCookie(resp.setCookie, currentUrl);

    if (rd.kind === "deliver") {
      // ⑦ 经统一 firewall choke point 交回 adapter。无 deps.masker → 空规则透明交付。
      // ② Policy 匹配：按最终 URL（重定向后最后一跳）+ 最后一跳 method 选规则（ADR-026 §2.8）。
      const masker = deps.masker;
      const rules =
        masker === undefined
          ? []
          : selectMaskerRules(masker.policy, {
              capability: masker.capability,
              method,
              finalUrl: currentUrl,
              ...(masker.requestKey === undefined ? {} : { requestKey: masker.requestKey }),
            });
      const rawBase = { status: resp.status, headers: resp.headers };
      const rawWithBody = resp.body === undefined ? rawBase : { ...rawBase, body: resp.body };
      const firewallInput = {
        raw:
          resp.repeatedHeaders === undefined
            ? rawWithBody
            : { ...rawWithBody, repeatedHeaders: resp.repeatedHeaders },
        // P1-04：缺省按**不可证明**处理——header 源规则据此 fail-closed，绝不收割折叠值。
        headerCardinalityAttested: resp.headerCardinalityAttested ?? false,
        // A3：真实判定由传输层给出（`decodeOk`）；缺省（fake transport / 无信号）按 true。
        // `false`（非 UTF-8 charset / 非法字节）→ firewall `body_not_plaintext` fail-closed。
        transportDecodeOk: resp.decodeOk ?? true,
        rules,
        view,
        sink: masker?.sink ?? NOOP_MASKER_SINK,
        ctx: masker?.ctx ?? NOOP_MASKER_CTX,
      };
      const delivered = deliverThroughFirewall(
        deps.signal === undefined ? firewallInput : { ...firewallInput, signal: deps.signal },
      );
      return { ...delivered.response, requestCount };
    }

    if (deps.queryHarvest !== undefined) {
      harvestQueryUrl(rd.nextUrl, deps.queryHarvest);
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
