/**
 * Cookie 匹配原语（Gate A · B4）—— RFC 6265 §5.1.3 domain-match / §5.1.4 path-match。
 *
 * **不复用 `url-match.ts`**：那是 network.allow / credentials.scope 的 uri-template
 * **前缀**语义（`https://host/path/*`，`*` 通配）；cookie 的域/路径匹配是 RFC 6265 的
 * **后缀域 + 路径前缀**语义，方向与含义都不同。混用会污染 url-match 锁定的契约
 * （它与校验器 C4/C6/C7 语义绑定）。故本模块独立。
 *
 * 仅按 domain / path 匹配——**不**校验 `Secure` / `__Host-` 前缀 / cookie 属性
 * （B4 范围决定，见 docs/reference/b4_cookie_jar_plan.md §8 拍板 #1）。
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

/** 出站请求 URL 解析出的 host + path。 */
export interface UrlHostPath {
  host: string;
  path: string;
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

/** 解析具体出站 URL 的 host + path（无 query/fragment）。无法解析 → null。 */
export function parseUrlHostPath(url: string): UrlHostPath | null {
  try {
    const u = new URL(url);
    return { host: u.hostname.toLowerCase(), path: u.pathname || "/" };
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
