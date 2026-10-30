// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
import assert from "node:assert/strict";
import { createCipheriv } from "node:crypto";
import test from "node:test";
import { encryptPda } from "../src/pda_ui.js";
import { FORM, harness, passwordFields, pdaLogin } from "./pda.fixture.mjs";

for (const salt of ["0123456789abcdef", "0123456789abcdef01234567", "0123456789abcdef0123456789abcdef"])
  test(`password AES matches independent CBC oracle (${salt.length * 8} bit)`, async () => {
    const text = "EXAMPLE_SYNTHETIC_密码";
    const actual = await encryptPda({ text, salt });
    const cipher = createCipheriv(
      `aes-${salt.length * 8}-cbc`,
      Buffer.from(salt),
      Buffer.from("xidianscriptsxdu"),
    );
    assert.equal(
      actual,
      Buffer.concat([cipher.update("xidianscriptsxdu".repeat(4) + text), cipher.final()]).toString("base64"),
    );
  });
test("reject missing/duplicated form fields and retain empty lt", () => {
  assert.equal(passwordFields(FORM).lt, "");
  assert.throws(() => passwordFields(FORM.replace('name="lt"', 'name="other"')), /form_invalid/);
  assert.throws(
    () =>
      passwordFields(FORM.replace("</form>", '<input type="hidden" name="execution" value="bad"></form>')),
    /form_invalid/,
  );
});
for (const options of [{}, { mfa: true }, { continueForm: true }, { serviceMfa: true }, { system: "yjspt" }])
  test(`native password/captcha/SSO flow ${JSON.stringify(options)}`, async () => {
    const h = harness(options);
    const result = await pdaLogin(
      h.ctx,
      { system: options.system || "ehall" },
      options.system === "yjspt" ? "postgraduate" : "undergraduate",
    );
    assert.ok(h.records.has("ids"));
    assert.ok(h.records.has(options.system || "ehall"));
    assert.equal(JSON.parse(h.records.get("ids")).data.authFlow, "pda");
    const allSaved = [...h.records.values()].join();
    assert.ok(!allSaved.includes("EXAMPLE_SYNTHETIC_PASSWORD"));
    assert.ok(!allSaved.includes("EXAMPLE_SYNTHETIC_CODE"));
    assert.ok(!JSON.stringify(result).includes("SYNTHETIC"));
    assert.ok(!JSON.stringify(h.events.filter((e) => e[0] === "log")).includes("SYNTHETIC"));
    const firstSave = h.events.findIndex((e) => e[0] === "save" && e[1] === "ids");
    const service = h.events.findIndex((e) => e[0] === "request" && e[1].includes("?service="));
    assert.ok(firstSave < service);
    if (options.mfa || options.serviceMfa) {
      const submits = h.events.findIndex((e) => e[0] === "request" && e[1].includes("reAuthSubmit"));
      assert.ok(
        h.events
          .slice(submits + 1)
          .some((e) => e[0] === "request" && new URL(e[1]).pathname === "/authserver/login"),
      );
    }
  });
test("verified cached global session needs no browser", async () => {
  const h = harness({ cached: true });
  delete h.ctx.browser;
  await pdaLogin(h.ctx, { system: "ehall" }, "undergraduate");
  assert.ok(!h.events.some((e) => e[0] === "input"));
});
for (const options of [
  { badProbe: true },
  { redirect: "https://evil.invalid/steal?ticket=SYNTHETIC" },
  { redirect: "http://ehall.xidian.edu.cn:80/fail" },
])
  test(`save global IDS independently on target failure ${JSON.stringify(options)}`, async () => {
    const h = harness(options);
    await assert.rejects(pdaLogin(h.ctx, { system: "ehall" }, "undergraduate"));
    assert.ok(h.records.has("ids"));
    assert.ok(!h.records.has("ehall"));
    assert.ok(!h.events.some((e) => e[0] === "request" && e[1].includes("evil.invalid")));
  });
for (const options of [
  { wrongPassword: true },
  { cancel: true },
  { captchaReject: true },
  { neverInput: true },
])
  test(`incomplete auth never saves a session ${JSON.stringify(options)}`, async () => {
    const h = harness(options);
    await assert.rejects(pdaLogin(h.ctx, { system: "ehall" }, "undergraduate"));
    assert.ok(!h.records.has("ids"));
    assert.ok(!h.records.has("ehall"));
    assert.equal(h.records.size, 0);
    assert.equal(h.events.at(-1)[0], "clear");
  });

test("enterprise WeChat MFA uses its own delivery type and the same stable device fingerprint", async () => {
  const h = harness({ mfa: true, wechat: true });
  await pdaLogin(h.ctx, { system: "ehall" }, "undergraduate");
  const registrations = h.events
    .filter((e) => e[0] === "request" && e[1].includes("/bfp/info"))
    .map((e) => new URL(e[1]).searchParams.get("bfp"));
  assert.equal(registrations.length, 2);
  assert.equal(registrations[0], JSON.parse(h.records.get("ids")).data.browserFingerprint);
  assert.equal(registrations[1], registrations[0]);
});
test("an IDS rotation during service signing survives a later maintenance response", async () => {
  const h = harness({ rotateIds: true, badProbe: true });
  await assert.rejects(pdaLogin(h.ctx, { system: "ehall" }, "undergraduate"));
  const saved = JSON.parse(h.records.get("ids"));
  assert.equal(saved.cookies.find((c) => c.name === "CASTGC").value, "EXAMPLE_SYNTHETIC_ROTATED");
  assert.ok(!h.records.has("ehall"));
});

test("native service exchange does not reuse legacy WebView business cookies", async () => {
  const h = harness();
  h.records.set(
    "ehall",
    JSON.stringify({
      version: 1,
      service: "ehall",
      data: { origin: "http://ehall.xidian.edu.cn" },
      cookies: [
        {
          name: "MOD_AUTH_CAS",
          value: "EXAMPLE_SYNTHETIC_LEGACY",
          domain: "ehall.xidian.edu.cn",
          hostOnly: true,
          path: "/",
        },
      ],
    }),
  );
  const delegate = h.ctx.fetch;
  h.ctx.fetch = async (url, init) => {
    assert.ok(!(init.headers.Cookie || "").includes("EXAMPLE_SYNTHETIC_LEGACY"));
    return delegate(url, init);
  };
  await pdaLogin(h.ctx, { system: "ehall" }, "undergraduate");
  assert.equal(JSON.parse(h.records.get("ehall")).data.authFlow, "pda");
});
