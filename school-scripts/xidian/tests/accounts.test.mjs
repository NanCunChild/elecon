// Synthetic account checks; no school traffic, browser or password submission.
import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { harness, response } from "./webview.fixture.mjs";

const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/accounts.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const { createAccountSession } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString("base64")}`
);

function accountHarness({ system = "ehall", ids = true, child = true, rejectChild = true } = {}) {
  const h = harness({ system });
  const reports = [];
  const interactions = [];
  if (ids)
    h.records.set(
      "ids",
      JSON.stringify({
        version: 1,
        service: "ids",
        data: { studentId: "SYNTHETIC-ACCOUNT" },
        cookies: [
          {
            name: "CASTGC",
            value: "EXAMPLE_SYNTHETIC_GLOBAL",
            domain: "ids.xidian.edu.cn",
            hostOnly: true,
            path: "/authserver",
            isSecure: true,
          },
        ],
      }),
    );
  if (child)
    h.records.set(
      system,
      JSON.stringify({
        version: 1,
        service: system,
        data: { studentId: "SYNTHETIC-OLD" },
        cookies: [
          {
            name: "MOD_AUTH_CAS",
            value: "EXAMPLE_STALE",
            domain: new URL(h.origin).host,
            hostOnly: true,
            path: "/",
            isSecure: true,
          },
        ],
      }),
    );
  h.ctx.accounts = {
    report: async (id, event) => {
      assert.equal(id, "school");
      reports.push(event);
    },
    password: async () => {
      interactions.push("password");
      assert.fail("status must never retrieve a password");
    },
  };
  h.ctx.browser = new Proxy(
    {},
    {
      get() {
        interactions.push("browser");
        assert.fail("status must never access a browser");
      },
    },
  );
  const fetch = h.ctx.fetch;
  let exchanges = 0;
  h.ctx.fetch = async (url, init) => {
    if (url.startsWith("https://ids.xidian.edu.cn/")) exchanges++;
    if (rejectChild && new URL(url).origin === h.origin && init.method === "POST" && exchanges === 0)
      return response(url, "", { status: 401 });
    return fetch(url, init);
  };
  return { ...h, reports, interactions, exchanges: () => exchanges };
}

async function status(h, role = "undergraduate") {
  const result = await createAccountSession(role)(h.ctx, { account: "school", operation: "status" });
  assert.deepEqual(h.interactions, [], "status must stay noninteractive even when failures are caught");
  return result;
}

for (const [role, system] of [
  ["undergraduate", "ehall"],
  ["postgraduate", "yjspt"],
]) {
  test(`${role}: rejected child refreshes existing IDS once and reports verified service`, async () => {
    const h = accountHarness({ system });
    const result = await status(h, role);
    assert.equal(result.status, "authenticated");
    assert.equal(result.accountId, "SYNTHETIC-ACCOUNT");
    assert.ok(result.checkedAt);
    assert.equal(h.exchanges(), 1);
    assert.deepEqual(h.reports, [{ status: "authenticated", reason: "verified" }]);
  });
}

test("valid child is verified without an IDS exchange, even without saved primary cookies", async () => {
  const h = accountHarness({ ids: false, rejectChild: false });
  const result = await status(h);
  assert.equal(result.status, "authenticated");
  assert.equal(result.accountId, "SYNTHETIC-OLD");
  assert.equal(h.exchanges(), 0);
  assert.deepEqual(h.reports, [{ status: "authenticated", reason: "verified" }]);
});

test("IDS alone can restore a missing child; legacy status also never opens login", async () => {
  const h = accountHarness({ child: false });
  delete h.ctx.accounts;
  const result = await createAccountSession("undergraduate")(h.ctx, {
    account: "school",
    operation: "status",
  });
  assert.equal(result.status, "authenticated");
  assert.equal(result.accountId, "SYNTHETIC-ACCOUNT");
  assert.equal(h.exchanges(), 1);
});

test("new account is signed out without a request; missing IDS after child rejection stays unknown", async () => {
  for (const child of [false, true]) {
    const h = accountHarness({ ids: false, child });
    const result = await createAccountSession("undergraduate")(h.ctx, {
      account: "school",
      operation: "status",
    });
    assert.equal(result.status, child ? "unknown" : "signedOut");
    assert.deepEqual(h.reports, [
      {
        status: child ? "unknown" : "signedOut",
        reason: child ? "networkUnknown" : "signedOut",
      },
    ]);
    assert.equal(h.exchanges(), 0);
    if (!child) assert.equal(h.events.length, 0);
  }
});

test("only a successful IDS response with the primary login form proves primary expiry", async () => {
  const h = accountHarness();
  const fetch = h.ctx.fetch;
  h.ctx.fetch = async (url, init) =>
    url.startsWith("https://ids.xidian.edu.cn/")
      ? response(url, "<form id='pwdFromId'></form>")
      : fetch(url, init);
  const result = await createAccountSession("undergraduate")(h.ctx, {
    account: "school",
    operation: "status",
  });
  assert.equal(result.status, "expired");
  assert.ok(result.checkedAt);
  assert.deepEqual(h.reports, [{ status: "expired", reason: "primaryExpired" }]);
});

test("transport, forbidden, rate-limited, malformed and rejected refreshed child remain unknown", async () => {
  for (const scenario of ["network", "forbidden", "rateLimit", "maintenance", "child", "invalid"]) {
    const h = accountHarness();
    const fetch = h.ctx.fetch;
    let idsReached = false;
    h.ctx.fetch = async (url, init) => {
      if (scenario === "network") throw new Error("network_timeout");
      if (url.startsWith("https://ids.xidian.edu.cn/")) {
        idsReached = true;
        if (scenario === "forbidden" || scenario === "rateLimit")
          return response(url, "<form id='pwdFromId'></form>", {
            status: scenario === "forbidden" ? 403 : 429,
          });
        if (scenario === "maintenance") return response(url, "<html>Maintenance</html>");
      }
      if (idsReached && init.method === "POST") {
        if (scenario === "child") return response(url, "", { status: 401 });
        if (scenario === "invalid") return response(url, { code: "0", datas: {} });
      }
      return fetch(url, init);
    };
    const result = await createAccountSession("undergraduate")(h.ctx, {
      account: "school",
      operation: "status",
    });
    assert.equal(result.status, "unknown", scenario);
    assert.deepEqual(h.reports, [{ status: "unknown", reason: "networkUnknown" }], scenario);
    assert.ok(h.exchanges() <= 1, scenario);
    assert.equal(JSON.parse(h.records.get("ehall")).data.studentId, "SYNTHETIC-OLD", scenario);
  }
});

test("APPTunnel account invokes its declared login target and keeps status read-only", async () => {
  const calls = [];
  const ctx = {
    appTunnel: {
      login: async (...args) => {
        calls.push(["login", ...args]);
        return { status: "authenticated" };
      },
      status: async (...args) => {
        calls.push(["status", ...args]);
        return { status: "unknown" };
      },
    },
  };
  const run = createAccountSession("undergraduate");
  assert.equal((await run(ctx, { account: "apptunnel", operation: "login" })).status, "authenticated");
  assert.equal((await run(ctx, { account: "apptunnel", operation: "status" })).status, "unknown");
  assert.deepEqual(calls, [
    ["login", "hermes-atrust", { accountId: "apptunnel" }],
    ["status", "hermes-atrust"],
  ]);
});
