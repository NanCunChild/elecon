/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
 * ADR-034/035: school-owned session flow; no Broker, opaque handles or native imports.
 */
import { failure } from "./errors.js";
import { PDA_UA } from "./pda_constants.js";

export const AUTH_NAMESPACE = "xidian.auth";
const address = { namespace: AUTH_NAMESPACE };
const services = new Set(["ids", "ehall", "yjspt", "card", "library"]);
const origins = new Set([
  "https://ids.xidian.edu.cn",
  "https://ehall.xidian.edu.cn",
  "http://ehall.xidian.edu.cn",
  "https://yjspt.xidian.edu.cn",
  "https://v8scan.xidian.edu.cn",
  "https://xxcapp.xidian.edu.cn",
  "https://tyrzfw.chaoxing.com",
  "https://mfindxidian.libsp.cn",
]);

export function parseUrl(value) {
  if (typeof value !== "string" || /[\s\\]/.test(value)) throw new Error("xidian_invalid_url");
  const m = /^(https?):\/\/([a-zA-Z0-9.-]+)(?::(\d+))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/.exec(value);
  if (!m) throw new Error("xidian_invalid_url");
  const port = m[3] ? Number(m[3]) : m[1] === "https" ? 443 : 80;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("xidian_invalid_url");
  const host = m[2].toLowerCase();
  const origin = `${m[1]}://${host}${port === (m[1] === "https" ? 443 : 80) ? "" : `:${port}`}`;
  return { scheme: m[1], host, origin, path: m[4] || "/", query: m[5] || "", hash: m[6] || "" };
}

export function resolveUrl(value, base) {
  if (typeof value !== "string" || !value) throw new Error("xidian_invalid_redirect");
  const b = parseUrl(base);
  if (/^https?:\/\//i.test(value)) return value;
  if (value.startsWith("//")) return `${b.scheme}:${value}`;
  if (value.startsWith("#")) return `${b.origin}${b.path}${b.query}${value}`;
  if (value.startsWith("?")) return `${b.origin}${b.path}${value}`;
  const path = value.startsWith("/") ? value : `${b.path.slice(0, b.path.lastIndexOf("/") + 1)}${value}`;
  const marker = path.search(/[?#]/);
  const rawPath = marker < 0 ? path : path.slice(0, marker);
  const suffix = marker < 0 ? "" : path.slice(marker);
  const parts = [];
  for (const part of rawPath.split("/")) {
    if (part === "..") parts.pop();
    else if (part !== ".") parts.push(part);
  }
  return `${b.origin}${parts.join("/") || "/"}${suffix}`;
}

function domainMatches(host, domain) {
  return host === domain || host.endsWith(`.${domain}`);
}
function pathMatches(path, prefix) {
  return (
    path === prefix || (path.startsWith(prefix) && (prefix.endsWith("/") || path[prefix.length] === "/"))
  );
}
function validPair(cookie) {
  return (
    cookie &&
    typeof cookie.name === "string" &&
    /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(cookie.name) &&
    typeof cookie.value === "string" &&
    !Array.from(cookie.value).some(
      (char) => char.charCodeAt(0) <= 32 || char.charCodeAt(0) === 127 || char === ";" || char === ",",
    )
  );
}

/** Native metadata can be absent on Android. Keep duplicate unknown scopes. */
export function normalizeBrowserCookies(url, records) {
  const target = parseUrl(url);
  if (!Array.isArray(records)) throw new Error("xidian_invalid_cookies");
  return records.filter(validPair).map((raw) => {
    const domain = (raw.domain || target.host).toLowerCase().replace(/^\./, "");
    if (!domainMatches(target.host, domain)) throw new Error("xidian_cookie_domain_mismatch");
    const pathKnown = typeof raw.path === "string" && raw.path.startsWith("/");
    const cookie = {
      name: raw.name,
      value: raw.value,
      domain,
      hostOnly: !raw.domain,
      path: pathKnown ? raw.path : target.path,
      isSecure: raw.isSecure ?? target.scheme === "https",
      isHttpOnly: raw.isHttpOnly ?? false,
      ...(pathKnown ? {} : { pathKnown: false, capturedUrl: `${target.origin}${target.path}` }),
    };
    if (Number.isFinite(raw.expiresDate) && raw.expiresDate >= 0) cookie.expiresDate = raw.expiresDate;
    if (["Lax", "Strict", "None"].includes(raw.sameSite)) cookie.sameSite = raw.sameSite;
    return cookie;
  });
}

function cookieId(c) {
  return `${c.domain}\n${c.path}\n${c.name}`;
}
export function mergeCookies(existing, incoming) {
  // A response can set the same known cookie twice; the last observation wins.
  const seen = new Set();
  incoming = incoming
    .slice()
    .reverse()
    .filter((cookie) => {
      if (cookie.pathKnown === false) return true;
      const key = cookieId(cookie);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .reverse();
  const unknownGroups = new Set(
    incoming.filter((c) => c.pathKnown === false).map((c) => `${cookieId(c)}\n${c.capturedUrl}`),
  );
  const known = new Set(incoming.filter((c) => c.pathKnown !== false).map(cookieId));
  const kept = existing.filter((c) => {
    if (c.pathKnown !== false) return !known.has(cookieId(c));
    if (unknownGroups.has(`${cookieId(c)}\n${c.capturedUrl}`)) return false;
    // Explicit server attributes supersede an earlier unknown-scope sample
    // for this name/domain/path. Native exports cannot reconstruct distinctions
    // they omitted; retaining a stale sample would override a rotated session.
    return !incoming.some(
      (next) =>
        next.pathKnown !== false &&
        next.name === c.name &&
        (next.hostOnly
          ? parseUrl(c.capturedUrl).host === next.domain
          : domainMatches(parseUrl(c.capturedUrl).host, next.domain)) &&
        pathMatches(c.path, next.path),
    );
  });
  return [...kept, ...incoming];
}

function matches(c, target, now) {
  return (
    validPair(c) &&
    typeof c.domain === "string" &&
    typeof c.path === "string" &&
    (c.hostOnly ? target.host === c.domain : domainMatches(target.host, c.domain)) &&
    pathMatches(target.path, c.path) &&
    (!c.isSecure || target.scheme === "https") &&
    (c.expiresDate == null || c.expiresDate > now) &&
    (c.pathKnown !== false || c.capturedUrl === `${target.origin}${target.path}`)
  );
}

/** A native URL snapshot replaces its observed scope, including an empty jar. */
export function replaceBrowserCookiesForUrl(existing, url, records) {
  const target = parseUrl(url);
  const remaining = existing.filter((cookie) => !matches(cookie, target, Number.NEGATIVE_INFINITY));
  return mergeCookies(remaining, normalizeBrowserCookies(url, records));
}

export function cookieHeader(session, url, now) {
  const target = parseUrl(url);
  return (session.cookies || [])
    .filter((c) => matches(c, target, now))
    .map((c, index) => ({ c, index }))
    .sort((a, b) => b.c.path.length - a.c.path.length || a.index - b.index)
    .map(({ c }) => `${c.name}=${c.value}`)
    .join("; ");
}

export function browserCookiesForUrl(session, url, now) {
  const target = parseUrl(url);
  return (session?.cookies || [])
    .filter((c) => matches(c, target, now))
    .map((c) => ({
      name: c.name,
      value: c.value,
      path: c.path,
      isSecure: c.isSecure,
      isHttpOnly: c.isHttpOnly,
      ...(c.hostOnly ? {} : { domain: c.domain }),
      ...(c.expiresDate == null ? {} : { expiresDate: c.expiresDate }),
      ...(c.sameSite == null ? {} : { sameSite: c.sameSite }),
    }));
}

export async function readSession(ctx, service) {
  if (!services.has(service)) throw new Error("xidian_unknown_service");
  const record = await ctx.credentials.get(service, address);
  if (!record) return null;
  let session;
  try {
    session = JSON.parse(record.value);
  } catch {
    throw new Error(`xidian_invalid_session_${service}`);
  }
  if (
    session?.version !== 1 ||
    session.service !== service ||
    !Array.isArray(session.cookies) ||
    !session.data ||
    typeof session.data !== "object" ||
    Array.isArray(session.data)
  )
    throw new Error(`xidian_invalid_session_${service}`);
  return session;
}

export async function saveSession(ctx, service, session) {
  if (!services.has(service) || session?.version !== 1 || session.service !== service)
    throw new Error("xidian_invalid_session");
  session.updatedAt = ctx.now();
  await ctx.credentials.set(service, JSON.stringify(session), {
    ...address,
    type: "cookie",
    expiresAt: null,
    scope: [...new Set((session.cookies || []).map((c) => `https://${c.domain}/`))],
  });
}

export function parseSetCookie(line, url, now) {
  const target = parseUrl(url),
    fields = line.split(";");
  const equal = fields[0].indexOf("=");
  if (equal <= 0) return null;
  const cookie = {
    name: fields[0].slice(0, equal).trim(),
    value: fields[0].slice(equal + 1).trim(),
    domain: target.host,
    hostOnly: true,
    path: target.path.slice(0, target.path.lastIndexOf("/")) || "/",
    isSecure: false,
    isHttpOnly: false,
  };
  let maxAge;
  for (const field of fields.slice(1)) {
    const [rawName, ...rest] = field.trim().split("=");
    const name = rawName.toLowerCase(),
      value = rest.join("=").trim();
    if (name === "domain") {
      const domain = value.toLowerCase().replace(/^\./, "");
      if (!domain || !domainMatches(target.host, domain)) return null;
      cookie.domain = domain;
      cookie.hostOnly = false;
    } else if (name === "path" && value.startsWith("/")) cookie.path = value;
    else if (name === "secure") cookie.isSecure = true;
    else if (name === "httponly") cookie.isHttpOnly = true;
    else if (name === "max-age" && /^-?\d+$/.test(value)) maxAge = Number(value);
    else if (name === "expires" && Number.isFinite(Date.parse(value))) cookie.expiresDate = Date.parse(value);
    else if (name === "samesite") {
      const normalized = value.slice(0, 1).toUpperCase() + value.slice(1).toLowerCase();
      if (["Lax", "Strict", "None"].includes(normalized)) cookie.sameSite = normalized;
    }
  }
  if (maxAge != null && Number.isFinite(maxAge)) cookie.expiresDate = maxAge <= 0 ? 0 : now + maxAge * 1000;
  return validPair(cookie) ? cookie : null;
}

export function encodeForm(fields) {
  return Object.entries(fields)
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`)
    .join("&");
}

export async function createClient(
  ctx,
  service,
  { initialSession, persistSession = true, maxRedirects = 8, userAgent } = {},
) {
  if (!Number.isInteger(maxRedirects) || maxRedirects < 0 || maxRedirects > 30)
    throw new Error("xidian_redirect_limit_invalid");
  let session = initialSession ?? (await readSession(ctx, service));
  if (session && session.service !== service) throw new Error("xidian_invalid_session");
  let ids = service === "ids" ? null : await readSession(ctx, "ids");
  if (!session && !ids) throw failure(`xidian_login_required_${service}`);
  session ||= { version: 1, service, cookies: [], data: {} };
  // ADR-035 §2: same-school IDS metadata was saved only after verified login.
  // SSO can bypass the username form; do not discard that verified account id.
  if ((service === "ehall" || service === "yjspt") && !session.data.studentId && ids?.data?.studentId)
    session.data.studentId = ids.data.studentId;
  const client = {
    session,
    log: (level, message) => ctx.log?.(level, message),
    save: async () => {
      if (persistSession) await saveSession(ctx, service, session);
    },
    async request(initialUrl, init = {}) {
      let url = initialUrl,
        method = (init.method || "GET").toUpperCase(),
        body = init.body;
      // Follow the origin verified in this school's visible E-Hall session.
      // HTTPS and HTTP are distinct authorized origins, not interchangeable
      // servers; forcing HTTPS can reach the school's maintenance vhost.
      if (
        service === "ehall" &&
        session.data.origin === "http://ehall.xidian.edu.cn" &&
        parseUrl(url).origin === "https://ehall.xidian.edu.cn"
      ) {
        url = url.replace(/^https:/, "http:");
      }
      let headers = { ...(init.headers || {}) };
      for (let hop = 0; hop <= maxRedirects; hop++) {
        const target = parseUrl(url);
        if (!origins.has(target.origin)) {
          // Origin only: never include the redirect path, query or ticket.
          ctx.log?.("warn", `xidian_redirect_blocked ${target.origin.replace("://", " ")}`);
          throw failure("xidian_redirect_origin_denied");
        }
        const jar = {
          cookies:
            target.host === "ids.xidian.edu.cn"
              ? mergeCookies(session.cookies, ids?.cookies || [])
              : mergeCookies(ids?.cookies || [], session.cookies),
        };
        const cookie = cookieHeader(jar, url, ctx.now());
        const requestHeaders = {
          ...(userAgent || session.data.authFlow === "pda" ? { "User-Agent": userAgent || PDA_UA } : {}),
          ...headers,
        };
        for (const key of Object.keys(requestHeaders))
          if (key.toLowerCase() === "cookie") delete requestHeaders[key];
        if (cookie) requestHeaders.Cookie = cookie;
        const response = await ctx.fetch(url, {
          method,
          headers: requestHeaders,
          ...(body == null ? {} : { body }),
          redirect: "manual",
        });
        const received = response.headers
          .getSetCookie()
          .map((line) => parseSetCookie(line, url, ctx.now()))
          .filter(Boolean);
        if (received.length) {
          if (target.host === "ids.xidian.edu.cn" && service !== "ids") {
            ids ||= { version: 1, service: "ids", cookies: [], data: {} };
          }
          const owner = target.host === "ids.xidian.edu.cn" && ids ? ids : session;
          owner.cookies = mergeCookies(owner.cookies, received).filter(
            (c) => c.expiresDate == null || c.expiresDate > ctx.now(),
          );
          // Persist rotated credentials before parsing the business response.
          // ADR-035 §3: verified IDS rotations survive a failed service login;
          // a staged business jar is committed only after its read-only probe.
          if (owner === ids || persistSession) await saveSession(ctx, owner.service, owner);
        }
        const location = response.headers.get("location");
        if (![301, 302, 303, 307, 308].includes(response.status) || !location) {
          if (
            service === "ehall" &&
            target.host === "ehall.xidian.edu.cn" &&
            target.path.startsWith("/jwapp/") &&
            session.data.origin !== target.origin &&
            (target.origin === "http://ehall.xidian.edu.cn" ||
              session.data.origin === "http://ehall.xidian.edu.cn")
          ) {
            session.data.origin = target.origin;
            await client.save();
          }
          return response;
        }
        if (hop === maxRedirects) throw new Error("xidian_redirect_limit");
        // PDA's HTTPS Location rule belongs to its own verified sessions; legacy
        // browser sessions retain their observed HTTP origin (ADR-034 §5).
        const resolved = resolveUrl(location, url);
        const next = session.data.authFlow === "pda" ? resolved.replace(/^http:/, "https:") : resolved;
        if (response.status === 303 || ([301, 302].includes(response.status) && method === "POST")) {
          if (method !== "HEAD") method = "GET";
          body = undefined;
          for (const key of Object.keys(headers))
            if (key.toLowerCase().startsWith("content-")) delete headers[key];
        }
        const cross = parseUrl(next).origin !== target.origin;
        if (cross) {
          if (body != null && method !== "GET" && method !== "HEAD")
            throw new Error("xidian_cross_origin_replay_denied");
          headers = {};
        }
        url = next;
      }
      throw new Error("xidian_redirect_limit");
    },
    async getJSON(url, options = {}) {
      return json(await client.request(url, options));
    },
    async postForm(url, fields = {}, options = {}) {
      return json(
        await client.request(url, {
          ...options,
          method: "POST",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "X-Requested-With": "XMLHttpRequest",
            ...(options.headers || {}),
          },
          body: encodeForm(fields),
        }),
      );
    },
    async postJSON(url, value, options = {}) {
      return json(
        await client.request(url, {
          ...options,
          method: "POST",
          headers: { "Content-Type": "application/json; charset=UTF-8", ...(options.headers || {}) },
          body: JSON.stringify(value),
        }),
      );
    },
  };
  async function json(response) {
    if (
      response.status === 401 ||
      response.status === 403 ||
      parseUrl(response.url).host === "ids.xidian.edu.cn"
    )
      throw failure(`xidian_login_required_${service}`);
    if (!response.ok) throw new Error("xidian_http_failed");
    try {
      return await response.json();
    } catch {
      throw new Error("xidian_non_json_response");
    }
  }
  return client;
}
