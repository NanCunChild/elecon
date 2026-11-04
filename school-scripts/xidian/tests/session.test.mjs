import assert from "node:assert/strict";
// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
import test from "node:test";
import { dateOnly, moneyMinor, schoolDateTime } from "../src/normalize.js";
import {
  browserCookiesForUrl,
  cookieHeader,
  createClient,
  mergeCookies,
  normalizeBrowserCookies,
  parseSetCookie,
  readSession,
  replaceBrowserCookiesForUrl,
  resolveUrl,
} from "../src/session.js";

function context(sessions, fetch) {
  const records = new Map(Object.entries(sessions).map(([key, value]) => [key, JSON.stringify(value)]));
  const writes = [];
  return {
    records,
    writes,
    now: () => 1_800_000_000_000,
    fetch,
    credentials: {
      async get(key, options) {
        assert.equal(options.namespace, "xidian.auth");
        return records.has(key) ? { value: records.get(key) } : null;
      },
      async set(key, value, options) {
        assert.equal(options.namespace, "xidian.auth");
        assert.equal(options.expiresAt, null);
        records.set(key, value);
        writes.push(key);
      },
    },
  };
}
function session(service, cookies = [], data = {}) {
  return { version: 1, service, cookies, data };
}

test("academic SSO reuses verified same-school IDS account metadata without replacing a service account", async () => {
  const ctx = context(
    {
      ids: session("ids", [], { studentId: "SYNTHETIC-IDS" }),
      ehall: session("ehall"),
      yjspt: session("yjspt", [], { studentId: "SYNTHETIC-SERVICE" }),
    },
    () => assert.fail("metadata lookup does not need a request"),
  );
  assert.equal((await createClient(ctx, "ehall")).session.data.studentId, "SYNTHETIC-IDS");
  assert.equal((await createClient(ctx, "yjspt")).session.data.studentId, "SYNTHETIC-SERVICE");
  assert.deepEqual(ctx.writes, []);
});

test("academic HTTP 403 without login evidence does not request authentication", async () => {
  for (const service of ["ehall", "yjspt"]) {
    const url = `https://${service}.xidian.edu.cn/query`;
    const ctx = context({ [service]: session(service) }, async () => response(url, { status: 403 }));
    await assert.rejects(
      (await createClient(ctx, service)).getJSON(url),
      (error) => error.message === "xidian_http_failed" && error.code !== "authentication_required",
    );
  }
});

test("denied redirect diagnostics identify only its scheme and host", async () => {
  const ctx = context({ ehall: session("ehall") }, async () =>
    response("https://ehall.xidian.edu.cn/", {
      status: 302,
      headers: { location: "https://blocked.example/path?ticket=SYNTHETIC-PRIVATE" },
    }),
  );
  const logs = [];
  ctx.log = (level, message) => logs.push([level, message]);
  const client = await createClient(ctx, "ehall");
  await assert.rejects(
    client.request("https://ehall.xidian.edu.cn/"),
    (error) => error.message === "xidian_redirect_origin_denied" && error.code === "network_denied",
  );
  assert.deepEqual(logs, [["warn", "xidian_redirect_blocked https blocked.example"]]);
});

test("declared E-Hall HTTP redirect is preserved and subsequent business calls use its actual origin", async () => {
  const seen = [];
  const start = "https://ehall.xidian.edu.cn/appShow?appId=EXAMPLE_SYNTHETIC";
  const end = "http://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do?ticket=EXAMPLE_SYNTHETIC";
  const ctx = context({ ehall: session("ehall") }, async (url) => {
    seen.push(url);
    return response(url, url === start ? { status: 302, headers: { location: end } } : {});
  });
  const client = await createClient(ctx, "ehall");
  await client.request(start);
  assert.deepEqual(seen, [start, end]);
  assert.equal((await readSession(ctx, "ehall")).data.origin, "http://ehall.xidian.edu.cn");
  await client.request("https://ehall.xidian.edu.cn/jwapp/sys/wdkb/api.do");
  assert.equal(seen.at(-1), "http://ehall.xidian.edu.cn/jwapp/sys/wdkb/api.do");
  const explicitPort = context({ ehall: session("ehall") }, async (url) => {
    if (url === start)
      return response(url, {
        status: 302,
        headers: { location: end.replace(/^http:\/\/ehall.xidian.edu.cn/, "http://ehall.xidian.edu.cn:80") },
      });
    assert.equal(url, end.replace(/^http:\/\/ehall.xidian.edu.cn/, "http://ehall.xidian.edu.cn:80"));
    return response(url);
  });
  await (await createClient(explicitPort, "ehall")).request(start);
  for (const denied of ["http://ehall.xidian.edu.cn:8080/path", "http://other.example/path"]) {
    const rejected = context({ ehall: session("ehall") }, async (url) => {
      assert.equal(url, start);
      return response(url, { status: 302, headers: { location: denied } });
    });
    await assert.rejects(
      (await createClient(rejected, "ehall")).request(start),
      /xidian_redirect_origin_denied/,
    );
  }
});

test("a cross-origin 307 cannot replay a POST even when the HTTP destination is declared", async () => {
  let count = 0;
  const ctx = context({ ehall: session("ehall") }, async (url) => {
    count++;
    return response(url, { status: 307, headers: { location: "http://ehall.xidian.edu.cn/next" } });
  });
  await assert.rejects(
    (await createClient(ctx, "ehall")).request("https://ehall.xidian.edu.cn/start", {
      method: "POST",
      body: "EXAMPLE_SYNTHETIC",
    }),
    /xidian_cross_origin_replay_denied/,
  );
  assert.equal(count, 1);
});
function response(url, { status = 200, headers = {}, cookies = [], body = {} } = {}) {
  return {
    url,
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (name) => headers[name.toLowerCase()] ?? null, getSetCookie: () => cookies },
    async text() {
      return typeof body === "string" ? body : JSON.stringify(body);
    },
    async json() {
      return typeof body === "string" ? JSON.parse(body) : body;
    },
  };
}

test("cookie identities preserve path, domain, SameSite and duplicate unknown native scopes", () => {
  const url = "https://ehall.xidian.edu.cn/jwapp/api";
  const cookies = normalizeBrowserCookies(url, [
    {
      name: "SID",
      value: "ROOT",
      path: "/",
      domain: "ehall.xidian.edu.cn",
      sameSite: "Lax",
      isHttpOnly: true,
    },
    {
      name: "SID",
      value: "APP",
      path: "/jwapp",
      domain: "ehall.xidian.edu.cn",
      sameSite: "None",
      isSecure: true,
    },
    { name: "SID", value: "UNKNOWN_A" },
    { name: "SID", value: "UNKNOWN_B" },
  ]);
  const combined = mergeCookies([], cookies);
  assert.equal(combined.length, 4);
  assert.equal(
    cookieHeader(session("ehall", combined), url, 0),
    "SID=UNKNOWN_A; SID=UNKNOWN_B; SID=APP; SID=ROOT",
  );
  assert.equal(cookieHeader(session("ehall", combined), "https://other.xidian.edu.cn/jwapp/api", 0), "");
  assert.equal(
    cookieHeader(session("ehall", combined), "https://ehall.xidian.edu.cn/jwapp/another", 0),
    "SID=APP; SID=ROOT",
  );
  const native = browserCookiesForUrl(session("ehall", combined), url, 0);
  assert.equal(native.find((c) => c.value === "APP").sameSite, "None");
  assert.equal(native.find((c) => c.value === "ROOT").isHttpOnly, true);
  assert.equal(native.find((c) => c.value === "UNKNOWN_A").domain, undefined);
  assert.equal(mergeCookies(combined, cookies).length, 4);
});

test("legacy public-suffix cookies are neither restored nor sent to another school service", () => {
  const url = "https://ids.xidian.edu.cn/authserver/login";
  const cookies = [
    ...["cn", "edu.cn", "com"].map((domain) => ({
      name: "LEGACY",
      value: "SYNTHETIC",
      domain,
      hostOnly: false,
      path: "/",
      isSecure: false,
      isHttpOnly: true,
    })),
    parseSetCookie("SID=SYNTHETIC_SSO; Domain=.xidian.edu.cn; Path=/; Secure", url, 0),
  ];
  const saved = session("ids", cookies);
  assert.deepEqual(
    browserCookiesForUrl(saved, url, 0).map((c) => c.name),
    ["SID"],
  );
  assert.equal(cookieHeader(saved, "https://rs.xidian.edu.cn/", 0), "SID=SYNTHETIC_SSO");
  assert.equal(cookieHeader(saved, "https://mfindxidian.libsp.cn/", 0), "");
  for (const domain of ["cn", "edu.cn", "com", "xidian.edu.cn.evil.invalid"])
    assert.equal(parseSetCookie(`BAD=SYNTHETIC; Domain=${domain}; Path=/`, url, 0), null);
  assert.throws(
    () =>
      normalizeBrowserCookies(url, [
        {
          name: "BAD",
          value: "SYNTHETIC",
          domain: "edu.cn",
          path: "/",
        },
      ]),
    /domain_mismatch/,
  );
  assert.equal(
    parseSetCookie("CX=SYNTHETIC; Domain=.chaoxing.com; Path=/", "https://learn.chaoxing.com/", 0).domain,
    "chaoxing.com",
  );
});

test("authenticated redirects use each host's own cookies and save rotated credentials", async () => {
  const start = "https://ehall.xidian.edu.cn/appShow?appId=1";
  const cas = "https://ids.xidian.edu.cn/authserver/login?service=synthetic";
  const landing = "https://ehall.xidian.edu.cn/new/index.html?ticket=EXAMPLE_SYNTHETIC_ST";
  const api = "https://ehall.xidian.edu.cn/jwapp/api";
  const ctx = context(
    {
      ids: session(
        "ids",
        normalizeBrowserCookies(cas, [
          { name: "CASTGC", value: "EXAMPLE_SYNTHETIC_CAS", path: "/authserver" },
        ]),
      ),
      ehall: session("ehall", normalizeBrowserCookies(api, [{ name: "SID", value: "OLD", path: "/" }])),
    },
    async (url, init) => {
      assert.equal(init.redirect, "manual");
      if (url === start) {
        assert.equal(init.headers.Cookie, "SID=OLD");
        return response(url, { status: 302, headers: { location: cas } });
      }
      if (url === cas) {
        assert.equal(init.headers.Cookie, "CASTGC=EXAMPLE_SYNTHETIC_CAS");
        assert.equal(init.headers.Authorization, undefined);
        return response(url, {
          status: 302,
          headers: { location: landing },
          cookies: ["CASTGC=ROTATED; Path=/authserver; Secure; HttpOnly; SameSite=Lax"],
        });
      }
      if (url === landing) return response(url, { cookies: ["SID=NEW; Path=/; Max-Age=3600; Secure"] });
      assert.equal(url, api);
      assert.equal(init.headers.Cookie, "SID=NEW");
      return response(url, { body: { authenticated: true } });
    },
  );
  const client = await createClient(ctx, "ehall");
  await client.request(start, { headers: { Authorization: "EXAMPLE_SYNTHETIC_BEARER" } });
  assert.deepEqual(await client.postForm(api, { XNXQDM: "2026-2027-1" }), { authenticated: true });
  assert.deepEqual(ctx.writes, ["ids", "ehall"]);
  assert.equal((await readSession(ctx, "ids")).cookies[0].value, "ROTATED");
});

test("response cookie changes survive malformed business JSON and cookie deletion", async () => {
  const url = "https://ehall.xidian.edu.cn/jwapp/api";
  const ctx = context(
    {
      ehall: session(
        "ehall",
        normalizeBrowserCookies(url, [
          { name: "A", value: "OLD", path: "/" },
          { name: "B", value: "REMOVE", path: "/" },
        ]),
      ),
    },
    async () =>
      response(url, {
        cookies: ["A=NEW; Path=/", "B=; Path=/; Max-Age=0"],
        body: "<html>bad business data</html>",
      }),
  );
  const client = await createClient(ctx, "ehall");
  await assert.rejects(client.getJSON(url), /xidian_non_json_response/);
  assert.equal(cookieHeader(await readSession(ctx, "ehall"), url, ctx.now()), "A=NEW");
});

test("a rotated server cookie replaces stale unknown native samples and repeated Set-Cookie uses the last value", async () => {
  const url = "https://ehall.xidian.edu.cn/jwapp/api";
  const ctx = context(
    { ehall: session("ehall", normalizeBrowserCookies(url, [{ name: "SID", value: "NATIVE_OLD" }])) },
    async () => response(url, { cookies: ["SID=FIRST; Path=/; Secure", "SID=LAST; Path=/; Secure"] }),
  );
  const client = await createClient(ctx, "ehall");
  await client.getJSON(url);
  const saved = await readSession(ctx, "ehall");
  assert.equal(saved.cookies.length, 1);
  assert.equal(cookieHeader(saved, url, ctx.now()), "SID=LAST");
});

test("unknown redirect origins and cross-origin POST replay fail before another request", async () => {
  for (const target of ["https://other.invalid/path", "https://ids.xidian.edu.cn/authserver/login"]) {
    let requests = 0;
    const url = "https://ehall.xidian.edu.cn/api";
    const ctx = context({ ehall: session("ehall") }, async () => {
      requests++;
      return response(url, { status: 307, headers: { location: target } });
    });
    const client = await createClient(ctx, "ehall");
    await assert.rejects(
      client.request(url, { method: "POST", body: "EXAMPLE_SYNTHETIC_BODY" }),
      /xidian_(?:redirect_origin_denied|cross_origin_replay_denied)/,
    );
    assert.equal(requests, 1);
  }
});

test("request helpers preserve school header fields without overriding Host", async () => {
  const url = "https://mfindxidian.libsp.cn/find/loan/list";
  const ctx = context(
    { library: session("library", [], { token: "EXAMPLE_SYNTHETIC_JWT", groupCode: "200755" }) },
    async (target, init) => {
      assert.equal(target, url);
      assert.equal(init.headers.jwtOpacAuth, "EXAMPLE_SYNTHETIC_JWT");
      assert.equal(init.headers.Host, undefined);
      assert.deepEqual(JSON.parse(init.body), { page: 1 });
      return response(url, { body: { data: [] } });
    },
  );
  const client = await createClient(ctx, "library");
  assert.deepEqual(
    await client.postJSON(url, { page: 1 }, { headers: { jwtOpacAuth: "EXAMPLE_SYNTHETIC_JWT" } }),
    {
      data: [],
    },
  );
});

test("a first CAS refresh creates the shared IDS record instead of hiding it in one service", async () => {
  const start = "https://ehall.xidian.edu.cn/appShow?appId=1";
  const cas = "https://ids.xidian.edu.cn/authserver/login";
  const end = "https://ehall.xidian.edu.cn/new/index.html";
  const ctx = context({ ehall: session("ehall") }, async (url) => {
    if (url === start) return response(url, { status: 302, headers: { location: cas } });
    if (url === cas)
      return response(url, {
        status: 302,
        headers: { location: end },
        cookies: ["CASTGC=NEW; Path=/authserver; Secure"],
      });
    return response(end);
  });
  await (await createClient(ctx, "ehall")).request(start);
  assert.equal((await readSession(ctx, "ehall")).cookies.length, 0);
  assert.equal((await readSession(ctx, "ids")).cookies[0].value, "NEW");
  assert.equal((await createClient(ctx, "card")).session.service, "card");
});

test("parent-domain server updates replace unknown native cookies and empty snapshots clear their scope", async () => {
  const url = "https://ehall.xidian.edu.cn/jwapp/api";
  const ctx = context(
    { ehall: session("ehall", normalizeBrowserCookies(url, [{ name: "SID", value: "OLD" }])) },
    async () => response(url, { cookies: ["SID=NEW; Domain=.xidian.edu.cn; Path=/; Secure"] }),
  );
  await (await createClient(ctx, "ehall")).getJSON(url);
  const cookies = (await readSession(ctx, "ehall")).cookies;
  assert.equal(cookieHeader(session("ehall", cookies), url, ctx.now()), "SID=NEW");
  assert.deepEqual(replaceBrowserCookiesForUrl(cookies, url, []), []);
});

test("shared IDS rotations take precedence over stale cookies in an older business snapshot", async () => {
  const url = "https://ids.xidian.edu.cn/authserver/login";
  const ctx = context(
    {
      ids: session(
        "ids",
        normalizeBrowserCookies(url, [{ name: "CASTGC", value: "NEW", path: "/authserver" }]),
      ),
      ehall: session(
        "ehall",
        normalizeBrowserCookies(url, [{ name: "CASTGC", value: "OLD", path: "/authserver" }]),
      ),
    },
    async (_url, init) => {
      assert.equal(init.headers.Cookie, "CASTGC=NEW");
      return response(url);
    },
  );
  await (await createClient(ctx, "ehall")).request(url);
});

test("China wall times, calendar dates and decimal money are normalized without UTC shifts", () => {
  assert.equal(schoolDateTime("2026-06-20 09:00:00"), "2026-06-20T01:00:00.000Z");
  assert.equal(schoolDateTime("2026-06-20T09:00:00+08:00"), "2026-06-20T01:00:00.000Z");
  assert.equal(moneyMinor("0.29"), 29);
  assert.equal(moneyMinor("-12.30"), -1230);
  assert.equal(dateOnly("2026/6/2"), "2026-06-02");
  assert.throws(() => dateOnly("2026-02-29"));
  assert.throws(() => moneyMinor("1.001"));
  assert.throws(() => schoolDateTime("2026-10-01 24:59:00"));
  assert.equal(
    resolveUrl("../sso/login?ticket=ONE#jwt=TWO", "https://ehall.xidian.edu.cn/app/start"),
    "https://ehall.xidian.edu.cn/sso/login?ticket=ONE#jwt=TWO",
  );
});

test("campus-card HTTP redirects admit the OAuth intermediary without replaying card cookies", async () => {
  const start = "https://v8scan.xidian.edu.cn/home/openXDOAuth2Page";
  const oauth = "https://xxcapp.xidian.edu.cn/oauth/authorize?state=EXAMPLE_SYNTHETIC";
  const cas = "https://ids.xidian.edu.cn/authserver/login?service=EXAMPLE_SYNTHETIC";
  const seen = [];
  const ctx = context(
    {
      card: session(
        "card",
        normalizeBrowserCookies(start, [{ name: "SID", value: "EXAMPLE_SYNTHETIC_CARD", path: "/" }]),
      ),
      ids: session(
        "ids",
        normalizeBrowserCookies(cas, [{ name: "TGC", value: "EXAMPLE_SYNTHETIC_IDS", path: "/authserver" }]),
      ),
    },
    async (url, init) => {
      seen.push(url);
      if (url === start) {
        assert.equal(init.headers.Cookie, "SID=EXAMPLE_SYNTHETIC_CARD");
        return response(url, { status: 302, headers: { location: oauth } });
      }
      if (url === oauth) {
        assert.equal(init.headers.Cookie, undefined);
        return response(url, { status: 302, headers: { location: cas } });
      }
      assert.equal(url, cas);
      assert.equal(init.headers.Cookie, "TGC=EXAMPLE_SYNTHETIC_IDS");
      return response(url);
    },
  );
  await (await createClient(ctx, "card")).request(start);
  assert.deepEqual(seen, [start, oauth, cas]);
});

test("PDA sessions retain desktop UA and HTTPS redirects after login", async () => {
  const seen = [];
  const start = "https://ehall.xidian.edu.cn/appShow?appId=EXAMPLE_SYNTHETIC";
  const end = "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do";
  const ctx = context(
    { ehall: session("ehall", [], { authFlow: "pda", origin: "https://ehall.xidian.edu.cn" }) },
    async (url, init) => {
      seen.push(url);
      assert.match(init.headers["User-Agent"], /Chrome\/130.*XDYou\/2\.0\.0/);
      return response(
        url,
        url === start ? { status: 302, headers: { location: end.replace("https:", "http:") } } : {},
      );
    },
  );
  await (await createClient(ctx, "ehall")).request(start);
  assert.deepEqual(seen, [start, end]);
  assert.equal(ctx.writes.length, 0);
});
