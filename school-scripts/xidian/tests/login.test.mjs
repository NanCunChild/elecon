// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import {
  createLogin,
  inspectLoginPage,
  LOGIN_TARGETS,
  libraryGroupCode,
  login,
} from "../src/browser_login.js";
import { normalizeBrowserCookies } from "../src/session.js";

const IDS = "https://ids.xidian.edu.cn/authserver/login";
const EHALL_API = "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/xskcb/xskcb.do";

function harness({
  states = [{ ready: true, data: {} }],
  saved = {},
  cookies,
  groupCode = "EXAMPLE_SYNTHETIC_GROUP",
  onEvaluate,
  stageStates = {},
  onStageEvaluate,
} = {}) {
  let clock = 1000;
  let calls = 0;
  let totalEvaluations = 0;
  const stageCalls = {};
  const events = [];
  const records = new Map(Object.entries(saved).map(([key, value]) => [key, JSON.stringify(value)]));
  const ctx = {
    now: () => clock,
    credentials: {
      async get(key, options) {
        assert.equal(options.namespace, "xidian.auth");
        events.push(["read", key]);
        return records.has(key) ? { key, value: records.get(key), namespace: options.namespace } : null;
      },
      async set(key, value, options) {
        assert.equal(options.namespace, "xidian.auth");
        records.set(key, value);
        events.push(["save", key]);
      },
    },
    browser: {
      async setCookies(url, values) {
        events.push(["restore", url, values]);
      },
      async open(url) {
        events.push(["open", url]);
      },
      async evaluate(fn, ..._args) {
        if (fn === libraryGroupCode) return groupCode;
        assert.equal(fn, inspectLoginPage);
        clock += 1000;
        totalEvaluations++;
        const stage = _args[0];
        if (stage === "ids" || stage === "ehall-portal") {
          const index = stageCalls[stage] ?? 0;
          stageCalls[stage] = index + 1;
          onStageEvaluate?.({ stage, index, events, records });
          const values = stageStates[stage] ?? [{ ready: true, page: stage, data: {} }];
          const state = values[Math.min(index, values.length - 1)];
          if (state instanceof Error) throw state;
          return state;
        }
        calls++;
        onEvaluate?.({ events, records, calls });
        const state = states[Math.min(calls - 1, states.length - 1)];
        if (state instanceof Error) throw state;
        return state;
      },
      async cookies(url) {
        events.push(["cookies", url]);
        if (cookies) return cookies(url);
        return [
          {
            name: "EXAMPLE_SYNTHETIC_SESSION",
            value: "example-synthetic-cookie-secret",
            path: "/",
            isSecure: true,
            isHttpOnly: true,
          },
        ];
      },
    },
  };
  return { ctx, events, records, callCount: () => calls, totalEvaluations: () => totalEvaluations };
}

function savedSession(service, url, rawCookies, data = {}) {
  return { version: 1, service, cookies: normalizeBrowserCookies(url, rawCookies), data, updatedAt: 100 };
}

test("a campus-card login request opens and harvests the card target instead of the academic default", async () => {
  const h = harness({
    states: [{ ready: true, page: "card", data: { openid: "EXAMPLE_SYNTHETIC_OPENID" } }],
  });
  await createLogin("undergraduate")(h.ctx, { requiredRef: "card-session" });
  assert.equal(h.events.find(([kind]) => kind === "open")[1], LOGIN_TARGETS.card.openUrl);
  assert.ok(h.records.has("card"));
  assert.equal(h.records.has("ehall"), false);
});

test("an unverified portal never opens IDS independently or saves either session", async () => {
  const h = harness({ stageStates: { "ehall-portal": [{ ready: false }] } });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.deepEqual(
    h.events.filter(([kind]) => kind === "open"),
    [["open", "https://ehall.xidian.edu.cn/"]],
  );
  assert.equal(h.records.size, 0);
  assert.equal(
    h.events.some(([kind]) => kind === "cookies"),
    false,
  );
});

test("verified IDS is saved before business navigation and survives a later failure without replacing old business data", async () => {
  const old = savedSession("ehall", EHALL_API, [], { studentId: "EXAMPLE_SYNTHETIC_OLD_ID" });
  const h = harness({
    saved: {
      ehall: old,
      ids: savedSession("ids", IDS, [], {
        studentId: "EXAMPLE_SYNTHETIC_OLD_ID",
        fingerprint: "EXAMPLE_SYNTHETIC_BFP",
      }),
    },
    states: [new Error("browser_navigation_blocked")],
  });
  await assert.rejects(createLogin("postgraduate")(h.ctx, { system: "ehall" }), /browser_navigation_blocked/);
  const savedAt = h.events.findIndex(([kind, key]) => kind === "save" && key === "ids");
  const businessAt = h.events.findIndex(
    ([kind, url]) => kind === "open" && url === LOGIN_TARGETS.ehall.openUrl,
  );
  assert.ok(savedAt >= 0 && savedAt < businessAt);
  assert.deepEqual(JSON.parse(h.records.get("ehall")), old);
  const ids = JSON.parse(h.records.get("ids"));
  assert.equal(ids.data.role, "postgraduate");
  assert.equal(ids.data.fingerprint, "EXAMPLE_SYNTHETIC_BFP");
  assert.equal(ids.data.studentId, undefined);
  assert.ok(ids.cookies.length > 0);
  assert.equal(
    h.events.some(([kind, key]) => kind === "save" && key === "ehall"),
    false,
  );
});

test("IDS cannot be saved just because a cookie exists while independent verification remains incomplete", async () => {
  const old = savedSession("ids", IDS, [
    { name: "CASTGC", value: "EXAMPLE_SYNTHETIC_OLD", path: "/authserver" },
  ]);
  const h = harness({ saved: { ids: old }, stageStates: { ids: [{ ready: false }] } });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.deepEqual(JSON.parse(h.records.get("ids")), old);
  assert.equal(
    h.events.some(([kind]) => kind === "save"),
    false,
  );
  assert.equal(
    h.events.some(([kind, url]) => kind === "open" && url === LOGIN_TARGETS.ehall.openUrl),
    false,
  );
});

test("independent IDS capture preserves different authserver and personalInfo sessions with the same cookie name", async () => {
  const h = harness({
    cookies: (url) => [
      {
        name: "JSESSIONID",
        value: url.includes("/personalInfo/") ? "EXAMPLE_SYNTHETIC_PERSONAL" : "EXAMPLE_SYNTHETIC_AUTH",
        path: url.includes("/personalInfo/") ? "/personalInfo" : "/authserver",
      },
    ],
    states: [new Error("browser_navigation_blocked")],
  });
  await assert.rejects(login(h.ctx), /browser_navigation_blocked/);
  const cookies = JSON.parse(h.records.get("ids")).cookies;
  assert.equal(cookies.filter((c) => c.name === "JSESSIONID").length, 2);
  assert.deepEqual(new Set(cookies.map((c) => c.path)), new Set(["/authserver", "/personalInfo"]));
});

test("a mobile IDS landing is independently saved before resuming the E-Hall portal exactly once", async () => {
  const h = harness({
    stageStates: { "ehall-portal": [{ ready: false, verifiedIdsLanding: true }, { ready: true }] },
  });
  await login(h.ctx);
  const opens = h.events.filter(([kind]) => kind === "open").map(([, url]) => url);
  assert.deepEqual(opens, [
    "https://ehall.xidian.edu.cn/",
    IDS,
    "https://ehall.xidian.edu.cn/",
    LOGIN_TARGETS.ehall.openUrl,
  ]);
  const saved = h.events.findIndex(([kind, key]) => kind === "save" && key === "ids");
  const resumed = h.events.findIndex(
    ([kind, url], index) => index > saved && kind === "open" && url === "https://ehall.xidian.edu.cn/",
  );
  assert.ok(saved >= 0 && resumed > saved);
  assert.ok(h.records.has("ehall"));
});

test("a portal that still returns to IDS after resumption cannot loop or erase the independently saved SSO", async () => {
  const h = harness({ stageStates: { "ehall-portal": [{ ready: false, verifiedIdsLanding: true }] } });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.equal(
    h.events.filter(([kind, url]) => kind === "open" && url === "https://ehall.xidian.edu.cn/").length,
    2,
  );
  assert.ok(h.records.has("ids"));
  assert.equal(h.records.has("ehall"), false);
});

test("restores IDS and target cookies before opening E-Hall's session-initializing entry, then saves verified snapshots", async () => {
  const h = harness({
    saved: {
      ids: savedSession(
        "ids",
        IDS,
        [{ name: "TGC", value: "example-synthetic-old-tgc", path: "/authserver" }],
        {
          fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
          role: "postgraduate",
          studentId: "EXAMPLE_SYNTHETIC_OLD_ID",
        },
      ),
      ehall: savedSession("ehall", EHALL_API, [
        { name: "JSESSIONID", value: "example-synthetic-old-ehall", path: "/jwapp" },
      ]),
    },
  });
  const result = await login(h.ctx, { studentId: "EXAMPLE_SYNTHETIC_STUDENT" });
  const openAt = h.events.findIndex(([kind]) => kind === "open");
  const restores = h.events
    .map(([kind], index) => (kind === "restore" ? index : -1))
    .filter((index) => index >= 0);
  assert.ok(restores.length >= 2);
  assert.ok(restores.every((index) => index < openAt));
  const open = h.events[openAt][1];
  assert.equal(open, "https://ehall.xidian.edu.cn/");
  assert.equal(new URL(open).searchParams.has("service"), false);
  assert.deepEqual(
    h.events.filter(([kind]) => kind === "open").map(([, url]) => url),
    ["https://ehall.xidian.edu.cn/", IDS, LOGIN_TARGETS.ehall.openUrl],
  );
  const captured = h.events.filter(([kind]) => kind === "cookies").map(([, url]) => url);
  for (const url of LOGIN_TARGETS.ehall.cookieUrls) assert.ok(captured.includes(url), url);
  const session = JSON.parse(h.records.get("ehall"));
  assert.equal(session.data.studentId, "EXAMPLE_SYNTHETIC_STUDENT");
  assert.equal(session.service, "ehall");
  const ids = JSON.parse(h.records.get("ids"));
  assert.equal(ids.service, "ids");
  assert.deepEqual(ids.data, {
    fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
    role: "undergraduate",
    studentId: "EXAMPLE_SYNTHETIC_STUDENT",
  });
  assert.equal(result.sectionId, "xidian.login");
  assert.doesNotMatch(
    JSON.stringify(result),
    /example-synthetic-cookie-secret|example-synthetic-old-tgc|EXAMPLE_SYNTHETIC_STUDENT/,
  );
});

test("postgraduate target is explicit and preserves a previously supplied student id", async () => {
  const h = harness({
    saved: {
      ids: savedSession("ids", IDS, [], { role: "undergraduate", studentId: "EXAMPLE_SYNTHETIC_UG" }),
      ehall: savedSession("ehall", EHALL_API, [], { studentId: "EXAMPLE_SYNTHETIC_UG" }),
      yjspt: savedSession("yjspt", LOGIN_TARGETS.yjspt.service, [], { studentId: "EXAMPLE_SYNTHETIC_PG" }),
    },
  });
  await login(h.ctx, { system: "yjspt" });
  assert.equal(JSON.parse(h.records.get("yjspt")).data.studentId, "EXAMPLE_SYNTHETIC_PG");
  assert.equal(JSON.parse(h.records.get("ids")).data.role, "postgraduate");
  assert.equal(JSON.parse(h.records.get("ids")).data.studentId, "EXAMPLE_SYNTHETIC_PG");
  assert.equal(
    new URL(h.events.find(([kind]) => kind === "open")[1]).searchParams.get("service"),
    LOGIN_TARGETS.yjspt.service,
  );
  assert.equal(JSON.parse(h.records.get("ehall")).data.studentId, "EXAMPLE_SYNTHETIC_UG");
});

test("switching academic role without a matching student id clears the old shared id", async () => {
  const h = harness({
    saved: {
      ids: savedSession("ids", IDS, [], {
        role: "undergraduate",
        studentId: "EXAMPLE_SYNTHETIC_UG",
        fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
      }),
    },
  });
  await login(h.ctx, { system: "yjspt" });
  assert.deepEqual(JSON.parse(h.records.get("ids")).data, {
    role: "postgraduate",
    fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
  });
  assert.equal(JSON.parse(h.records.get("yjspt")).data.studentId, undefined);
});

test("browser snapshots remove deleted known and unknown cookies while preserving unrelated paths", async () => {
  const pgApi = "https://yjspt.xidian.edu.cn/gsapp/sys/yjsemaphome/modules/pubWork/getUserInfo.do";
  const old = savedSession("yjspt", pgApi, [
    { name: "SID", value: "EXAMPLE_SYNTHETIC_DELETED_KNOWN", path: "/gsapp" },
    { name: "UNRELATED", value: "EXAMPLE_SYNTHETIC_UNRELATED", path: "/unvisited" },
  ]);
  old.cookies.push(
    ...normalizeBrowserCookies(pgApi, [{ name: "OLD_UNKNOWN", value: "EXAMPLE_SYNTHETIC_DELETED_UNKNOWN" }]),
  );
  const h = harness({
    saved: {
      ids: savedSession(
        "ids",
        IDS,
        [{ name: "TGC", value: "EXAMPLE_SYNTHETIC_DELETED_TGC", path: "/authserver" }],
        {
          fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
        },
      ),
      yjspt: old,
    },
    cookies: (url) =>
      url.includes("/gsapp/") ? [{ name: "SID", value: "EXAMPLE_SYNTHETIC_NEW", path: "/gsapp" }] : [],
  });
  await login(h.ctx, { system: "yjspt" });
  const session = JSON.parse(h.records.get("yjspt"));
  assert.ok(session.cookies.some((cookie) => cookie.value === "EXAMPLE_SYNTHETIC_NEW"));
  assert.ok(session.cookies.some((cookie) => cookie.value === "EXAMPLE_SYNTHETIC_UNRELATED"));
  assert.doesNotMatch(JSON.stringify(session), /EXAMPLE_SYNTHETIC_DELETED/);
  const ids = JSON.parse(h.records.get("ids"));
  assert.deepEqual(ids.cookies, []);
  assert.equal(ids.data.fingerprint, "EXAMPLE_SYNTHETIC_FINGERPRINT");
});

test("an incomplete MFA login never replaces the prior IDS session or saves a partial snapshot", async () => {
  const h = harness({
    saved: {
      ids: savedSession(
        "ids",
        IDS,
        [{ name: "TGC", value: "EXAMPLE_SYNTHETIC_DELETED", path: "/authserver" }],
        {
          role: "undergraduate",
        },
      ),
    },
    states: [{ ready: false }],
    cookies: () => [],
  });
  await assert.rejects(login(h.ctx, { system: "yjspt" }), /xidian_login_timeout/);
  const ids = JSON.parse(h.records.get("ids"));
  assert.equal(ids.cookies[0].value, "EXAMPLE_SYNTHETIC_DELETED");
  assert.equal(ids.data.role, "undergraduate");
  assert.ok(!h.events.some(([kind]) => kind === "save"));
});

test("card session receives only the actual page openid, never the student id as a substitute", async () => {
  const h = harness({
    states: [{ ready: false }, { ready: true, data: { openid: "example-synthetic-actual-openid" } }],
    saved: {
      ids: savedSession("ids", IDS, [], {
        role: "postgraduate",
        fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
      }),
    },
  });
  const result = await login(h.ctx, { system: "card", studentId: "EXAMPLE_SYNTHETIC_STUDENT" });
  assert.equal(h.events.find(([kind]) => kind === "open")[1], LOGIN_TARGETS.card.openUrl);
  assert.equal(JSON.parse(h.records.get("card")).data.openid, "example-synthetic-actual-openid");
  assert.equal(JSON.parse(h.records.get("card")).data.openidFetchedAt, h.ctx.now());
  assert.deepEqual(JSON.parse(h.records.get("ids")).data, {
    role: "postgraduate",
    fingerprint: "EXAMPLE_SYNTHETIC_FINGERPRINT",
    studentId: "EXAMPLE_SYNTHETIC_STUDENT",
  });
  assert.doesNotMatch(JSON.stringify(result), /example-synthetic-actual-openid/);
});

test("library can collect an HttpOnly JWT through native cookies and stores its group separately", async () => {
  const h = harness({
    states: [{ libraryOrigin: true, ready: false, data: {} }],
    cookies: (url) =>
      url.startsWith("https://mfindxidian.libsp.cn/")
        ? [{ name: "jwt", value: "example-synthetic-library-jwt", isHttpOnly: true }]
        : [],
  });
  const result = await login(h.ctx, { system: "library" });
  const session = JSON.parse(h.records.get("library"));
  assert.deepEqual(session.data, {
    token: "example-synthetic-library-jwt",
    groupCode: "EXAMPLE_SYNTHETIC_GROUP",
  });
  assert.doesNotMatch(JSON.stringify(result), /example-synthetic-library-jwt|EXAMPLE_SYNTHETIC_GROUP/);
});

test("a navigation-masked native error is retried; cancellation rejects without a service write", async () => {
  const h = harness({
    states: [new Error("browser_failed"), { ready: true, data: { openid: "example-synthetic-openid" } }],
  });
  await login(h.ctx, { system: "card" });
  assert.ok(h.callCount() > 2, "one ready snapshot cannot complete login");
  const cancelled = harness({ states: [new Error("script_cancelled")] });
  await assert.rejects(login(cancelled.ctx), /script_cancelled/);
  assert.equal(cancelled.records.has("ehall"), false);
});

test("business waiting is bounded and keeps independently verified IDS without claiming business success", async () => {
  const h = harness({ states: [{ ready: false }] });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.ok(h.callCount() <= 150);
  assert.equal(h.records.has("ehall"), false);
  assert.equal(h.records.has("ids"), true);
  assert.equal(h.events.filter(([kind, key]) => kind === "save" && key === "ids").length, 1);
});

test("a brief ready page followed by MFA cannot save either service or IDS credentials", async () => {
  const h = harness({ stageStates: { ids: [{ ready: true }, { ready: false }] } });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.equal(h.records.size, 0);
  assert.ok(!h.events.some(([kind]) => kind === "save"));
});

test("navigation to MFA during cookie sampling invalidates the final completion check", async () => {
  const h = harness({
    stageStates: { ids: [{ ready: true }, { ready: true }, { ready: true }, { ready: false }] },
  });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.ok(h.events.some(([kind]) => kind === "cookies"));
  assert.ok(!h.events.some(([kind]) => kind === "save"));
});

test("continuously rotating cookies fail within the snapshot budget without saving", async () => {
  let sample = 0;
  const h = harness({ cookies: () => [{ name: "SID", value: `EXAMPLE_SYNTHETIC_ROTATING_${sample++}` }] });
  await assert.rejects(login(h.ctx), /xidian_login_unstable/);
  assert.equal(h.records.size, 0);
  assert.ok(h.callCount() <= 7);
});

test("cookie rotation restarts stability and only the final session is persisted", async () => {
  const h = harness({
    cookies: () => [
      { name: "SID", value: h.callCount() < 3 ? "EXAMPLE_SYNTHETIC_OLD" : "EXAMPLE_SYNTHETIC_FINAL" },
    ],
    onEvaluate: ({ events }) => assert.ok(!events.some(([kind, key]) => kind === "save" && key === "ehall")),
  });
  await login(h.ctx);
  assert.ok(h.callCount() >= 6);
  const session = JSON.parse(h.records.get("ehall"));
  assert.ok(session.cookies.length > 0);
  assert.ok(session.cookies.every((cookie) => cookie.value === "EXAMPLE_SYNTHETIC_FINAL"));
});

test("school-bound login defaults to the correct academic service and rejects cross-school overrides before I/O", async () => {
  for (const role of ["undergraduate", "postgraduate"]) {
    const h = harness();
    const bound = createLogin(role);
    await assert.rejects(
      async () => bound(h.ctx, { role: role === "undergraduate" ? "postgraduate" : "undergraduate" }),
      /school_role_mismatch/,
    );
    assert.deepEqual(h.events, []);
    if (role === "undergraduate") {
      await assert.rejects(async () => bound(h.ctx, { system: "yjspt" }), /school_system_mismatch/);
      assert.deepEqual(h.events, []);
    }
    await bound(h.ctx);
    const open = h.events.find(([kind]) => kind === "open")[1];
    if (role === "undergraduate") assert.equal(open, "https://ehall.xidian.edu.cn/");
    else assert.equal(new URL(open).searchParams.get("service"), LOGIN_TARGETS.yjspt.service);
    assert.equal(JSON.parse(h.records.get("ids")).data.role, role);
  }
  const classroom = harness();
  await createLogin("postgraduate")(classroom.ctx, { system: "ehall" });
  assert.equal(classroom.events.find(([kind]) => kind === "open")[1], "https://ehall.xidian.edu.cn/");
  assert.equal(JSON.parse(classroom.records.get("ids")).data.role, "postgraduate");
});

test("invalid system or missing browser performs no navigation or credential write", async () => {
  const h = harness();
  await assert.rejects(login(h.ctx, { system: "constructor" }), /system_invalid/);
  const withoutBrowser = { ...h.ctx, browser: undefined };
  await assert.rejects(login(withoutBrowser), /browser_required/);
  assert.deepEqual(h.events, []);
});

async function inspect(
  url,
  { openid, cookie = "", passwordForm = false, readyState = "complete", probe } = {},
  system = "library",
) {
  const context = {
    URL,
    URLSearchParams,
    location: { href: url },
    fetch:
      probe ??
      (async () => ({
        ok: true,
        redirected: false,
        json: async () => ({
          code: "0",
          data: { xnxqdm: "2026-2027-1" },
          datas: { dqxnxq: { rows: [{ DM: "2026-2027-1" }] } },
        }),
      })),
    document: {
      cookie,
      readyState,
      querySelector: (selector) =>
        selector === "#pwdFromId"
          ? passwordForm
            ? {}
            : null
          : openid === undefined
            ? null
            : { value: openid },
    },
  };
  const fn = vm.runInNewContext(`(${inspectLoginPage.toString()})`, context);
  return JSON.parse(JSON.stringify(await fn(system, 0)));
}

test("portal probe requires the witnessed logged-in JSON rather than a public portal or login-looking URL", async () => {
  const url = "https://ehall.xidian.edu.cn/new/index_xd.html";
  const probe = async (path, init) => {
    assert.equal(path, "/jsonp/getUserAllUsableApp?searchKey=");
    assert.equal(init.method, "GET");
    assert.equal(init.credentials, "same-origin");
    return { ok: true, json: async () => ({ hasLogin: true, data: [] }) };
  };
  assert.equal((await inspect(url, { probe }, "ehall-portal")).ready, true);
  for (const result of [
    { hasLogin: false, data: [] },
    { hasLogin: "true", data: [] },
    { hasLogin: true },
    {},
  ]) {
    assert.equal(
      (await inspect(url, { probe: async () => ({ ok: true, json: async () => result }) }, "ehall-portal"))
        .ready,
      false,
    );
  }
  for (const bad of [
    "https://ehall.xidian.edu.cn/appShow",
    "https://ehall.xidian.edu.cn.evil.example/new/index_xd.html",
  ]) {
    assert.equal((await inspect(bad, { probe }, "ehall-portal")).ready, false);
  }
});

test("IDS probe verifies an authenticated personal-center endpoint and returns no account settings", async () => {
  const url = "https://ids.xidian.edu.cn/personalInfo/personCenter/index.html";
  const probe = async (path, init) => {
    assert.equal(path, "/personalInfo/accountSecurity/accountSetting");
    assert.equal(init.method, "POST");
    assert.equal(init.credentials, "same-origin");
    return {
      ok: true,
      json: async () => ({
        code: "0",
        datas: { userid: "EXAMPLE_SYNTHETIC_INTERNAL_ID", telephoneNumber: "EXAMPLE_SYNTHETIC_PRIVATE" },
      }),
    };
  };
  const state = await inspect(url, { probe }, "ids");
  assert.deepEqual(state, { ready: true, page: url });
  const mobile = "https://ids.xidian.edu.cn/personalInfo/personalMobile/index.html";
  assert.deepEqual(await inspect(mobile, { probe }, "ids"), { ready: true, page: mobile });
  assert.deepEqual(await inspect(mobile, { probe }, "ehall-portal"), {
    ready: false,
    page: mobile,
    verifiedIdsLanding: true,
  });
  assert.ok(!JSON.stringify(state).includes("EXAMPLE_SYNTHETIC"));
  for (const result of [
    { code: "401" },
    { code: "0", datas: {} },
    { code: "0", datas: { userid: 0 } },
    { code: "0", datas: { userid: "0" } },
  ]) {
    assert.equal(
      (await inspect(url, { probe: async () => ({ ok: true, json: async () => result }) }, "ids")).ready,
      false,
    );
  }
  for (const bad of [
    "https://ids.xidian.edu.cn/authserver/login",
    "http://ids.xidian.edu.cn/personalInfo/personCenter/index.html",
    "https://ids.xidian.edu.cn.evil.example/personalInfo/personCenter/index.html",
  ]) {
    assert.equal((await inspect(bad, { probe }, "ids")).ready, false);
  }
  assert.equal((await inspect(url, { probe, passwordForm: true }, "ids")).ready, false);
  assert.equal(
    (await inspect(url, { probe: async () => ({ ok: true, redirected: true }) }, "ids")).ready,
    false,
  );
});

test("actual page probe requires the correct origin, business route, and hidden card openid", async () => {
  assert.equal(
    (await inspect("https://ids.xidian.edu.cn/authserver/login", { openid: "fake" }, "card")).ready,
    false,
  );
  assert.equal(
    (await inspect("https://v8scan.xidian.edu.cn/home/openXDOAuth2Page", {}, "card")).ready,
    false,
  );
  assert.deepEqual(
    (
      await inspect(
        "https://v8scan.xidian.edu.cn/home/openHomePage",
        { openid: "example-synthetic-openid" },
        "card",
      )
    ).data,
    { openid: "example-synthetic-openid" },
  );
  assert.equal((await inspect("https://ehall.xidian.edu.cn/appShow", {}, "ehall")).ready, false);
  assert.equal(
    (await inspect("https://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do", {}, "ehall")).ready,
    true,
  );
  assert.equal(
    (
      await inspect(
        "https://yjspt.xidian.edu.cn/gsapp/sys/yjsemaphome/portal/index.do",
        { passwordForm: true },
        "yjspt",
      )
    ).ready,
    false,
  );
});

test("academic page completion requires a fully loaded page and authenticated business JSON", async () => {
  const url = "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do";
  for (const readyState of ["loading", "interactive"]) {
    assert.equal((await inspect(url, { readyState }, "ehall")).ready, false);
  }
  for (const probe of [
    async () => ({ ok: true, redirected: true, json: async () => ({}) }),
    async () => ({ ok: true, url: IDS, json: async () => ({}) }),
    async () => ({ ok: false, json: async () => ({}) }),
    async () => ({
      ok: true,
      json: async () => {
        throw new Error("MFA HTML");
      },
    }),
    async () => ({ ok: true, json: async () => ({ code: "401" }) }),
  ]) {
    assert.equal((await inspect(url, { probe }, "ehall")).ready, false);
  }
  for (const system of ["ehall", "yjspt"]) {
    const pg = system === "yjspt";
    const probe = async (path, init) => {
      assert.equal(
        path,
        pg
          ? "/gsapp/sys/yjsemaphome/modules/pubWork/getUserInfo.do"
          : "/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do",
      );
      assert.equal(init.method, "POST");
      assert.equal(init.credentials, "same-origin");
      return {
        ok: true,
        json: async () =>
          pg
            ? { code: "0", data: { xnxqdm: "2026-2027-1" } }
            : { datas: { dqxnxq: { rows: [{ DM: "2026-2027-1" }] } } },
      };
    };
    const state = await inspect(pg ? LOGIN_TARGETS.yjspt.service : url, { probe }, system);
    assert.equal(state.ready, true);
    assert.deepEqual(state.data, pg ? {} : { origin: "https://ehall.xidian.edu.cn" });
  }
});

test("verified HTTP E-Hall page retains its actual origin and still requires authenticated business JSON", async () => {
  const url = "http://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do";
  const state = await inspect(url, {}, "ehall");
  assert.equal(state.ready, true);
  assert.deepEqual(state.data, { origin: "http://ehall.xidian.edu.cn" });
  assert.equal((await inspect(url, { probe: async () => ({ ok: false }) }, "ehall")).ready, false);
  for (const denied of [
    "http://ehall.xidian.edu.cn:8080/jwapp/index.do",
    "http://ehall.xidian.edu.cn.evil.example/jwapp/index.do",
  ]) {
    assert.equal((await inspect(denied, {}, "ehall")).ready, false);
  }
  const h = harness({ states: [{ ready: true, page: url, data: state.data }] });
  await createLogin("undergraduate")(h.ctx);
  const cookies = h.events.filter(([kind]) => kind === "cookies").map(([, target]) => target);
  assert.ok(cookies.some((target) => target.startsWith("http://ehall.xidian.edu.cn/")));
  assert.equal(
    cookies.some((target) => target.startsWith("https://ehall.xidian.edu.cn/")),
    false,
  );
  assert.equal(JSON.parse(h.records.get("ehall")).data.origin, "http://ehall.xidian.edu.cn");
});

test("actual library probe reads URL query/hash or jwt cookie without inspecting guessed storage keys", async () => {
  assert.equal(
    (await inspect("https://mfindxidian.libsp.cn/?jwt=example-synthetic-query")).data.token,
    "example-synthetic-query",
  );
  assert.equal(
    (await inspect("https://mfindxidian.libsp.cn/#/home?jwt=example-synthetic-hash")).data.token,
    "example-synthetic-hash",
  );
  assert.equal(
    (await inspect("https://mfindxidian.libsp.cn/", { cookie: "other=a; jwt=example-synthetic-cookie" })).data
      .token,
    "example-synthetic-cookie",
  );
  assert.equal(
    (await inspect("https://tyrzfw.chaoxing.com/?jwt=example-synthetic-wrong-origin")).ready,
    false,
  );
});

test("library group comes from actual JWT metadata or the evidenced API, never an invented account", async () => {
  let fetched = false;
  const token = `synthetic.${Buffer.from(JSON.stringify({ groupCode: "EXAMPLE_SYNTHETIC_JWT_GROUP" })).toString("base64url")}.signature`;
  let fn = vm.runInNewContext(`(${libraryGroupCode.toString()})`, {
    atob,
    fetch: async () => {
      fetched = true;
      throw new Error("unexpected");
    },
  });
  assert.equal(await fn(token), "EXAMPLE_SYNTHETIC_JWT_GROUP");
  assert.equal(fetched, false);
  fn = vm.runInNewContext(`(${libraryGroupCode.toString()})`, {
    atob,
    fetch: async (url, init) => {
      assert.equal(url, "/find/homePage/getGroupCode");
      assert.equal(init.headers.jwtOpacAuth, "example-synthetic-opaque-token");
      return { ok: true, json: async () => ({ data: { groupCode: "EXAMPLE_SYNTHETIC_API_GROUP" } }) };
    },
  });
  assert.equal(await fn("example-synthetic-opaque-token"), "EXAMPLE_SYNTHETIC_API_GROUP");
});

test("late staged E-Hall success with restored cookies and stage logs stays within the host budget", async () => {
  const h = harness({
    states: [
      ...Array.from({ length: 121 }, () => ({ ready: false })),
      { ready: true, page: "ehall", data: { step: 1 } },
      { ready: true, page: "ehall", data: { step: 2 } },
      ...Array.from({ length: 4 }, () => ({ ready: true, page: "ehall", data: {} })),
    ],
    saved: {
      ids: savedSession("ids", IDS, [{ name: "TGC", value: "EXAMPLE_SYNTHETIC_IDS", path: "/" }]),
      ehall: savedSession("ehall", EHALL_API, [{ name: "SID", value: "EXAMPLE_SYNTHETIC_EHALL", path: "/" }]),
    },
  });
  let calls = 0;
  const logs = [];
  h.ctx.now = () => h.totalEvaluations() * 500;
  h.ctx.log = (level, message) => {
    calls++;
    logs.push([level, message]);
  };
  for (const group of [h.ctx.browser, h.ctx.credentials]) {
    for (const [name, operation] of Object.entries(group)) {
      group[name] = (...args) => {
        calls++;
        return operation(...args);
      };
    }
  }
  await login(h.ctx);
  assert.ok(calls <= 256, `host calls: ${calls}`);
  assert.ok(h.totalEvaluations() <= 137); // Shared polls plus IDS/business final validation.
  assert.ok(h.totalEvaluations() >= 135);
  assert.deepEqual(logs, [
    ["info", "xidian_login_open:ehall_portal"],
    ["info", "xidian_login_verified:ehall_portal"],
    ["info", "xidian_login_saved:ids"],
    ["info", "xidian_login_open:ehall"],
    ["info", "xidian_login_saved:ehall"],
  ]);
});

test("the official IDS account can be retained internally without declaring login success", async () => {
  const probe = vm.runInNewContext(`(${inspectLoginPage.toString()})`, {
    URL,
    location: { href: "https://ids.xidian.edu.cn/authserver/login" },
    document: { querySelector: (selector) => (selector === "#username" ? { value: "00000000" } : null) },
  });
  const state = JSON.parse(JSON.stringify(await probe("ehall", 0)));
  assert.deepEqual(state, { ready: false, studentId: "00000000" });
  const h = harness({ stageStates: { "ehall-portal": [state, { ready: true }] } });
  const result = await login(h.ctx);
  assert.equal(JSON.parse(h.records.get("ehall")).data.studentId, "00000000");
  assert.ok(!JSON.stringify(result).includes("00000000"));
});

test("staged login fits the host budget with maximum snapshots, restore URLs, wait logs and all 135 polls", async () => {
  for (const mobile of [false, true]) {
    let activeStage,
      idsCaptures = 0,
      businessCaptures = 0,
      calls = 0;
    const h = harness({
      saved: {
        ids: savedSession("ids", IDS, [{ name: "SID", value: "EXAMPLE_SYNTHETIC_OLD_IDS", path: "/" }]),
        ehall: savedSession("ehall", EHALL_API, [
          { name: "SID", value: "EXAMPLE_SYNTHETIC_OLD_BUSINESS", path: "/" },
        ]),
      },
      states: [
        ...Array.from({ length: mobile ? 117 : 118 }, (_, i) => ({
          ready: false,
          phase: i % 2 ? "business_data_invalid" : "business_page_pending",
        })),
        { ready: true, page: "ehall", data: {} },
      ],
      stageStates: mobile
        ? { "ehall-portal": [{ ready: false, verifiedIdsLanding: true }, { ready: true }] }
        : {},
      onStageEvaluate: ({ stage }) => {
        activeStage = stage;
      },
      onEvaluate: () => {
        activeStage = "ehall";
      },
      cookies: (url) => {
        if (activeStage === "ids" && url === IDS) idsCaptures++;
        if (activeStage === "ehall" && url === LOGIN_TARGETS.ehall.openUrl.split("?")[0]) businessCaptures++;
        const rotated = activeStage === "ids" ? idsCaptures >= 2 : businessCaptures >= 3;
        return [
          {
            name: "SID",
            value: rotated ? "EXAMPLE_SYNTHETIC_ROTATED" : "EXAMPLE_SYNTHETIC_INITIAL",
            path: "/",
          },
        ];
      },
    });
    h.ctx.now = () => h.totalEvaluations() * 500;
    h.ctx.log = () => {
      calls++;
    };
    for (const group of [h.ctx.browser, h.ctx.credentials]) {
      for (const [name, operation] of Object.entries(group)) {
        group[name] = (...args) => {
          calls++;
          return operation(...args);
        };
      }
    }
    await login(h.ctx);
    assert.equal(idsCaptures, 4);
    assert.equal(businessCaptures, 5);
    assert.equal(h.totalEvaluations(), 137);
    assert.ok(calls <= (mobile ? 254 : 250), `host calls: ${calls}`);
    assert.equal(h.records.size, 2);
  }
});
