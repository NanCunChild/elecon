import assert from "node:assert/strict";
import test from "node:test";
import { profileRequestUrl } from "../src/profile_request.js";

test("profile query signatures match independent fixed protocol vectors", () => {
  for (const [nonce, expected] of [
    ["00000000000000000000000000000000", "dbba77999d61df93f41efe71daba9202"],
    ["0123456789ab4def8123456789abcdef", "624013f76485006c4e1995ceb1aaa6d1"],
  ]) {
    const url = new URL(profileRequestUrl(1800000000000, nonce));
    assert.equal(url.origin, "https://useryd.chaoxing.com");
    assert.equal(url.pathname, "/apis/user/getUsers4C");
    assert.equal(url.searchParams.get("inf_enc"), expected);
    assert.deepEqual([...url.searchParams.keys()], ["_c_0_", "token", "_time", "inf_enc"]);
  }
});

test("profile nonce is transient and contains neither account nor device input", () => {
  const first = new URL(profileRequestUrl(1800000000000));
  const second = new URL(profileRequestUrl(1800000000000));
  assert.match(first.searchParams.get("_c_0_"), /^[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}$/);
  assert.notEqual(first.searchParams.get("_c_0_"), second.searchParams.get("_c_0_"));
  for (const [time, nonce] of [
    [-1, "0".repeat(32)],
    [1.5, "0".repeat(32)],
    [0, "invalid&uid=value"],
  ])
    assert.throws(() => profileRequestUrl(time, nonce));
});
