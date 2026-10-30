// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Synthetic protocol only; OpenSSL-backed Node AES is the independent oracle.
import assert from "node:assert/strict";
import { createDecipheriv, webcrypto } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { IDS_LOGIN, PDA_TARGETS, PDA_UA } from "../src/pda_constants.js";
import { encryptPda } from "../src/pda_ui.js";

globalThis.crypto ??= webcrypto;

const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/pda_login.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const directory = mkdtempSync(join(tmpdir(), "elecon-pda-fixture-"));
export let pdaLogin, passwordFields;
try {
  const path = join(directory, "module.mjs");
  writeFileSync(path, compiled.outputFiles[0].text);
  ({ pdaLogin, passwordFields } = await import(path));
} finally {
  rmSync(directory, { recursive: true, force: true });
}
export const FORM =
  '<form id="pwdFromId"><input type="hidden" id="pwdEncryptSalt" value="0123456789abcdef"><input type="hidden" name="lt" value=""><input type="hidden" name="execution" value="EXAMPLE_SYNTHETIC_EXECUTION"></form>';
const puzzle = {
  bigImage: Buffer.alloc(48, 7).toString("base64"),
  smallImage: Buffer.from("EXAMPLE_SYNTHETIC_IMAGE0123456789abcdef").toString("base64"),
};
const tracks = [
  { a: 0, b: 0, c: 0 },
  { a: 120, b: 1, c: 500 },
];
const cookie = "CASTGC=EXAMPLE_SYNTHETIC_GLOBAL; Path=/authserver; Secure; HttpOnly";
export function harness({
  system = "ehall",
  cached = false,
  mfa = false,
  serviceMfa = false,
  continueForm = false,
  badProbe = false,
  redirect,
  wrongPassword = false,
  cancel = false,
  captchaReject = false,
  neverInput = false,
  rotateIds = false,
  wechat = false,
} = {}) {
  const events = [],
    records = new Map();
  let clock = 0,
    step,
    globalSigned = false,
    mfaDone = false;
  if (cached)
    records.set(
      "ids",
      JSON.stringify({
        version: 1,
        service: "ids",
        data: { studentId: "EXAMPLE_SYNTHETIC_ACCOUNT" },
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
  const target = PDA_TARGETS[system];
  const reply = (url, body = "", status = 200, location, lines = []) => ({
    url,
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (n) => (n.toLowerCase() === "location" ? location : null), getSetCookie: () => lines },
    text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
    json: async () => (typeof body === "string" ? JSON.parse(body) : body),
  });
  const ctx = {
    now: () => clock,
    log: (_level, message) => events.push(["log", message]),
    credentials: {
      get: async (key) => (records.has(key) ? { value: records.get(key) } : null),
      set: async (key, value) => {
        records.set(key, value);
        events.push(["save", key]);
      },
    },
    browser: {
      open: async (url) => {
        assert.equal(url, IDS_LOGIN);
        events.push(["open"]);
      },
      evaluate: async (fn, options) => {
        if (fn.name === "preparePdaInput") return "0123456789ABCDEF0123456789ABCDEF";
        if (fn.name === "renderPdaInput") {
          step = options.kind;
          events.push(["input", step]);
          return true;
        }
        if (fn.name === "pollPdaInput") {
          clock += 700;
          if (neverInput) return null;
          if (cancel) return { cancelled: true };
          return structuredClone(
            {
              credentials: { username: "EXAMPLE_SYNTHETIC_ACCOUNT", password: "EXAMPLE_SYNTHETIC_PASSWORD" },
              captcha: { tracks },
              method: { type: wechat ? "4" : "3" },
              code: { code: "EXAMPLE_SYNTHETIC_CODE", trustDevice: true },
            }[step],
          );
        }
        if (fn.name === "encryptPda") return encryptPda(options);
        if (fn.name === "clearPdaInput") {
          events.push(["clear"]);
          return true;
        }
        throw new Error("unexpected_browser_function");
      },
    },
    fetch: async (url, init) => {
      events.push(["request", url, init]);
      assert.equal(init.headers["User-Agent"], PDA_UA);
      assert.equal(init.redirect, "manual");
      const u = new URL(url),
        fields = new URLSearchParams(init.body);
      if (u.pathname === "/authserver/login") {
        if (fields.has("username")) {
          assert.equal(fields.get("username"), "EXAMPLE_SYNTHETIC_ACCOUNT");
          assert.equal(fields.get("lt"), "");
          assert.equal(fields.get("execution"), "EXAMPLE_SYNTHETIC_EXECUTION");
          for (const [k, v] of Object.entries({
            rememberMe: "true",
            cllt: "userNameLogin",
            dllt: "generalLogin",
            _eventId: "submit",
          }))
            assert.equal(fields.get(k), v);
          const decipher = createDecipheriv(
            "aes-128-cbc",
            Buffer.from("0123456789abcdef"),
            Buffer.from("xidianscriptsxdu"),
          );
          const plain = Buffer.concat([
            decipher.update(Buffer.from(fields.get("password"), "base64")),
            decipher.final(),
          ]).toString();
          assert.equal(plain, "xidianscriptsxdu".repeat(4) + "EXAMPLE_SYNTHETIC_PASSWORD");
          if (wrongPassword) return reply(url, "", 401);
          if (continueForm)
            return reply(
              url,
              '<form id="continue"><input name="EXAMPLE_SYNTHETIC_CONTINUE" value="yes"></form>',
            );
          globalSigned = true;
        }
        if (fields.has("EXAMPLE_SYNTHETIC_CONTINUE")) globalSigned = true;
        if (u.searchParams.has("service")) {
          assert.equal(u.searchParams.get("service"), target.service);
          assert.match(init.headers.Cookie, /CASTGC=EXAMPLE_SYNTHETIC_GLOBAL/);
          if (serviceMfa && !mfaDone)
            return reply(url, "", 302, "/authserver/reAuthCheck/reAuthLoginView.do?isMultifactor=true");
          return reply(
            url,
            "",
            302,
            redirect || target.service,
            rotateIds ? ["CASTGC=EXAMPLE_SYNTHETIC_ROTATED; Path=/authserver; Secure; HttpOnly"] : [],
          );
        }
        if (cached || globalSigned) {
          if (mfa && !mfaDone)
            return reply(url, "", 302, "/authserver/reAuthCheck/reAuthLoginView.do?isMultifactor=true");
          return reply(url, "", 302, "http://ids.xidian.edu.cn/authserver/index.do", [cookie]);
        }
        return reply(url, FORM, 200, undefined, [
          "JSESSIONID=EXAMPLE_SYNTHETIC_PRE; Path=/authserver; Secure",
        ]);
      }
      if (u.pathname.endsWith("/bfp/info")) return reply(url, "ok");
      if (u.pathname.endsWith("/openSliderCaptcha.htl")) {
        assert.match(init.headers.Cookie, /JSESSIONID=EXAMPLE_SYNTHETIC_PRE/);
        return reply(url, puzzle);
      }
      if (u.pathname.endsWith("/verifySliderCaptcha.htl")) {
        assert.equal(init.headers.Origin, "https://ids.xidian.edu.cn");
        assert.equal(init.headers["X-Requested-With"], "XMLHttpRequest");
        // The random prefix/IV are both alphabet bytes; the plaintext tail is
        // unaffected by the CBC IV. Decode all but the first block independently.
        const decipher = createDecipheriv("aes-128-cbc", Buffer.from("0123456789abcdef"), Buffer.alloc(16));
        const plain = Buffer.concat([
          decipher.update(Buffer.from(fields.get("sign"), "base64")),
          decipher.final(),
        ])
          .subarray(64)
          .toString();
        assert.deepEqual(JSON.parse(plain), { canvasLength: 280, moveLength: 120, tracks });
        return reply(url, { errorCode: captchaReject ? 0 : 1 });
      }
      if (u.pathname.endsWith("/reAuthLoginView.do"))
        return reply(url, '{"reAuthUserId":"EXAMPLE_SYNTHETIC_DELIVERY"}');
      if (u.pathname.endsWith("/changeReAuthType.do")) {
        assert.equal(fields.get("reAuthType"), wechat ? "4" : "3");
        return reply(url, { code: "1" });
      }
      if (u.pathname.endsWith("/getDynamicCodeByReauth.do")) {
        assert.equal(fields.get("userName"), "EXAMPLE_SYNTHETIC_DELIVERY");
        assert.equal(
          fields.get("authCodeTypeName"),
          wechat ? "reAuthWChatDynamicCodeType" : "reAuthDynamicCodeType",
        );
        return reply(url, { res: "code_time_fail" });
      }
      if (u.pathname.endsWith("/reAuthSubmit.do")) {
        assert.equal(fields.get("dynamicCode"), "EXAMPLE_SYNTHETIC_CODE");
        assert.equal(fields.get("service"), serviceMfa ? target.service : "");
        mfaDone = true;
        return reply(url, { code: "reAuth_success" });
      }
      if (url === target.probe) {
        assert.match(init.headers.Cookie, /MOD_AUTH_CAS=EXAMPLE_SYNTHETIC_BUSINESS/);
        return reply(
          url,
          badProbe
            ? "<html>正在紧急修复</html>"
            : {
                code: "0",
                datas: { dqxnxq: { rows: [{ DM: "2026-2027-1" }] } },
                data: { xnxqdm: "2026-2027-1" },
              },
        );
      }
      if (u.origin === target.origin)
        return reply(url, "application", 200, undefined, [
          "MOD_AUTH_CAS=EXAMPLE_SYNTHETIC_BUSINESS; Path=/; Secure; HttpOnly",
        ]);
      throw new Error("unexpected_fixture_request");
    },
  };
  return { ctx, events, records };
}
