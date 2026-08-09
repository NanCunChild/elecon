/**
 * 执行内 cookie jar（Gate A · B4）—— ADR-009 §2.4 / §2.8。
 *
 * 单次执行的 cookie 容器，**两分区严格隔离**、对 adapter 全程不可见、不跨执行、不经 public：
 *   - **origin 区**：捕获 origin 下发的 `Set-Cookie`（含重定向各跳）。执行内会话态，
 *     且是耐久 cookie 收割（B5 → ADR-012）的**唯一权威**。
 *   - **ephemeral 区**：adapter 经 `ctx.setEphemeralCookie` 写入。**四重栅栏**（仅 passthrough
 *     origin / 不覆盖注入 / 永不收割 / 执行即弃）由本模块强制，解 XJT body-token 缺口
 *     （origin 把会话 token 放响应 body、零 Set-Cookie）。
 *
 * 纯决策（`decideEphemeralWrite` / `parseSetCookie` / `matchCookieForSend` / `selectCookies`）由
 * `contract/golden/broker/cookie-jar.json` 钉死两端一致（ADR-001 §8）；
 * 有态部分（捕获默认 domain/path、跨跳捕获、过期删除、执行即弃、分区隔离）由 smoke 覆盖。
 *
 * **cookie 属性面（P1-05 / P1-06，2026-08-07）**：`Secure` 只随 https 发出；`Max-Age` /
 * `Expires` 决定生命周期（Max-Age 优先），到期不发、不收割，`Max-Age=0` / 过期 `Expires`
 * 从 jar **删除**该条；覆盖键是 `(name, domain, path)`——同名不同 Path **并存**而非折叠。
 *
 * 不含（划走，见计划 §1）：B5 收割桥接、B6 完整请求拼装 / 真实 transport / resolver 取值。
 *
 * 🔒 红线 #1 写入面（adapter→jar）：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环
 * （AGENTS.md §1；ADR-009 §2.8 第 164 行：四重栅栏由 Broker 强制，非依赖 adapter 自律）。
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  defaultPath,
  domainMatch,
  expiryFromMaxAge,
  parseCookieDate,
  parseMaxAge,
  parseTemplateHostPath,
  parseUrlHostPath,
  pathMatch,
} from "./cookie-match.js";
import type { BrokerManifestView } from "./inject-policy.js";

/** cookie 来源分区。`origin` 进收割权威；`ephemeral` 永不收割。 */
export type CookieSource = "origin" | "ephemeral";

/** jar 内 cookie 表示（仅 host 侧可见；adapter 永不接触）。 */
export interface JarCookie {
  name: string;
  value: string;
  /** host-only（无前导 `.`），小写。 */
  domain: string;
  /** `Set-Cookie` 无 Domain 属性时为 true；此时只匹配精确响应 host。 */
  hostOnly?: boolean;
  path: string;
  source: CookieSource;
  /**
   * `Secure` 属性（P1-06）。为 true 时**只随 https 请求发出**——见 [matchCookieForSend]。
   * 缺省 false（未声明 Secure）。
   */
  secure?: boolean;
  /**
   * 过期时刻（ms epoch）。`null` / 缺省 = **session cookie**（无 `Max-Age`/`Expires`，
   * 随执行结束消亡）。已到期的 cookie 不发送、不收割，并在下次捕获时从 jar 删除。
   */
  expiresAt?: number | null;
}

/** `setEphemeralCookie` 入参（契约面 `ctx.setEphemeralCookie` 的 host 侧归一形）。 */
export interface EphemeralWriteInput {
  name: string;
  value: string;
  domain: string;
  path?: string;
}

export type EphemeralRejectReason =
  /** domain 不落在任何 network.allow 条目内（非 passthrough origin）。 */
  | "domain_not_passthrough"
  /** domain 与某 credentials.scope 域有 domain-match 关系（永不能写凭证域）。 */
  | "domain_is_credential"
  /** path 比对应 allow 条目声明的更宽（写出更宽 cookie 路径）。 */
  | "path_too_wide";

export type EphemeralWriteDecision =
  | { ok: true; cookie: { name: string; value: string; domain: string; path: string } }
  | { ok: false; reason: EphemeralRejectReason };

// 最小 public-suffix 护栏（#79 P0-4）：完整 PSL 需新依赖与更新机制；本阶段先
// fail-closed 拒绝单标签 TLD 与校园场景/常见 ccTLD 的二级公共后缀，封堵
// `dean.xjtu.edu.cn` 设置 `Domain=edu.cn` 这类过宽父域污染面。
// 列表单一事实源在 contract/broker/public-suffixes.json（Dart 侧常量由测试钉死一致）。
// 加载/形状非法即抛（fail-closed）：安全栅栏数据不得静默降级为空集。
const publicSuffixesPath = fileURLToPath(
  new URL("../../../../contract/broker/public-suffixes.json", import.meta.url),
);

function loadKnownMultiLabelPublicSuffixes(): ReadonlySet<string> {
  const raw = JSON.parse(readFileSync(publicSuffixesPath, "utf-8")) as {
    multiLabelPublicSuffixes?: unknown;
  };
  const list = raw.multiLabelPublicSuffixes;
  if (!Array.isArray(list) || list.length === 0 || !list.every((s) => typeof s === "string")) {
    throw new Error(
      `public-suffix 护栏数据非法：${publicSuffixesPath} 须含非空字符串数组 multiLabelPublicSuffixes（fail-closed）`,
    );
  }
  return new Set(list.map((s) => s.toLowerCase()));
}

const knownMultiLabelPublicSuffixes = loadKnownMultiLabelPublicSuffixes();

function isPublicSuffixLike(domain: string): boolean {
  const d = domain.toLowerCase().replace(/^\./, "");
  if (d === "" || !d.includes(".")) return true;
  return knownMultiLabelPublicSuffixes.has(d);
}

/** cookie path 是否「等于或深于」allow path 前缀（allowPath 为其前缀）——即不更宽。 */
function pathNotWiderThan(cookiePath: string, allowPathPrefix: string): boolean {
  const a = allowPathPrefix.endsWith("/") ? allowPathPrefix : allowPathPrefix + "/";
  const c = cookiePath.endsWith("/") ? cookiePath : cookiePath + "/";
  return c.startsWith(a);
}

/**
 * 四重栅栏之栅栏 1（写入校验，ADR-009 §2.4 第 143 行）。fail-closed：
 *   1.2 先查——domain 与**任何** credentials.scope 域有 domain-match 关系（双向）→ 拒
 *       （凭证域 ⊆ allow，故必须先于 1.1 拦下，绝不写凭证域）。
 *   1.1 ——domain 须 domain-match **某** allow 条目 host（cookie 可发往该 passthrough host）。
 *   1.3 ——该 allow 条目 path 须是 cookie path 前缀（cookie path 不更宽）；path 缺省 `/`。
 * 栅栏 2/3/4 分别由 selectCookies 优先级 / 收割只读 origin 区 / jar 生命周期保证。
 */
export function decideEphemeralWrite(
  input: EphemeralWriteInput,
  view: BrokerManifestView,
): EphemeralWriteDecision {
  const domain = input.domain.toLowerCase().replace(/^\./, "");
  const path = input.path ?? "/";

  // 栅栏 1.2：永不写凭证域（双向 domain-match，fail-closed 优先）。
  for (const decl of Object.values(view.credentials ?? {})) {
    for (const scope of decl.scope) {
      const p = parseTemplateHostPath(scope);
      if (!p) continue;
      if (domainMatch(p.host, domain) || domainMatch(domain, p.host)) {
        return { ok: false, reason: "domain_is_credential" };
      }
    }
  }

  // 栅栏 1.1 + 1.3：须存在某 allow 条目，domain 可发往其 host 且 path 不更宽。
  let domainOk = false;
  for (const a of view.allow) {
    const p = parseTemplateHostPath(a);
    if (!p) continue;
    if (!domainMatch(p.host, domain)) continue;
    domainOk = true;
    if (pathNotWiderThan(path, p.pathPrefix)) {
      return { ok: true, cookie: { name: input.name, value: input.value, domain, path } };
    }
  }
  return { ok: false, reason: domainOk ? "path_too_wide" : "domain_not_passthrough" };
}

/**
 * RFC 6265 §5.4 排序（path 长者先，同长按名升序）+ 确定性 tie-break（domain、value 升序）。
 * tie-break 使比较器成为 total order：同名同 path 不同 domain 的 cookie（harvest 可同时命中）
 * 在不稳定 sort 实现间、以及 TS/Dart 双实现间序一致。
 */
export function compareCookiePathName(
  a: { path: string; name: string; domain?: string; value?: string },
  b: { path: string; name: string; domain?: string; value?: string },
): number {
  return (
    b.path.length - a.path.length ||
    cmpStr(a.name, b.name) ||
    cmpStr(a.domain ?? "", b.domain ?? "") ||
    cmpStr(a.value ?? "", b.value ?? "")
  );
}

function cmpStr(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** [matchCookieForSend] / [selectCookies] 的候选 cookie 形（jar 内表示的结构子集）。 */
export interface CookieSendCandidate {
  domain: string;
  path: string;
  hostOnly?: boolean | undefined;
  secure?: boolean | undefined;
  expiresAt?: number | null | undefined;
}

/**
 * 单个 cookie 是否会被发往 requestUrl —— RFC 6265 §5.4 的四条判据全过才为真：
 *   ① domain-match（hostOnly 时须精确等于响应 host）；
 *   ② path-match；
 *   ③ **`Secure` ⟹ 请求 scheme 必须是 https**（P1-06；http/其它一律不发。刻意不给
 *      `http://localhost` 开浏览器式「可信本地源」豁免——校园场景无此需求，放宽只会
 *      给明文回落留缺口）；
 *   ④ **未过期**：`expiresAt != null && expiresAt <= nowMs` ⟹ 不发（P1-06）。
 *
 * [nowMs] **必填**，不设缺省：缺省值只会在某个调用点悄悄退化成「永不过期」。
 */
export function matchCookieForSend(cookie: CookieSendCandidate, requestUrl: string, nowMs: number): boolean {
  const u = parseUrlHostPath(requestUrl);
  if (!u) return false;
  if (cookie.secure === true && u.scheme !== "https") return false;
  if (isExpired(cookie.expiresAt, nowMs)) return false;
  const domainMatches =
    cookie.hostOnly === true ? u.host === cookie.domain : domainMatch(u.host, cookie.domain);
  return domainMatches && pathMatch(u.path, cookie.path);
}

/** 到期判据的单一事实源：`null`/`undefined` = session cookie，永不因时间失效。 */
export function isExpired(expiresAt: number | null | undefined, nowMs: number): boolean {
  return expiresAt !== null && expiresAt !== undefined && expiresAt <= nowMs;
}

/**
 * 为出站请求选 cookie（纯）。流程：
 *   ① 过 [matchCookieForSend]（domain/path/Secure/过期）；
 *   ② 栅栏 2（ADR-009 §2.4）——**某名字只要有任一 origin cookie 命中，该名下的
 *      ephemeral cookie 全部丢弃**。ephemeral 永不能遮盖或「补充」origin 会话名；
 *   ③ 同 `(name,domain,path)` 去重（jar 内已唯一，纯函数侧再兜一层）；
 *   ④ 排序：path 长者先（RFC 6265 §5.4），同长按名、domain、value 升序。
 *
 * **P1-05（同名不同 Path 不再折叠）**：此前按 `name` 收进 Map，`sid=/` 与 `sid=/api`
 * 只活一条——与浏览器行为不符，且会**静默丢失**深路径下的会话态（origin 下发的
 * `/api` 专用 token 被根路径同名 cookie 顶掉，请求带错值）。现按浏览器语义**全部带上**，
 * 长 Path 在前；栅栏 2 的信任边界改由「按名压制 ephemeral」表达，未被放宽。
 *
 * 返回 `{name,value}` 序列——**不外泄 domain/path/source/secure/expiresAt**。
 * 注：broker 注入的凭证 cookie 由 B6 在本输出之上叠加，不在本函数。
 */
export function selectCookies(
  cookies: readonly JarCookie[],
  requestUrl: string,
  nowMs: number,
): Array<{ name: string; value: string }> {
  const matched = cookies.filter((c) => matchCookieForSend(c, requestUrl, nowMs));
  // 栅栏 2 的判据是「本次请求实际命中的 origin 名字集」——不是全 jar 的 origin 名字：
  // 一条 path/域/过期上不参与本请求的 origin cookie，不该连带压掉可用的 ephemeral。
  const originNames = new Set(matched.filter((c) => c.source === "origin").map((c) => c.name));
  const seen = new Set<string>();
  const kept: JarCookie[] = [];
  for (const c of matched) {
    if (c.source === "ephemeral" && originNames.has(c.name)) continue; // 栅栏 2
    const key = `${c.name} ${c.domain} ${c.path}`;
    if (seen.has(key)) continue;
    seen.add(key);
    kept.push(c);
  }
  return kept.sort(compareCookiePathName).map((c) => ({ name: c.name, value: c.value }));
}

/**
 * 解析单条 `Set-Cookie` 头为 JarCookie（origin 区）。缺省 domain/path 按 RFC 6265 §5.3；
 * `Secure` / `Max-Age` / `Expires` 按 §5.2.1–§5.2.5 解析（P1-06）。
 *
 * 生命周期（§5.2.2 优先级）：**`Max-Age` 压过 `Expires`**；两者皆无/皆非法 ⟹ session
 * cookie（`expiresAt: null`）。`Max-Age=0`、负 `Max-Age`、过去的 `Expires` 都产出一个
 * 已过期的 `expiresAt`——由 [CookieJar.captureSetCookie] 翻译成**删除**语义。
 *
 * 导出仅为 golden 双跑（`parseSetCookie` 组）钉两端一致，不是 adapter 可见面。
 */
export function parseSetCookie(header: string, requestUrl: string, nowMs: number): JarCookie | null {
  const u = parseUrlHostPath(requestUrl);
  if (!u) return null;
  const parts = header.split(";");
  const first = parts[0] ?? "";
  const eq = first.indexOf("=");
  if (eq <= 0) return null;
  const name = first.slice(0, eq).trim();
  const value = first.slice(eq + 1).trim();
  if (name === "") return null;

  let domain = u.host; // 缺省 host-only
  let hasDomainAttr = false;
  let path: string | null = null;
  let secure = false;
  let maxAgeExpiry: number | null = null;
  let expiresExpiry: number | null = null;
  for (const attr of parts.slice(1)) {
    const i = attr.indexOf("=");
    const key = (i === -1 ? attr : attr.slice(0, i)).trim().toLowerCase();
    const val = i === -1 ? "" : attr.slice(i + 1).trim();
    if (key === "domain" && val !== "") {
      domain = val.toLowerCase().replace(/^\./, "");
      hasDomainAttr = true;
    } else if (key === "path" && val.startsWith("/")) {
      path = val;
    } else if (key === "secure") {
      // §5.2.5：属性名出现即置位，值被忽略（`Secure` 与 `Secure=xxx` 同义）。
      secure = true;
    } else if (key === "max-age") {
      const delta = parseMaxAge(val);
      if (delta !== null) maxAgeExpiry = expiryFromMaxAge(delta, nowMs);
    } else if (key === "expires") {
      // 非法日期 ⟹ 忽略该属性（§5.2.1），退化为 session——**不是**立刻过期。
      expiresExpiry = parseCookieDate(val);
    }
    // HttpOnly 无意义：本 jar 不暴露给任何脚本环境（adapter 全程看不到 cookie）。
  }
  // RFC 6265 §5.3 step 6（#79 P0-4）：显式 Domain 属性必须 domain-match 响应 host，
  // 且不得是 public suffix / 过宽父域；否则整条 Set-Cookie **丢弃**（fail-closed）。
  // 封堵「allow 集内某 host 为不属于自己的域或过宽父域伪造 cookie、经后续请求发往
  // 他域」的污染面。缺省 host-only（无 Domain 属性）不受限。
  if (hasDomainAttr && (!domainMatch(u.host, domain) || isPublicSuffixLike(domain))) return null;
  return {
    name,
    value,
    domain,
    hostOnly: !hasDomainAttr,
    path: path ?? defaultPath(u.path),
    source: "origin",
    secure,
    expiresAt: maxAgeExpiry ?? expiresExpiry, // Max-Age 优先（§5.2.2）
  };
}

/**
 * 有态 jar —— 随单次执行存活。两分区隔离；执行结束整体丢弃（栅栏 4：无任何持久化路径）。
 */
export class CookieJar {
  private readonly origin: JarCookie[] = [];
  private readonly ephemeral: JarCookie[] = [];
  private readonly now: () => number;

  /** [now] 可注入仅为测试可确定化；生产恒 `Date.now`。 */
  constructor(now: () => number = () => Date.now()) {
    this.now = now;
  }

  /**
   * 捕获一次响应的 `Set-Cookie`（含重定向跳）。
   *
   * 覆盖键 = `(name, domain, path)`（RFC 6265 §5.3 step 11）：**同名 + 同域 + 同 Path
   * 新值替换旧值**（会话轮换）；`name` 相同但 Path 不同 ⟹ **两条并存**，各自独立
   * （P1-05——此前折叠导致深路径 cookie 被根路径同名覆盖而丢失）。
   *
   * **删除语义（P1-06）**：解析出的 cookie 若已过期（`Max-Age=0`、负 `Max-Age`、
   * 过去的 `Expires`），不入 jar，并把 jar 内同 `(name,domain,path)` 的旧条目**删掉**
   * ——这是 origin 主动登出/失效会话的唯一表达方式，必须真删而非留一条死 cookie。
   */
  captureSetCookie(setCookieHeaders: readonly string[], requestUrl: string): void {
    for (const h of setCookieHeaders) {
      const c = parseSetCookie(h, requestUrl, this.now());
      if (!c) continue;
      const idx = this.origin.findIndex(
        (e) => e.name === c.name && e.domain === c.domain && e.path === c.path,
      );
      if (isExpired(c.expiresAt, this.now())) {
        if (idx >= 0) this.origin.splice(idx, 1); // 删除语义：Max-Age=0 / 过期 Expires
        continue;
      }
      if (idx >= 0) this.origin[idx] = c;
      else this.origin.push(c);
    }
  }

  /**
   * adapter 经 `ctx.setEphemeralCookie` 写入。过栅栏 1（decideEphemeralWrite）；
   * **违例静默丢弃 + warn**（计划 §8 拍板 #3），不抛错——不给 adapter 探测栅栏边界的信号。
   * 返回是否实际写入（供 smoke 断言；adapter 侧拿不到此返回）。
   */
  writeEphemeral(
    input: EphemeralWriteInput,
    view: BrokerManifestView,
    warn: (message: string) => void,
  ): boolean {
    const d = decideEphemeralWrite(input, view);
    if (!d.ok) {
      warn(`setEphemeralCookie 被拒（${d.reason}）：name=${input.name} domain=${input.domain}`);
      return false;
    }
    const idx = this.ephemeral.findIndex(
      (e) => e.name === d.cookie.name && e.domain === d.cookie.domain && e.path === d.cookie.path,
    );
    // ephemeral 恒为 session、恒非 Secure：adapter 不得给自己写的 cookie 设生命周期或
    // 传输限制——那是 origin 属性面，ephemeral 只在本次执行内存活（栅栏 4）。
    const entry: JarCookie = {
      ...d.cookie,
      hostOnly: false,
      source: "ephemeral",
      secure: false,
      expiresAt: null,
    };
    if (idx >= 0) this.ephemeral[idx] = entry;
    else this.ephemeral.push(entry);
    return true;
  }

  /**
   * 出站请求选 cookie 对（两分区合并 + selectCookies；origin>ephemeral 已落实）。
   * B6 拼装（assemble）在此输出之上叠加 broker 注入凭证（broker>origin>ephemeral）。
   * 仅返回 {name,value}——不外泄 domain/path/source。
   */
  selectForSend(requestUrl: string): Array<{ name: string; value: string }> {
    return selectCookies([...this.origin, ...this.ephemeral], requestUrl, this.now());
  }

  /** 出站请求的 `Cookie` 头值（空则 ""）。两分区合并后过 selectCookies。 */
  cookieHeader(requestUrl: string): string {
    return this.selectForSend(requestUrl)
      .map((p) => `${p.name}=${p.value}`)
      .join("; ");
  }

  /**
   * 收割视图（B5 用）：**仅 origin 区**。ephemeral 区结构上不在此返回 →「永不收割」
   * （栅栏 3）由类型/数据流保证，非靠调用方自律。
   *
   * 同时**滤掉已过期条目**（P1-06）：捕获时的删除只在「又收到一条 Set-Cookie」时触发，
   * 一条在捕获后自然到点的 cookie 仍会留在 origin 区；收割是它进入持久凭证库的入口，
   * 故在此按当前时钟再滤一次，绝不把死会话写进 Store。
   */
  harvestView(): readonly JarCookie[] {
    const now = this.now();
    return this.origin.filter((c) => !isExpired(c.expiresAt, now));
  }
}
