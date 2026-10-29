// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { inspectLoginPage, LOGIN_TARGETS, libraryGroupCode, login } from "../src/login.js";
import { normalizeBrowserCookies } from "../src/session.js";

const IDS = "https://ids.xidian.edu.cn/authserver/login";
const EHALL_API = "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/xskcb/xskcb.do";

function harness({
  states = [{ ready: true, data: {} }],
  saved = {},
  cookies,
  groupCode = "EXAMPLE_SYNTHETIC_GROUP",
} = {}) {
  let clock = 1000;
  let calls = 0;
  const events = [];
  const records = new Map(Object.entries(saved).map(([key, value]) => [key, JSON.stringify(value)]));
  const ctx = {
    now: () => clock,
    credentials: {
      async get(key, options) {
        assert.equal(options.namespace, "xidian.auth");
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
        calls++;
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
  return { ctx, events, records, callCount: () => calls };
}

function savedSession(service, url, rawCookies, data = {}) {
  return { version: 1, service, cookies: normalizeBrowserCookies(url, rawCookies), data, updatedAt: 100 };
}

test("restores IDS and target cookies before opening CAS, then saves each API path and safe summary", async () => {
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
  assert.equal(new URL(open).origin, "https://ids.xidian.edu.cn");
  assert.equal(new URL(open).searchParams.get("service"), LOGIN_TARGETS.ehall.service);
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
  const old = savedSession("ehall", EHALL_API, [
    { name: "SID", value: "EXAMPLE_SYNTHETIC_DELETED_KNOWN", path: "/jwapp" },
    { name: "UNRELATED", value: "EXAMPLE_SYNTHETIC_UNRELATED", path: "/unvisited" },
  ]);
  old.cookies.push(
    ...normalizeBrowserCookies(EHALL_API, [
      { name: "OLD_UNKNOWN", value: "EXAMPLE_SYNTHETIC_DELETED_UNKNOWN" },
    ]),
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
      ehall: old,
    },
    cookies: (url) =>
      url.includes("/jwapp/") ? [{ name: "SID", value: "EXAMPLE_SYNTHETIC_NEW", path: "/jwapp" }] : [],
  });
  await login(h.ctx);
  const session = JSON.parse(h.records.get("ehall"));
  assert.ok(session.cookies.some((cookie) => cookie.value === "EXAMPLE_SYNTHETIC_NEW"));
  assert.ok(session.cookies.some((cookie) => cookie.value === "EXAMPLE_SYNTHETIC_UNRELATED"));
  assert.doesNotMatch(JSON.stringify(session), /EXAMPLE_SYNTHETIC_DELETED/);
  const ids = JSON.parse(h.records.get("ids"));
  assert.deepEqual(ids.cookies, []);
  assert.equal(ids.data.fingerprint, "EXAMPLE_SYNTHETIC_FINGERPRINT");
});

test("an incomplete login still persists an empty IDS snapshot after browser deletion", async () => {
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
  assert.deepEqual(ids.cookies, []);
  assert.equal(ids.data.role, "undergraduate");
  assert.ok(h.events.some(([kind, service]) => kind === "save" && service === "ids"));
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
  assert.equal(h.callCount(), 2);
  const cancelled = harness({ states: [new Error("script_cancelled")] });
  await assert.rejects(login(cancelled.ctx), /script_cancelled/);
  assert.equal(cancelled.records.has("ehall"), false);
});

test("waiting is bounded and does not claim success for an uncompleted official login", async () => {
  const h = harness({ states: [{ ready: false }] });
  await assert.rejects(login(h.ctx), /xidian_login_timeout/);
  assert.ok(h.callCount() <= 150);
  assert.equal(h.records.has("ehall"), false);
  assert.equal(JSON.parse(h.records.get("ids")).service, "ids");
  assert.equal(JSON.parse(h.records.get("ids")).data.role, undefined);
});

test("invalid system or missing browser performs no navigation or credential write", async () => {
  const h = harness();
  await assert.rejects(login(h.ctx, { system: "constructor" }), /system_invalid/);
  const withoutBrowser = { ...h.ctx, browser: undefined };
  await assert.rejects(login(withoutBrowser), /browser_required/);
  assert.deepEqual(h.events, []);
});

async function inspect(url, { openid, cookie = "", passwordForm = false } = {}, system = "library") {
  const context = {
    URL,
    URLSearchParams,
    location: { href: url },
    document: {
      cookie,
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
