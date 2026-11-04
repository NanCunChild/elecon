import assert from "node:assert/strict";
import test from "node:test";
import { createProfile } from "../src/profile.js";
import { harness } from "./webview.fixture.mjs";

test("profile name comes only from school session display metadata, never login username", async () => {
  for (const role of ["undergraduate", "postgraduate"]) {
    const h = harness();
    assert.deepEqual(await createProfile(role)(h.ctx), {});
    h.records.set(
      "ids",
      JSON.stringify({ version: 1, service: "ids", cookies: [], data: { studentId: "SYNTHETIC" } }),
    );
    assert.deepEqual(await createProfile(role)(h.ctx), {});
    h.records.set(
      "ids",
      JSON.stringify({ version: 1, service: "ids", cookies: [], data: { accountLabel: "合成同学" } }),
    );
    assert.deepEqual(await createProfile(role)(h.ctx), { name: "合成同学" });
    assert.equal(h.events.length, 0, "profile metadata read must not trigger network or login");
    await assert.rejects(createProfile(role)(h.ctx, { role: "other" }), /input_invalid_request/);
  }
});
