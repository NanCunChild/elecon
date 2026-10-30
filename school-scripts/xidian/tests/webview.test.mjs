// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
import assert from "node:assert/strict";
import test from "node:test";
import { createLogin } from "../src/login.js";
import { harness, response } from "./webview.fixture.mjs";

test("IDS settles in two snapshots 250ms apart and blocks touches before business exchange", async () => {
  const h = harness();
  await createLogin("undergraduate")(h.ctx);
  const probes = h.events.filter(([type]) => type === "inspect");
  assert.deepEqual(
    probes.map(([, , delay]) => delay),
    [0, 250],
  );
  assert.equal(h.events.filter(([type]) => type === "cookies").length, 12);
  const busyAt = h.events.findIndex(([type, busy]) => type === "busy" && busy);
  assert.ok(busyAt < h.events.findIndex(([type]) => type === "cookies"));
  assert.ok(busyAt < h.events.findIndex(([type]) => type === "request"));
});

test("IDS cookie rotation restarts settling and cookie order does not delay completion", async () => {
  for (const rotate of [true, false]) {
    const h = harness();
    let reads = 0;
    h.ctx.browser.cookies = async () => {
      const sample = Math.floor(reads++ / 6);
      const cookies = [
        {
          name: "CASTGC",
          value: rotate && sample === 0 ? "EXAMPLE_SYNTHETIC_INITIAL" : "EXAMPLE_SYNTHETIC_GLOBAL",
          path: "/authserver",
        },
        { name: "JSESSIONID", value: "EXAMPLE_SYNTHETIC_SESSION", path: "/" },
      ];
      return sample % 2 ? cookies.reverse() : cookies;
    };
    await createLogin("undergraduate")(h.ctx);
    assert.equal(reads, rotate ? 18 : 12);
  }
});

test("empty or continuously rotating IDS cookies never commit a session", async () => {
  for (const empty of [false, true]) {
    const h = harness();
    let sample = 0;
    h.ctx.browser.cookies = async () =>
      empty ? [] : [{ name: "CASTGC", value: `EXAMPLE_SYNTHETIC_ROTATING_${sample++}`, path: "/authserver" }];
    await assert.rejects(createLogin("undergraduate")(h.ctx), /xidian_login_unstable/);
    assert.equal(h.records.size, 0);
    assert.ok(!h.events.some(([type]) => type === "request"));
  }
});

test("cancellation while harvesting under the overlay never saves or exchanges a session", async () => {
  const h = harness();
  h.ctx.browser.cookies = async () => {
    throw new Error("script_cancelled");
  };
  await assert.rejects(createLogin("undergraduate")(h.ctx), /script_cancelled/);
  assert.ok(h.events.some(([type, busy]) => type === "busy" && busy));
  assert.equal(h.records.size, 0);
  assert.ok(!h.events.some(([type]) => type === "request"));
});

test("returning to MFA clears the overlay and navigation during snapshots cannot save", async () => {
  for (const lateNavigation of [false, true]) {
    const h = harness();
    const evaluate = h.ctx.browser.evaluate;
    let probes = 0;
    h.ctx.browser.evaluate = async (fn, ...args) => {
      const state = await evaluate(fn, ...args);
      if (fn.name === "inspectIdsLocation") return null;
      probes++;
      return (!lateNavigation && probes > 1) || (lateNavigation && probes > 2) ? { ready: false } : state;
    };
    await assert.rejects(createLogin("undergraduate")(h.ctx), /xidian_login_timeout/);
    assert.ok(h.events.some(([type, busy]) => type === "busy" && busy === false));
    assert.equal(h.records.size, 0);
  }
});

for (const role of ["undergraduate", "postgraduate"]) {
  test(`${role}: default login only renders official IDS and commits verified API session`, async () => {
    const system = role === "postgraduate" ? "yjspt" : "ehall";
    const h = harness({ system });
    const out = await createLogin(role)(h.ctx, { studentId: "EXAMPLE_SYNTHETIC_ACCOUNT" });
    assert.equal(h.events.filter(([type]) => type === "open").length, 1);
    const saved = JSON.parse(h.records.get(system));
    assert.equal(saved.data.authFlow, "webview");
    assert.equal(saved.data.studentId, "EXAMPLE_SYNTHETIC_ACCOUNT");
    assert.equal(saved.data.currentTerm, "2026-2027-1");
    assert.equal(saved.cookies[0].name, "MOD_AUTH_CAS");
    assert.equal(JSON.parse(h.records.get("ids")).cookies[0].value, "EXAMPLE_SYNTHETIC_ROTATED");
    assert.ok(
      h.events.findIndex(([type, key]) => type === "save" && key === "ids") <
        h.events.findIndex(([type]) => type === "request"),
    );
    assert.ok(!JSON.stringify(out).includes("SYNTHETIC"));
    assert.ok(!JSON.stringify(h.events.filter(([type]) => type === "log")).includes("SYNTHETIC"));
  });
}

test("business failure preserves verified SSO and the previous business record even after Set-Cookie", async () => {
  const h = harness({ badProbe: true });
  const old = JSON.stringify({
    version: 1,
    service: "ehall",
    cookies: [],
    data: { marker: "EXAMPLE_SYNTHETIC_OLD" },
  });
  h.records.set("ehall", old);
  await assert.rejects(createLogin("undergraduate")(h.ctx), /academic_response_invalid/);
  assert.equal(h.records.get("ehall"), old);
  assert.ok(!h.events.some(([type, key]) => type === "save" && key === "ehall"));
  assert.equal(JSON.parse(h.records.get("ids")).cookies[0].value, "EXAMPLE_SYNTHETIC_ROTATED");
});

test("unverified IDS and cancellation never issue native requests or save cookies", async () => {
  for (const options of [{ idsReady: false }, { cancel: true }]) {
    const h = harness(options);
    await assert.rejects(createLogin("undergraduate")(h.ctx), /xidian_login_timeout|script_cancelled/);
    assert.equal(h.records.size, 0);
    assert.ok(!h.events.some(([type]) => type === "request"));
  }
});

test("service MFA or renewed password page fails without submitting credentials or replacing business", async () => {
  const h = harness();
  h.ctx.fetch = async (url, init) => {
    assert.equal(init.method, "GET");
    return response(url, "<form id=pwdFromId>学校 MFA</form>");
  };
  await assert.rejects(createLogin("undergraduate")(h.ctx), /xidian_login_required_ehall/);
  assert.ok(h.records.has("ids"));
  assert.ok(!h.records.has("ehall"));
});

test("service redirect outside declared origins is rejected before sending cookies", async () => {
  const h = harness();
  let requests = 0;
  h.ctx.fetch = async (url) => {
    requests++;
    return response(url, "", { status: 302, location: "https://evil.invalid/?ticket=EXAMPLE_SYNTHETIC" });
  };
  await assert.rejects(createLogin("undergraduate")(h.ctx), /xidian_redirect_origin_denied/);
  assert.equal(requests, 1);
  assert.ok(h.records.has("ids"));
  assert.ok(!h.records.has("ehall"));
});

test("harvested browser flow keeps the actual HTTP business origin without inheriting PDA rewrites", async () => {
  const h = harness();
  h.records.set(
    "ids",
    JSON.stringify({ version: 1, service: "ids", cookies: [], data: { authFlow: "pda" } }),
  );
  const seen = [];
  h.ctx.fetch = async (url, init) => {
    seen.push(url);
    if (url.startsWith("https://ids.xidian.edu.cn/"))
      return response(url, "", {
        status: 302,
        location: "http://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do",
      });
    assert.equal(new URL(url).origin, "http://ehall.xidian.edu.cn");
    return response(
      url,
      init.method === "POST"
        ? {
            code: "0",
            datas: { dqxnxq: { rows: [{ DM: "2026-2027-1" }] } },
          }
        : "<html>调用接口异常</html>",
      { cookies: ["MOD_AUTH_CAS=EXAMPLE_SYNTHETIC_HTTP; Path=/; HttpOnly"] },
    );
  };
  await createLogin("undergraduate")(h.ctx);
  assert.equal(seen.length, 3);
  assert.equal(JSON.parse(h.records.get("ehall")).data.origin, "http://ehall.xidian.edu.cn");
  assert.equal(JSON.parse(h.records.get("ids")).data.authFlow, "webview");
});
