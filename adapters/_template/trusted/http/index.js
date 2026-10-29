// ADR-034/035: ordinary JS owns the school flow. Both templates explicitly
// share this namespace; another script's default "session" key cannot collide.
const SHARED = { namespace: "campus.session" };
const BUSINESS_URL = "https://campus.example.edu/api/notices";

export const capabilities = {
  async "notice.list"(ctx) {
    const session = await ctx.credentials.get("browser-cookies", SHARED);
    if (!session) {
      ctx.log("error", "Sign in using the browser script before requesting private notices");
      throw new Error("session_required");
    }
    const snapshot = JSON.parse(session.value);
    const cookie = cookieHeaderForUrl(snapshot, BUSINESS_URL, ctx.now());
    if (!cookie) throw new Error("session_required");
    const response = await ctx.fetch(BUSINESS_URL, {
      headers: { Cookie: cookie },
      // Authentication flows needing intermediate Set-Cookie use manual mode.
      redirect: "manual",
    });
    if (!response.ok) throw new Error("notice_http_failed");
    const json = await response.json();
    return {
      items: json.items.map((item) => ({
        id: String(item.id),
        title: item.title,
        source: "Campus",
        category: "academic",
      })),
    };
  },
};

// Keep the captured records, including SameSite/HttpOnly and duplicate names,
// in JSON. A flattened header is an output for one URL, never the stored jar.
export function cookieHeaderForUrl(snapshot, targetUrl, now) {
  const { target, cookies } = snapshotForUrl(snapshot, targetUrl);
  return cookies
    .map((cookie, index) => ({ cookie, index }))
    .filter(({ cookie }) => applicable(cookie, target, now))
    .sort((a, b) => knownPathLength(b.cookie) - knownPathLength(a.cookie) || a.index - b.index)
    .map(({ cookie }) => `${cookie.name}=${cookie.value}`)
    .join("; ");
}

function snapshotForUrl(snapshot, targetUrl) {
  if (snapshot?.version !== 1 || !Array.isArray(snapshot.targets)) {
    throw new Error("cookie_snapshot_invalid");
  }
  const target = httpUrl(targetUrl);
  const group = snapshot.targets.find((item) => {
    const captured = httpUrl(item.url);
    return captured.origin === target.origin && captured.path === target.path;
  });
  if (!group || !Array.isArray(group.cookies)) throw new Error("cookie_snapshot_required");
  return { target, cookies: group.cookies };
}

function applicable(cookie, target, now) {
  if (
    !cookie ||
    typeof cookie.name !== "string" ||
    !cookie.name ||
    typeof cookie.value !== "string" ||
    !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(cookie.name) ||
    Array.from(cookie.value).some(
      (char) => char === ";" || char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127,
    )
  )
    return false;
  const domain =
    typeof cookie.domain === "string" && cookie.domain
      ? cookie.domain.toLowerCase().replace(/^\./, "")
      : target.host;
  // Missing native domain metadata is scoped to the captured hostname; the
  // exact-origin group above never exports it to another host/subdomain.
  if (
    target.host !== domain &&
    (target.host.includes(":") || /^[0-9.]+$/.test(target.host) || !target.host.endsWith(`.${domain}`))
  )
    return false;
  const path = typeof cookie.path === "string" && cookie.path ? cookie.path : target.path;
  if (
    !path.startsWith("/") ||
    !(
      target.path === path ||
      (target.path.startsWith(path) && (path.endsWith("/") || target.path[path.length] === "/"))
    )
  )
    return false;
  if (cookie.isSecure === true && target.scheme !== "https") return false;
  const expiry = cookie.expiresDate;
  if (
    expiry != null &&
    (typeof expiry !== "number" || !Number.isFinite(expiry) || (expiry >= 0 && expiry <= now))
  )
    return false;
  // SameSite belongs to browser request context, which native ctx.fetch does
  // not emulate. Preserve it in JSON for browser restoration instead.
  return true;
}

function knownPathLength(cookie) {
  return typeof cookie.path === "string" ? cookie.path.length : 0;
}

// No global URL dependency: the minimal QuickJS runtime need not expose DOM
// URL APIs. These are the template's already-declared absolute business URLs.
function httpUrl(value) {
  const match = /^(https?):\/\/(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?(\/[^?#]*)?(?:[?#].*)?$/.exec(
    value,
  );
  if (!match) throw new Error("cookie_target_invalid");
  const scheme = match[1];
  const host = match[2].replace(/^\[|\]$/g, "").toLowerCase();
  const port = Number(match[3] || (scheme === "https" ? 443 : 80));
  return { scheme, host, origin: `${scheme}://${host}:${port}`, path: match[4] || "/" };
}
