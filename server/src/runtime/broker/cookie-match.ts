/**
 * Cookie 匹配原语（Gate A · B4）—— RFC 6265 §5.1.3 domain-match / §5.1.4 path-match。
 *
 * **不复用 `url-match.ts`**：那是 network.allow / credentials.scope 的 uri-template
 * **前缀**语义（`https://host/path/*`，`*` 通配）；cookie 的域/路径匹配是 RFC 6265 的
 * **后缀域 + 路径前缀**语义，方向与含义都不同。混用会污染 url-match 锁定的契约
 * （它与校验器 C4/C6/C7 语义绑定）。故本模块独立。
 *
 * 本模块提供 domain / path 匹配 + **cookie 属性解析原语**（`Secure` 由 [parseUrlHostPath]
 * 暴露的 scheme 判定；生命周期由 [parseCookieDate] / [parseMaxAge]）。`__Host-` / `__Secure-`
 * 前缀仍不校验（B4 范围，见 docs/reference/b4_cookie_jar_plan.md §8 拍板 #1）。
 *
 * 🔒 安全敏感（红线 #1，凭证/会话态匹配路径）：AI 起草，须人工 + 安全清单复核，
 * 不得 AI 独自闭环（AGENTS.md §1）。
 */

/** 模板（allow / scope）解析出的 host + 字面 path 前缀。 */
export interface TemplateHostPath {
  host: string;
  /** 第一个 `*` / `{param}` 前的字面 path 前缀，恒以 `/` 开头。 */
  pathPrefix: string;
}

/** 出站请求 URL 解析出的 scheme + host + path。 */
export interface UrlHostPath {
  host: string;
  path: string;
  /** 小写 scheme，**不含**结尾 `:`（如 `https`）。`Secure` cookie 的发送判据。 */
  scheme: string;
}

/** host 是否为 IP 字面量（IPv4 点分 或 含 `:` 的 IPv6）。IP 不参与后缀域匹配。 */
export function isIpLiteral(host: string): boolean {
  if (host.includes(":")) return true; // IPv6
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host);
}

/**
 * RFC 6265 §5.1.3 domain-match：Domb=`cookieDomain` 的 cookie 是否会被发往 host=`host`
 * 的请求。真当：① `host === cookieDomain`，或 ② `host` 以 `.cookieDomain` 结尾且 host
 * 非 IP（cookieDomain 是 host 的父域）。**方向不可写反**：是 host 落在 cookie 域内，
 * 不是 cookie 域落在 host 内（ADR-009 §2.4 第 123 行）。
 */
export function domainMatch(host: string, cookieDomain: string): boolean {
  const h = host.toLowerCase();
  const d = cookieDomain.toLowerCase().replace(/^\./, "");
  if (h === d) return true;
  if (isIpLiteral(h)) return false;
  return d.length > 0 && h.endsWith("." + d);
}

/**
 * RFC 6265 §5.1.4 path-match：请求 path=`requestPath` 是否匹配 cookie path=`cookiePath`。
 * 真当：① 相等；② `cookiePath` 是 `requestPath` 前缀且（`cookiePath` 以 `/` 结尾，或
 * `requestPath` 在该前缀后紧跟 `/`）。
 */
export function pathMatch(requestPath: string, cookiePath: string): boolean {
  if (requestPath === cookiePath) return true;
  if (!requestPath.startsWith(cookiePath)) return false;
  if (cookiePath.endsWith("/")) return true;
  return requestPath[cookiePath.length] === "/";
}

/**
 * 解析 allow / scope 模板的 host + 字面 path 前缀。去掉 `*` 通配后用 URL 解析；
 * `{param}` 占位中性化为 `_`（与 url-match concretize 同处理）。无法解析 → null。
 */
export function parseTemplateHostPath(template: string): TemplateHostPath | null {
  const neutralized = template.replace(/\{[^}]+\}/g, "_").replace(/\*/g, "");
  try {
    const u = new URL(neutralized);
    return { host: u.hostname.toLowerCase(), pathPrefix: u.pathname || "/" };
  } catch {
    return null;
  }
}

/** 解析具体出站 URL 的 scheme + host + path（无 query/fragment）。无法解析 → null。 */
export function parseUrlHostPath(url: string): UrlHostPath | null {
  try {
    const u = new URL(url);
    return {
      host: u.hostname.toLowerCase(),
      path: u.pathname || "/",
      scheme: u.protocol.replace(/:$/, "").toLowerCase(),
    };
  } catch {
    return null;
  }
}

/**
 * RFC 6265 §5.1.4 default-path：从请求 path 推导 cookie 默认 Path。
 * path 为空 / 不以 `/` 开头 → `/`；否则取最后一个 `/` 前的部分，为空 → `/`。
 */
export function defaultPath(requestPath: string): string {
  if (!requestPath.startsWith("/")) return "/";
  const lastSlash = requestPath.lastIndexOf("/");
  if (lastSlash <= 0) return "/";
  return requestPath.slice(0, lastSlash);
}

/**
 * cookie 过期时刻的可表示上界（ms epoch，= JS `Date` 的最大值 ±8.64e15）。
 *
 * 存在理由是**跨端确定性**：`Max-Age=<30 位数字>` 在 JS 里是有限 float、在 Dart 里溢出
 * 64 位 int，直接算会两端分叉。故一切换算先夹到本上界，两端得同一个「远期」时刻。
 */
export const MAX_COOKIE_EXPIRY_MS = 8_640_000_000_000_000;

/** `Max-Age` 的 delta-seconds 夹取上界（10^18，绝对值超此按上界处理；见 [parseMaxAge]）。 */
const MAX_DELTA_SECONDS = 1_000_000_000_000_000_000;

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

/**
 * RFC 6265 §5.1.1 date-token 分隔符：%x09 / %x20-2F / %x3B-40 / %x5B-60 / %x7B-7E。
 * 注意 `:`（%x3A）**不是**分隔符——时间 `hh:mm:ss` 须留在同一 token 内。
 */
function isCookieDateDelimiter(code: number): boolean {
  return (
    code === 0x09 ||
    (code >= 0x20 && code <= 0x2f) ||
    (code >= 0x3b && code <= 0x40) ||
    (code >= 0x5b && code <= 0x60) ||
    (code >= 0x7b && code <= 0x7e)
  );
}

/**
 * 解析 `Expires` 属性值为 ms epoch（RFC 6265 §5.1.1 的**逐 token 算法**，非依赖宿主
 * `Date.parse` / `DateTime.parse`）。返回 null = 该属性不可解析 ⟹ **整条属性忽略**
 * （cookie 退化为 session，§5.2.1），不是「立刻过期」。
 *
 * 为什么自己写：`Date.parse`（JS）与 `DateTime.parse`（Dart）对 RFC 850 两位年、asctime
 * 无时区、非法日期 rollover 的处理各不相同——照抄宿主即两端语义漂移。本算法逐 token、
 * 与宿主日历实现无关，两端逐字镜像，并由 `contract/golden/broker/cookie-jar.json`
 * 的 `parseCookieDate` 组钉死。
 *
 * 与 RFC 一致的刻意行为：年 70–99 ⟹ +1900，0–69 ⟹ +2000；年 < 1601 判失败；
 * 日 1–31 之外判失败（**但** 2 月 31 日这类「合法数字、非法日历日」按宿主日历自然进位，
 * 两端一致，golden 有例）。
 */
export function parseCookieDate(value: string): number | null {
  let foundTime = false;
  let foundDay = false;
  let foundMonth = false;
  let foundYear = false;
  let hour = 0;
  let minute = 0;
  let second = 0;
  let day = 0;
  let month = 0;
  let year = 0;

  for (const token of splitCookieDateTokens(value)) {
    if (!foundTime) {
      const t = /^(\d{1,2}):(\d{1,2}):(\d{1,2})(?!\d)/.exec(token);
      if (t) {
        foundTime = true;
        hour = Number(t[1]);
        minute = Number(t[2]);
        second = Number(t[3]);
        continue;
      }
    }
    if (!foundDay) {
      const d = /^(\d{1,2})(?!\d)/.exec(token);
      if (d) {
        foundDay = true;
        day = Number(d[1]);
        continue;
      }
    }
    if (!foundMonth) {
      const idx = MONTHS.indexOf(token.slice(0, 3).toLowerCase());
      if (idx >= 0) {
        foundMonth = true;
        month = idx + 1;
        continue;
      }
    }
    if (!foundYear) {
      const y = /^(\d{2,4})(?!\d)/.exec(token);
      if (y) {
        foundYear = true;
        year = Number(y[1]);
      }
    }
  }

  if (year >= 70 && year <= 99) year += 1900;
  else if (year >= 0 && year <= 69) year += 2000;

  if (!foundTime || !foundDay || !foundMonth || !foundYear) return null;
  if (day < 1 || day > 31) return null;
  if (year < 1601) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  return Date.UTC(year, month - 1, day, hour, minute, second);
}

/** 按 §5.1.1 分隔符切 date-token，丢弃空段。 */
function splitCookieDateTokens(value: string): string[] {
  const tokens: string[] = [];
  let cur = "";
  for (const ch of value) {
    if (isCookieDateDelimiter(ch.charCodeAt(0))) {
      if (cur !== "") tokens.push(cur);
      cur = "";
    } else {
      cur += ch;
    }
  }
  if (cur !== "") tokens.push(cur);
  return tokens;
}

/**
 * 解析 `Max-Age` 属性值为 delta-seconds（RFC 6265 §5.2.2）。返回 null = 属性非法
 * ⟹ **忽略该属性**（不是「立刻过期」）。
 *
 * §5.2.2 原文：首字符须是 DIGIT 或 `-`，其余须全是 DIGIT，否则忽略整条属性。
 * 结果 ≤ 0 ⟹ 调用方按「最早可表示时刻」处理（即立刻过期 ⟹ 删除该 cookie）。
 *
 * 位数超 18 时夹到 ±[MAX_DELTA_SECONDS]：防 JS（有限 float）与 Dart（int 溢出返 null）
 * 在超长数字上分叉。
 */
export function parseMaxAge(value: string): number | null {
  const s = value.trim();
  if (s === "") return null;
  const negative = s.startsWith("-");
  const digits = negative ? s.slice(1) : s;
  if (digits === "" || !/^\d+$/.test(digits)) return null;
  const trimmed = digits.replace(/^0+(?=\d)/, "");
  const magnitude = trimmed.length > 18 ? MAX_DELTA_SECONDS : Number(trimmed);
  return negative ? -magnitude : magnitude;
}

/** 由 `Max-Age` delta-seconds 与 `now` 算过期时刻（ms epoch），夹到 [MAX_COOKIE_EXPIRY_MS]。 */
export function expiryFromMaxAge(deltaSeconds: number, nowMs: number): number {
  if (deltaSeconds <= 0) return -MAX_COOKIE_EXPIRY_MS; // 最早可表示时刻 ⟹ 立刻过期
  const ms = nowMs + deltaSeconds * 1000;
  return ms > MAX_COOKIE_EXPIRY_MS || !Number.isFinite(ms) ? MAX_COOKIE_EXPIRY_MS : ms;
}
