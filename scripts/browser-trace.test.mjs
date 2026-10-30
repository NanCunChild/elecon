// Copyright 2026 elecon contributors. SPDX-License-Identifier: MIT
// Synthetic credentials only. The integration test never contacts a school.
import assert from "node:assert/strict";
import { existsSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { safeUrl, startBrowserTrace, TraceRedactor } from "./browser-trace.mjs";

test("nested services keep routing evidence without credentials, query values, fragments or matrix sessions", () => {
  const inner =
    "https://ehall.example.edu/login;jsessionid=SYNTHETIC_PATH_SECRET?service=" +
    encodeURIComponent("http://ehall.example.edu/appShow?appId=SYNTHETIC_APP");
  const url =
    "https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@ids.example.edu/authserver/login?service=" +
    encodeURIComponent(inner) +
    "&ticket=ST-SYNTHETIC_TICKET#SYNTHETIC_FRAGMENT";
  const result = safeUrl(url);
  assert.equal(result.origin, "https://ids.example.edu");
  assert.equal(result.path, "/authserver/login");
  assert.deepEqual(result.queryKeys, ["service", "ticket"]);
  assert.equal(result.service.path, "/login;[redacted]");
  assert.equal(result.service.service.origin, "http://ehall.example.edu");
  assert.equal(result.service.service.path, "/appShow");
  assert.equal(result.hasFragment, true);
  assert.ok(!JSON.stringify(result).includes("SYNTHETIC"));
  assert.deepEqual(safeUrl("/authserver/login?ticket=SYNTHETIC", "https://ids.example.edu"), {
    origin: "https://ids.example.edu",
    path: "/authserver/login",
    queryKeys: ["ticket"],
    hasFragment: false,
  });
  assert.equal(safeUrl("https://ids.example.edu/authserver/ST-short").path, "/authserver/[redacted]");
});

test("cookie identities correlate rotation and sends but differ between runs; arbitrary headers stay out", () => {
  const a = new TraceRedactor(),
    b = new TraceRedactor();
  const value = "EXAMPLE_SYNTHETIC_COOKIE_SECRET";
  const first = a.cookie({
    name: "CASTGC",
    value,
    domain: "ids.example.edu",
    path: "/authserver",
    httpOnly: true,
  });
  const header = a.headers({
    Cookie: "CASTGC=" + value,
    "Set-Cookie": "CASTGC=" + value + "; Path=/authserver; Secure; HttpOnly; SameSite=Lax",
    Authorization: "Bearer EXAMPLE_SYNTHETIC_AUTHORIZATION",
    "X-CSRF-Token": "EXAMPLE_SYNTHETIC_CSRF",
    Location: "https://ehall.example.edu/callback?ticket=EXAMPLE_SYNTHETIC_TICKET",
  });
  assert.equal(first.valueId, header.cookies[0].valueId);
  assert.equal(first.valueId, header.setCookies[0].valueId);
  assert.equal(header.setCookies[0].httpOnly, true);
  assert.equal(header.setCookies[0].secure, true);
  assert.equal(header.setCookies[0].sameSite, "Lax");
  assert.notEqual(first.valueId, b.id(value));
  assert.notEqual(first.valueId, a.id("EXAMPLE_SYNTHETIC_ROTATED"));
  assert.equal(header.authorizationPresent, true);
  const callback = a.url("https://ehall.example.edu/callback?ticket=EXAMPLE_SYNTHETIC_TICKET");
  assert.equal(header.location.query[0].valueId, callback.query[0].valueId);
  assert.notEqual(header.location.query[0].valueId, b.id("EXAMPLE_SYNTHETIC_TICKET"));
  assert.equal(a.url("/callback?ticket=EXAMPLE_SYNTHETIC_TICKET").relative, true);
  assert.ok(!JSON.stringify(header).includes("EXAMPLE_SYNTHETIC"));
});

async function until(predicate) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await delay(100);
  }
  assert.fail("timed out waiting for browser trace evidence");
}

const chromeAvailable =
  typeof WebSocket !== "undefined" &&
  [
    process.env.CHROME_BIN,
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/opt/google/chrome/chrome",
  ].some((p) => p && existsSync(p));
test("real Chrome records redirects, HttpOnly cookies, rejected cookies and IDS revisit without raw secrets", {
  skip: !chromeAvailable,
  timeout: 30000,
}, async (t) => {
  const secrets = [
    "EXAMPLE_SYNTHETIC_BUSINESS_SECRET",
    "EXAMPLE_SYNTHETIC_GLOBAL_SECRET",
    "EXAMPLE_SYNTHETIC_PATH_SECRET",
    "ST-EXAMPLE_SYNTHETIC_TICKET",
    "EXAMPLE_SYNTHETIC_PASSWORD",
    "EXAMPLE_SYNTHETIC_CODE",
    "EXAMPLE_SYNTHETIC_RESPONSE",
    "EXAMPLE_SYNTHETIC_REJECTED_COOKIE",
  ];
  let posted = false;
  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/start") {
      response.writeHead(302, {
        Location:
          "/login;jsessionid=" +
          secrets[2] +
          "?service=" +
          encodeURIComponent("http://127.0.0.1/appShow?appId=EXAMPLE_SYNTHETIC_APP"),
        "Set-Cookie": "EHALL_SYNTH=" + secrets[0] + "; Path=/; HttpOnly; SameSite=Lax",
      });
    } else if (url.pathname.startsWith("/login;")) {
      response.writeHead(302, {
        Location: "/landing?ticket=" + secrets[3],
        "Set-Cookie": [
          "CASTGC=" + secrets[1] + "; Path=/authserver; HttpOnly; SameSite=Lax",
          "REJECTED=" + secrets[7] + "; Domain=elsewhere.invalid; Path=/",
        ],
      });
    } else if (url.pathname === "/landing") {
      response.setHeader("Content-Type", "text/html; charset=utf-8");
      response.end(
        `<p>参数错误</p><input type="password" value="${secrets[4]}"><script>fetch('/api',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'password=${secrets[4]}&code=${secrets[5]}'})</script>`,
      );
      return;
    } else if (url.pathname === "/api") {
      posted = request.method === "POST";
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify({ private: secrets[6] }));
      return;
    } else if (url.pathname === "/authserver") {
      response.setHeader("Content-Type", "text/html; charset=utf-8");
      response.end('<h1>账号设置</h1><a href="/authserver/logout">退出</a>');
      return;
    }
    response.end();
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  t.after(() => new Promise((r) => server.close(r)));
  const trace = await startBrowserTrace({ headless: true, hosts: ["127.0.0.1"] });
  t.after(async () => {
    await trace.stop();
    rmSync(trace.directory, { recursive: true, force: true });
  });
  const records = () =>
    readFileSync(trace.logPath, "utf8")
      .trim()
      .split("\n")
      .map((s) => JSON.parse(s));
  await until(() => records().some((r) => r.event === "tab_attached"));
  const [sessionId] = trace.pages.keys();
  const origin = `http://127.0.0.1:${server.address().port}`;
  await trace.cdp.send("Page.navigate", { url: origin + "/start" }, sessionId);
  await until(() => records().some((r) => r.event === "page_state" && r.state.parameterError));
  assert.equal(posted, true);
  await trace.cdp.send("Page.navigate", { url: origin + "/authserver" }, sessionId);
  await until(() =>
    records().some((r) => r.event === "page_state" && r.state.settings && r.state.logoutLink),
  );
  await trace.snapshot();
  const events = records();
  assert.equal(events.filter((r) => r.event === "redirect").length, 2);
  assert.ok(events.some((r) => r.event === "request" && r.method === "POST" && r.hasPostData));
  assert.ok(
    events.some(
      (r) =>
        r.event === "response_cookies" &&
        r.blocked.some((b) => b.cookie.name === "REJECTED" && b.blockedReasons.length),
    ),
  );
  const snapshots = events.filter((r) => r.event === "cookie_snapshot");
  assert.deepEqual(snapshots[0].cookies, []);
  const globalCookie = snapshots.flatMap((r) => r.cookies).find((c) => c.name === "CASTGC");
  assert.equal(globalCookie.httpOnly, true);
  assert.equal(globalCookie.path, "/authserver");
  assert.ok(
    events.some(
      (r) =>
        r.event === "request_cookies" &&
        r.headers.cookies?.some((c) => c.name === "CASTGC" && c.valueId === globalCookie.valueId),
    ),
  );
  const contents =
    readFileSync(trace.logPath, "utf8") + readFileSync(join(trace.directory, "cookies.latest.json"), "utf8");
  for (const secret of secrets)
    assert.ok(!contents.includes(secret), "raw synthetic credential entered trace");
  assert.equal(statSync(trace.directory).mode & 0o777, 0o700);
  assert.equal(statSync(trace.logPath).mode & 0o777, 0o600);
});
