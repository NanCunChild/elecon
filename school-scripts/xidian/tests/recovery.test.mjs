// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
import assert from "node:assert/strict";
import test from "node:test";
import { recoverAcademicSession } from "../src/login.js";
import { harness, response } from "./webview.fixture.mjs";

function savedSso(h, role = "undergraduate") {
  h.records.set(
    "ids",
    JSON.stringify({
      version: 1,
      service: "ids",
      data: { role, studentId: "SYNTHETIC-ACCOUNT" },
      cookies: [
        {
          name: "CASTGC",
          value: "EXAMPLE_SYNTHETIC_GLOBAL",
          domain: "ids.xidian.edu.cn",
          hostOnly: true,
          path: "/authserver",
          isSecure: true,
          isHttpOnly: true,
        },
      ],
    }),
  );
}

for (const [role, system] of [
  ["undergraduate", "ehall"],
  ["postgraduate", "yjspt"],
  ["postgraduate", "ehall"],
]) {
  test(`${role}/${system}: child ticket exchange verifies API without any browser access`, async () => {
    const h = harness({ system });
    savedSso(h, role);
    delete h.ctx.browser;
    await recoverAcademicSession(h.ctx, role, system);
    assert.equal(JSON.parse(h.records.get(system)).data.currentTerm, "2026-2027-1");
    assert.equal(h.events.filter(([type]) => type === "request").length, 3);
    assert.ok(!h.events.some(([type]) => type === "open"));
  });
}

test("primary login navigation allows one visible fallback, without password submission", async () => {
  const h = harness();
  savedSso(h);
  const fetch = h.ctx.fetch;
  let first = true;
  h.ctx.fetch = async (url, init) => {
    if (first) {
      first = false;
      assert.equal(init.method, "GET");
      return response(url, "<form id='pwdFromId'></form>");
    }
    return fetch(url, init);
  };
  await recoverAcademicSession(h.ctx, "undergraduate", "ehall");
  assert.equal(h.events.filter(([type]) => type === "open").length, 1);
  assert.ok(h.records.has("ehall"));
});

test("bad business probe, transport failure, cancellation and rejected child do not reopen login", async () => {
  for (const scenario of ["invalid", "network", "cancel", "child"]) {
    const h = harness({ badProbe: scenario === "invalid" });
    savedSso(h);
    const previous = JSON.stringify({ version: 1, service: "ehall", cookies: [], data: { marker: "OLD" } });
    h.records.set("ehall", previous);
    const fetch = h.ctx.fetch;
    h.ctx.fetch = async (url, init) => {
      if (scenario === "network") throw new Error("network_timeout");
      if (scenario === "cancel") throw new Error("script_cancelled");
      if (scenario === "child" && init.method === "POST") return response(url, "", { status: 401 });
      return fetch(url, init);
    };
    await assert.rejects(recoverAcademicSession(h.ctx, "undergraduate", "ehall"));
    assert.equal(h.records.get("ehall"), previous);
    assert.ok(!h.events.some(([type]) => type === "open"));
  }
});

test("failed credential persistence is not success or a reason to submit login again", async () => {
  const h = harness();
  savedSso(h);
  const set = h.ctx.credentials.set;
  h.ctx.credentials.set = async (key, value, options) => {
    if (key === "ehall") throw new Error("storage_failed");
    return set(key, value, options);
  };
  await assert.rejects(recoverAcademicSession(h.ctx, "undergraduate", "ehall"), /storage_failed/);
  assert.ok(!h.records.has("ehall"));
  assert.ok(!h.events.some(([type]) => type === "open"));
});

test("IDS HTTP refusal, rate limit, outage and non-login HTML never trigger fallback", async () => {
  for (const status of [200, 403, 429, 500]) {
    const h = harness();
    savedSso(h);
    h.ctx.fetch = async (url) =>
      response(url, status === 200 ? "<html>Maintenance</html>" : "<form id=pwdFromId></form>", { status });
    await assert.rejects(
      recoverAcademicSession(h.ctx, "undergraduate", "ehall"),
      /academic_response_invalid/,
    );
    assert.ok(!h.events.some(([type]) => type === "open"));
    assert.ok(!h.records.has("ehall"));
  }
});

test("recovery cannot switch school role or use another academic system", async () => {
  const h = harness();
  savedSso(h, "postgraduate");
  await assert.rejects(recoverAcademicSession(h.ctx, "undergraduate", "yjspt"), /school_system_mismatch/);
  assert.equal(h.events.length, 0);
});

test("installed postgraduate role replaces stale metadata when refreshing its own service", async () => {
  const h = harness({ system: "yjspt" });
  savedSso(h, "undergraduate");
  delete h.ctx.browser;
  await recoverAcademicSession(h.ctx, "postgraduate", "yjspt");
  assert.equal(JSON.parse(h.records.get("yjspt")).data.role, "postgraduate");
  assert.ok(!h.records.has("ehall"));
});
