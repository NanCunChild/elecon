// ADR-034/035: synthetic template; adjust targets/selectors to the real school.
// This record is intentionally shared with the HTTP template, independently
// of either script's default namespace or version.
const SHARED = { namespace: "campus.session" };
const PAGE_URL = "https://campus.example.edu/notices";
const BUSINESS_URL = "https://campus.example.edu/api/notices";
const TARGETS = [PAGE_URL, BUSINESS_URL];

export const capabilities = {
  async "notice.list"(ctx) {
    const saved = await ctx.credentials.get("browser-cookies", SHARED);
    if (saved) {
      const snapshot = JSON.parse(saved.value);
      for (const url of TARGETS) {
        const cookies = cookiesForRestore(snapshot, url, ctx.now());
        if (cookies.length) await ctx.browser.setCookies(url, cookies);
      }
    }
    await ctx.browser.open(PAGE_URL);
    // The user may log in and complete a challenge in the visible school page.
    const ready = await ctx.browser.waitFor("#notice-list", 30000);
    if (!ready) throw new Error("page_not_ready");
    const targets = [];
    for (const url of TARGETS) {
      // Query the real page/API URL, not the bare origin: a Cookie scoped to
      // /api would be invisible to some platforms when querying only "/".
      targets.push({ url, cookies: await ctx.browser.cookies(url) });
    }
    // Preserve every record's domain/path/Secure/HttpOnly/SameSite/expiry and
    // duplicate names. Do not deduplicate by name or save a flattened header.
    await ctx.credentials.set("browser-cookies", JSON.stringify({ version: 1, targets }), {
      ...SHARED,
      type: "cookie",
      scope: TARGETS,
    });
    const items = await ctx.browser.evaluate(() =>
      Array.from(document.querySelectorAll("#notice-list a")).map((a, index) => ({
        id: String(index),
        title: a.textContent.trim(),
        url: a.href,
        source: "Campus",
        category: "academic",
      })),
    );
    return { items };
  },
};

export function cookiesForRestore(snapshot, targetUrl, now) {
  if (snapshot?.version !== 1 || !Array.isArray(snapshot.targets)) {
    throw new Error("cookie_snapshot_invalid");
  }
  const target = httpUrl(targetUrl);
  const group = snapshot.targets.find((item) => {
    const captured = httpUrl(item.url);
    return captured.origin === target.origin && captured.path === target.path;
  });
  if (!group || !Array.isArray(group.cookies)) return [];
  return group.cookies
    .filter((cookie) => applicable(cookie, target, now))
    .map((cookie) => {
      const restored = { ...cookie };
      // Some Android APIs return only name/value. Their original Cookie Path
      // and host-only attributes cannot be reconstructed. Use this captured
      // business path and omit unknown Domain, limiting rather than broadening
      // the restoration. Same-name unknown-scope records are preserved in the
      // snapshot, but native restoration cannot promise a lossless jar.
      if (!restored.path) restored.path = target.path;
      if (!restored.domain) delete restored.domain;
      if (restored.expiresDate != null && restored.expiresDate < 0) delete restored.expiresDate;
      return restored;
    });
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
  return (
    expiry == null || (typeof expiry === "number" && Number.isFinite(expiry) && (expiry < 0 || expiry > now))
  );
}

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
