// Public directory data is product content, not a student/contact fixture.
// Invalid cases below are synthetic; this suite performs no network requests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { phoneDirectory } from "../src/phone_directory.js";

const ajv = new Ajv({ strict: true });
addFormats(ajv);
const validate = ajv.compile(
  JSON.parse(
    readFileSync(new URL("../../../contract/schema/directory.phones.schema.json", import.meta.url), "utf8"),
  ),
);
const noHost = new Proxy(
  {},
  {
    get() {
      throw new Error("must stay offline and credential-free");
    },
  },
);

test("packaged directory validates, preserves campus identities and per-entry sources", async () => {
  const result = await phoneDirectory(noHost);
  assert.ok(validate(result), JSON.stringify(validate.errors));
  assert.equal(new Set(result.items.map((i) => i.id)).size, result.items.length);
  assert.ok(result.items.filter((i) => i.category === "常用电话").length === 30);
  assert.ok(result.items.some((i) => new URL(i.sourceUrl).hostname !== "tel.xidian.cc"));
  assert.ok(result.items.some((i) => i.note?.includes("转")));
  assert.ok(!result.items.some((i) => /^1[3-9]\d{9}$/.test(i.phone)), "no personal mobile contacts");
  const report = JSON.parse(
    readFileSync(new URL("../phone-directory-sources.json", import.meta.url), "utf8"),
  );
  for (const source of report.sources) {
    assert.equal(source.entries, result.items.filter((i) => i.category === source.name).length);
    if (source.status === "unverified") assert.ok(source.note);
  }
});

test("output mutation cannot change the next invocation", async () => {
  const original = await phoneDirectory(noHost);
  const modified = await phoneDirectory(noHost);
  modified.items[0].phone = "000";
  modified.items.pop();
  assert.deepEqual(await phoneDirectory(noHost), original);
});

test("directory does not accept arbitrary runtime URLs or operations", async () => {
  for (const params of [null, [], "", { url: "https://example.invalid" }, { operation: "call" }]) {
    await assert.rejects(phoneDirectory(noHost, params), /invalid_params/);
  }
});

test("phone schema refuses URI schemes, USSD, extensions and invalid provenance", async () => {
  const base = {
    items: [
      {
        id: "synthetic",
        name: "合成服务",
        category: "合成部门",
        phone: "+8610000000000",
        sourceUrl: "https://example.invalid/contact",
      },
    ],
    sourceUrl: "https://example.invalid/",
    verifiedDate: "2026-11-04",
  };
  assert.ok(validate(base));
  for (const phone of ["tel:10000", "*123#", "10000;123", "10000,123", "123\n", "12", "1".repeat(16)]) {
    assert.equal(validate({ ...base, items: [{ ...base.items[0], phone }] }), false, phone);
  }
  assert.equal(validate({ ...base, verifiedDate: "2026-02-30" }), false);
  assert.equal(validate({ ...base, items: [{ ...base.items[0], sourceUrl: "javascript:alert(1)" }] }), false);
});
