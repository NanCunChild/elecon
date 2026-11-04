// Synthetic official-page DOM and native bridge; never real credentials.
import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { recoverAcademicSession } from "../src/login.js";
import { inspectPasswordOutcome, passwordLogin, submitSavedPassword } from "../src/webview_login.js";
import { harness, response } from "./webview.fixture.mjs";

function passwordHarness(options = {}) {
  const h = harness(options);
  const calls = [];
  const evaluate = h.ctx.browser.evaluate;
  h.ctx.browser.evaluate = async (fn, ...args) => {
    if (fn.name === "submitSavedPassword") {
      if (args[2] === true) return "ready";
      calls.push(["submit", ...args]);
      if (options.navigationAfterClick) throw new Error("browser_navigation_changed");
      return "submitted";
    }
    if (fn.name === "inspectPasswordOutcome") return options.outcome ?? null;
    return evaluate(fn, ...args);
  };
  h.ctx.accounts = {
    async password(id, request) {
      calls.push(["password", id, request]);
      if (options.cancel) return null;
      if (options.fallback) {
        const error = new Error("account_interactive_fallback");
        error.code = error.message;
        throw error;
      }
      return { username: "EXAMPLE_USER", password: "EXAMPLE_PASSWORD", attemptId: "EXAMPLE_ATTEMPT" };
    },
    async completePassword(id, request) {
      calls.push(["complete", id, request]);
      if (request.outcome === "authenticated") {
        assert.ok(
          h.records.has(options.system ?? "ehall"),
          "commit only after business probe and cookie storage",
        );
      }
      if (options.storageFailure) {
        const error = new Error("account_storage_failed");
        error.code = error.message;
        throw error;
      }
    },
    async report(id, event) {
      calls.push(["report", id, event]);
    },
  };
  return { ...h, calls };
}

for (const [role, system] of [
  ["undergraduate", "ehall"],
  ["postgraduate", "yjspt"],
]) {
  test(`${role}: saved password submits once on IDS then commits after the real academic probe`, async () => {
    const h = passwordHarness({ system });
    await passwordLogin(h.ctx, { system }, role);
    assert.equal(h.calls.filter((c) => c[0] === "submit").length, 1);
    assert.deepEqual(h.calls.at(-1), [
      "complete",
      "school",
      { attemptId: "EXAMPLE_ATTEMPT", outcome: "authenticated" },
    ]);
    assert.equal(h.records.has(system), true);
    assert.equal(h.events.filter((e) => e[0] === "restore").length, 0);
  });
}
for (const outcome of ["credentialsRejected", "interactionRequired", "accountDisabled"]) {
  test(`${outcome}: password flow stops immediately without service exchange or resubmit`, async () => {
    const h = passwordHarness({ outcome });
    await assert.rejects(
      passwordLogin(h.ctx, { system: "ehall" }, "undergraduate"),
      (e) => e.authOutcome === outcome,
    );
    assert.equal(h.calls.filter((c) => c[0] === "submit").length, 1);
    assert.deepEqual(h.calls.at(-1)[2], { attemptId: "EXAMPLE_ATTEMPT", outcome });
    assert.equal(h.events.filter((e) => e[0] === "request").length, 0);
  });
}
test("a lost DOM return after password click never replays submission", async () => {
  const h = passwordHarness({ navigationAfterClick: true });
  await passwordLogin(h.ctx, { system: "ehall" }, "undergraduate");
  assert.equal(h.calls.filter((c) => c[0] === "submit").length, 1);
});
test("cancel leaves browser closed and explicit fallback uses normal official login", async () => {
  const cancelled = passwordHarness({ cancel: true });
  await assert.rejects(passwordLogin(cancelled.ctx, { system: "ehall" }, "undergraduate"), /input_cancelled/);
  assert.equal(cancelled.events.filter((e) => e[0] === "open").length, 0);
  const fallback = passwordHarness({ fallback: true });
  await passwordLogin(fallback.ctx, { system: "ehall" }, "undergraduate");
  assert.equal(fallback.calls.filter((c) => c[0] === "submit" || c[0] === "complete").length, 0);
});
test("bad business data and storage failure never claim verified password success or retry", async () => {
  const failed = passwordHarness({ badProbe: true });
  await assert.rejects(
    passwordLogin(failed.ctx, { system: "ehall" }, "undergraduate"),
    /academic_response_invalid/,
  );
  assert.equal(failed.calls.at(-1)[2].outcome, "unknown");
  const disk = passwordHarness({ storageFailure: true });
  await assert.rejects(
    passwordLogin(disk.ctx, { system: "ehall" }, "undergraduate"),
    /account_storage_failed/,
  );
  assert.equal(disk.calls.filter((c) => c[0] === "complete").length, 1);
});
test("SDK14 primary expiry publishes an event and never prompts from ordinary query", async () => {
  const h = passwordHarness();
  h.records.set(
    "ids",
    JSON.stringify({
      version: 1,
      service: "ids",
      cookies: [
        {
          name: "CASTGC",
          value: "EXAMPLE_OLD",
          domain: "ids.xidian.edu.cn",
          path: "/authserver",
          hostOnly: true,
        },
      ],
      data: {},
    }),
  );
  h.ctx.fetch = async (url) => response(url, "<form id='pwdFromId'></form>");
  await assert.rejects(
    recoverAcademicSession(h.ctx, "undergraduate", "ehall"),
    (e) => e.code === "authentication_required",
  );
  assert.deepEqual(h.calls, [["report", "school", { status: "expired", reason: "primaryExpired" }]]);
  assert.equal(h.events.filter((e) => e[0] === "open").length, 0);
});
test("SDK14 missing IDS never claims primary expiry or prompts from an ordinary query", async () => {
  for (const child of [false, true]) {
    const h = passwordHarness();
    if (child)
      h.records.set(
        "ehall",
        JSON.stringify({
          version: 1,
          service: "ehall",
          data: {},
          cookies: [{ name: "MOD_AUTH_CAS", value: "EXAMPLE_OLD" }],
        }),
      );
    await assert.rejects(
      recoverAcademicSession(h.ctx, "undergraduate", "ehall"),
      (error) => error.code === "authentication_required",
    );
    assert.deepEqual(h.calls, [
      [
        "report",
        "school",
        {
          status: child ? "unknown" : "signedOut",
          reason: child ? "networkUnknown" : "signedOut",
        },
      ],
    ]);
    assert.equal(h.events.length, 0);
  }
});
for (const mobile of [false, true]) {
  test(`actual ${mobile ? "mobile" : "desktop"} DOM submit scopes password inputs and clicks the page handler once`, () => {
    let clicks = 0;
    let visible = true;
    const getClientRects = () => (visible ? [{}] : []);
    const inputs = [
      { value: "", dispatchEvent() {}, getClientRects },
      { value: "", dispatchEvent() {}, getClientRects },
    ];
    let action = "/authserver/login";
    const submit = {
      getClientRects,
      click() {
        clicks++;
      },
    };
    const form = {
      getClientRects,
      getAttribute: () => action,
      querySelector: (selector) =>
        selector === "#username" ? inputs[0] : selector === "#password" ? inputs[1] : submit,
    };
    const context = {
      URL,
      Event: class {},
      location: { href: "https://ids.xidian.edu.cn/authserver/login" },
      document: {
        readyState: "complete",
        querySelector: (selector) => {
          if (selector === "#pwdFromId") return mobile ? null : form;
          if (selector === "#pwdLoginDiv form#loginFromId") return mobile ? form : null;
          // Mobile also has a hidden SMS form with the same input/button ids.
          // Looking up those ids globally must never select or submit that form.
          assert.fail(`unexpected global lookup: ${selector}`);
        },
      },
    };
    const fn = vm.runInNewContext(`(${submitSavedPassword.toString()})`, context);
    assert.equal(fn(null, null, true), "ready");
    assert.equal(clicks, 0);
    assert.equal(inputs[0].value, "");
    assert.equal(fn("EXAMPLE_USER", "EXAMPLE_PASSWORD"), "submitted");
    assert.equal(clicks, 1);
    assert.equal(inputs[0].value, "EXAMPLE_USER");
    action = "https://outside.example/login";
    assert.equal(fn("OTHER", "OTHER"), "invalid");
    assert.equal(clicks, 1);
    action = "/authserver/other";
    assert.equal(fn("OTHER", "OTHER"), "invalid");
    assert.equal(clicks, 1);
    action = "/authserver/login";
    visible = false;
    assert.equal(fn("OTHER", "OTHER"), "pending");
    assert.equal(clicks, 1);
    assert.equal(inputs[0].value, "EXAMPLE_USER");
  });
}
test("actual DOM outcome uses visible IDS error evidence, not arbitrary body text", () => {
  let message = "用户名或密码错误",
    shown = true,
    captcha = false;
  const context = {
    URL,
    location: { href: "https://ids.xidian.edu.cn/authserver/login" },
    document: {
      body: { textContent: "账号已禁用" },
      querySelectorAll: (selector) =>
        selector.startsWith("#msg")
          ? [
              {
                getClientRects: () => (shown ? [{}] : []),
                get textContent() {
                  return message;
                },
              },
            ]
          : captcha
            ? [{ getClientRects: () => [{}] }]
            : [],
    },
  };
  const fn = vm.runInNewContext(`(${inspectPasswordOutcome.toString()})`, context);
  assert.equal(fn(), "credentialsRejected");
  message = "未知错误";
  assert.equal(fn(), null);
  message = "账号已禁用";
  assert.equal(fn(), "accountDisabled");
  shown = false;
  assert.equal(fn(), null);
  captcha = true;
  assert.equal(fn(), "interactionRequired");
  context.location.href = "https://outside.example/login";
  assert.equal(fn(), null);
});
