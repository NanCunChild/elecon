// Synthetic service only. No school or forum traffic.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { build } from "esbuild";
import { md5 } from "../src/md5.js";

const built = await build({
  entryPoints: [new URL("../src/ruisi.js", import.meta.url).pathname],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: { "elecon:html": new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url).pathname },
});
const { forumSession, ruisiAccount } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);
const own =
  '<div id="um"><strong class="vwmy"><a href="home.php?mod=space&uid=112233">Synthetic user</a></strong><a href="member.php?action=logout">退出</a></div>';
const form =
  '<form id="loginform_TEST" action="member.php?loginhash=TEST"><input name="formhash" value="FORMHASH"></form>';
function harness({ captcha = false, cancel = false, rejected = false, invalid = false } = {}) {
  const records = new Map();
  const calls = [];
  let clock = 0;
  let loggedIn = false;
  const ctx = {
    now: () => clock++,
    credentials: {
      get: async (k, o) => {
        assert.equal(o.namespace, "xidian.services");
        return records.has(k) ? { value: records.get(k) } : null;
      },
      set: async (k, v, o) => {
        assert.equal(o.namespace, "xidian.services");
        records.set(k, v);
      },
      delete: async (k) => records.delete(k),
    },
    ui: {
      requestInput: async () => (cancel ? null : { username: "SYNTHETIC", password: "SYNTHETIC_PASSWORD" }),
    },
    browser: {
      setCookies: async () => {},
      open: async () => {
        calls.push(["browser"]);
        loggedIn = true;
      },
      evaluate: async () => own,
      cookies: async () => [
        { name: "RS_SESSION", value: "SYNTHETIC_BROWSER_COOKIE", path: "/", isSecure: true },
      ],
    },
    fetch: async (url, init) => {
      calls.push([url, init]);
      let body;
      if (init.method === "POST") {
        assert.equal(new URLSearchParams(init.body).get("password"), md5("SYNTHETIC_PASSWORD"));
        loggedIn = !rejected;
        body = loggedIn ? "欢迎您回来" : "登录失败";
      } else if (url.includes("mod=space"))
        body = invalid ? "请先登录后才能继续浏览" : loggedIn ? own : "请先登录后才能继续浏览";
      else body = captcha ? form + '<script>updateseccode("synthetic")</script>' : form;
      return {
        ok: true,
        status: 200,
        url,
        headers: {
          get: () => null,
          getSetCookie: () => ["RS_SESSION=SYNTHETIC_COOKIE; Path=/; Secure; HttpOnly"],
        },
        text: async () => body,
      };
    },
  };
  return { ctx, calls, records };
}
test("MD5 matches independent vectors including Unicode and block boundaries", () => {
  for (const s of ["", "abc", "瑞思密码", "x".repeat(64), "y".repeat(1000)])
    assert.equal(md5(s), createHash("md5").update(s).digest("hex"));
});
test("account evidence excludes arbitrary uid links and logged-out pages", () => {
  assert.equal(ruisiAccount('<a href="home.php?mod=space&uid=334455">friend</a>'), null);
  assert.equal(ruisiAccount(own).id, "112233");
});
test("form login verifies own account, stores only cookies, and local logout is scoped", async () => {
  const h = harness();
  h.records.set("unrelated", "OTHER");
  assert.equal((await forumSession(h.ctx)).status, "signedOut");
  assert.equal(h.calls.length, 0);
  const result = await forumSession(h.ctx, { operation: "login" });
  assert.equal(result.accountId, "112233");
  assert.ok(!h.records.get("xidian.ruisi").includes("SYNTHETIC_PASSWORD"));
  assert.equal((await forumSession(h.ctx)).status, "authenticated");
  assert.equal((await forumSession(h.ctx, { operation: "logout" })).status, "signedOut");
  assert.equal(h.records.get("unrelated"), "OTHER");
});
test("CAPTCHA switches to visible original page without password protocol attempts", async () => {
  const h = harness({ captcha: true });
  const result = await forumSession(h.ctx, { operation: "login" });
  assert.equal(result.status, "authenticated");
  assert.equal(h.calls.filter((c) => c[0] === "browser").length, 1);
  assert.ok(!h.calls.some((c) => c[1]?.method === "POST"));
});
test("CAPTCHA login waits through an asynchronous page navigation", async () => {
  const h = harness({ captcha: true });
  h.records.set("school-session", "SYNTHETIC_SCHOOL");
  let navigating = true;
  const finished = setTimeout(() => {
    navigating = false;
  }, 50);
  h.ctx.browser.evaluate = async () => {
    if (navigating) throw new Error("browser_navigation_changed");
    return own;
  };
  try {
    assert.equal((await forumSession(h.ctx, { operation: "login" })).status, "authenticated");
    assert.equal(h.records.get("school-session"), "SYNTHETIC_SCHOOL");
  } finally {
    clearTimeout(finished);
  }
});
for (const [name, options] of [
  ["cancel", { cancel: true }],
  ["rejected", { rejected: true }],
  ["unverified uid", { invalid: true }],
])
  test(`login ${name} never saves account`, async () => {
    const h = harness(options);
    await assert.rejects(forumSession(h.ctx, { operation: "login" }));
    assert.equal(h.records.size, 0);
    assert.ok(h.calls.filter((c) => c[1]?.method === "POST").length <= 1);
  });
test("closed input schema rejects extra credentials and operations before traffic", async () => {
  const h = harness();
  for (const p of [{ password: "SECRET" }, { operation: "switch" }])
    await assert.rejects(forumSession(h.ctx, p));
  assert.equal(h.calls.length, 0);
});
