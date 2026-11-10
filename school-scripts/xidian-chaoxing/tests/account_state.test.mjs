import assert from "node:assert/strict";
import test from "node:test";
import { ACCOUNT_URL, accountSession, messagesSession } from "../src/account.js";

function fixture() {
  const records = new Map();
  let answer = {
    msg: { puid: "123", uid: "234", fid: "345", name: "Synthetic", hxToken: "SYNTHETIC_TOKEN" },
  };
  let fail = false;
  const ctx = {
    now: () => 1800000000000,
    credentials: {
      get: async (k) => (records.has(k) ? { value: records.get(k) } : null),
      set: async (k, v) => records.set(k, v),
      delete: async (k) => records.delete(k),
    },
    fetch: async (url) => {
      assert.equal(url, ACCOUNT_URL);
      if (fail) throw new Error("SYNTHETIC_TIMEOUT");
      return {
        ok: true,
        status: 200,
        headers: { getSetCookie: () => [] },
        text: async () => JSON.stringify(answer),
      };
    },
    browser: {
      setCookies: async (_, cookies) => assert.deepEqual(cookies, []),
      open: async () => {},
      evaluate: async () => true,
      cookies: async () => [{ name: "SESSION", value: "SYNTHETIC_NEW", path: "/", isSecure: true }],
    },
  };
  return {
    ctx,
    records,
    fail: () => {
      fail = true;
    },
    answer: (value) => {
      answer = value;
    },
  };
}
const params = { account: "chaoxing", operation: "status" };
test("explicit account transitions discard member and avatar metadata", async () => {
  const h = fixture();
  h.records.set("chat-enrichment", "SYNTHETIC_OLD_AVATAR");
  await accountSession(h.ctx, { ...params, operation: "login" });
  assert.equal(h.records.has("chat-enrichment"), false);
  h.records.set("chat-enrichment", "SYNTHETIC_NEW_AVATAR");
  await messagesSession(h.ctx, { operation: "logout" });
  assert.equal(h.records.has("chat-enrichment"), false);
  assert.equal(h.records.has("chaoxing"), false);
});
test("state distinguishes missing, verified, network-unknown and confirmed expiration", async () => {
  const h = fixture();
  assert.equal((await accountSession(h.ctx, params)).status, "signedOut");
  const signed = await accountSession(h.ctx, { ...params, operation: "login" });
  assert.equal(signed.status, "authenticated");
  assert.equal(signed.accountId, "123");
  assert.equal(JSON.stringify(signed).includes("SYNTHETIC_TOKEN"), false);
  h.answer({ msg: { puid: 0, uid: 0 } });
  assert.equal((await accountSession(h.ctx, params)).status, "expired");
  assert.equal((await accountSession(h.ctx, params)).status, "expired");
  h.answer({
    msg: { puid: "567", uid: "678", fid: "789", name: "Replacement", hxToken: "SYNTHETIC_TOKEN2" },
  });
  assert.equal((await accountSession(h.ctx, { ...params, operation: "login" })).accountId, "567");
  assert.equal(h.records.has("chaoxing-expired"), false);
  const saved = h.records.get("chaoxing");
  h.fail();
  assert.deepEqual(await accountSession(h.ctx, params), { status: "unknown" });
  assert.equal(h.records.get("chaoxing"), saved);
});
test("status never opens a browser and cancellation preserves prior verified credentials", async () => {
  const h = fixture();
  await accountSession(h.ctx, { ...params, operation: "login" });
  const saved = [...h.records];
  h.ctx.browser.open = async () => {
    throw new Error("input_cancelled");
  };
  assert.equal((await accountSession(h.ctx, params)).status, "authenticated");
  await assert.rejects(accountSession(h.ctx, { ...params, operation: "login" }), /input_cancelled/);
  assert.deepEqual([...h.records], saved);
});
