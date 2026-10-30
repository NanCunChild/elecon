// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Synthetic WebView snapshots and CAS/API responses; never school traffic.
import assert from "node:assert/strict";

export function harness({ system = "ehall", cancel = false, badProbe = false, idsReady = true } = {}) {
  let clock = 1000;
  const events = [];
  const records = new Map();
  const origin = system === "yjspt" ? "https://yjspt.xidian.edu.cn" : "https://ehall.xidian.edu.cn";
  const service = system === "yjspt" ? `${origin}/` : `${origin}/appShow?appId=4770397878132218`;
  const ctx = {
    now: () => clock,
    log: (_, message) => events.push(["log", message]),
    credentials: {
      async get(key, options) {
        assert.equal(options.namespace, "xidian.auth");
        return records.has(key) ? { value: records.get(key) } : null;
      },
      async set(key, value, options) {
        assert.equal(options.namespace, "xidian.auth");
        records.set(key, value);
        events.push(["save", key]);
      },
    },
    browser: {
      async open(url) {
        assert.equal(url, "https://ids.xidian.edu.cn/authserver/login");
        events.push(["open", url]);
        if (cancel) throw new Error("script_cancelled");
      },
      async setCookies(url) {
        assert.equal(new URL(url).host, "ids.xidian.edu.cn");
        events.push(["restore", url]);
      },
      async evaluate(fn, stage) {
        assert.equal(fn.name, "inspectLoginPage");
        assert.equal(stage, "ids");
        clock += 1000;
        events.push(["inspect", stage]);
        return {
          ready: idsReady,
          page: "https://ids.xidian.edu.cn/personalInfo/personalMobile/index.html",
        };
      },
      async cookies(url) {
        events.push(["cookies", url]);
        return [
          {
            name: "CASTGC",
            value: "EXAMPLE_SYNTHETIC_GLOBAL",
            path: "/authserver",
            isSecure: true,
            isHttpOnly: true,
          },
        ];
      },
    },
    async fetch(url, init) {
      const parsed = new URL(url);
      events.push(["request", url, init]);
      assert.equal(init.redirect, "manual");
      if (parsed.host === "ids.xidian.edu.cn") {
        assert.equal(parsed.pathname, "/authserver/login");
        assert.equal(init.method, "GET");
        assert.equal(parsed.searchParams.get("service"), service);
        assert.match(init.headers.Cookie, /CASTGC=EXAMPLE_SYNTHETIC_GLOBAL/);
        assert.ok(records.has("ids"), "SSO must be saved before the service exchange");
        return response(url, "", {
          status: 302,
          location: `${service}${service.includes("?") ? "&" : "?"}ticket=EXAMPLE_SYNTHETIC_TICKET`,
          cookies: ["CASTGC=EXAMPLE_SYNTHETIC_ROTATED; Path=/authserver; Secure; HttpOnly"],
        });
      }
      assert.equal(parsed.origin, origin);
      if (init.method === "POST") {
        return response(
          url,
          badProbe
            ? { code: "1", datas: {} }
            : {
                code: "0",
                data: { xnxqdm: "2026-2027-1" },
                datas: { dqxnxq: { rows: [{ DM: "2026-2027-1" }], extParams: { code: 1 } } },
              },
        );
      }
      // HTML bootstrap fails even with a valid session; the native read-only
      // endpoint remains usable. This HTML must never open in the WebView.
      return response(url, "<html>系统异常 / 调用接口异常 / 正在紧急修复</html>", {
        cookies: ["MOD_AUTH_CAS=EXAMPLE_SYNTHETIC_BUSINESS; Path=/; Secure; HttpOnly"],
      });
    },
  };
  return { ctx, records, events, origin, service };
}

export function response(url, body, { status = 200, location, cookies = [] } = {}) {
  return {
    url,
    status,
    ok: status >= 200 && status < 300,
    headers: {
      get: (key) => (key.toLowerCase() === "location" ? location : null),
      getSetCookie: () => cookies,
    },
    json: async () => (typeof body === "string" ? JSON.parse(body) : body),
    text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
  };
}
