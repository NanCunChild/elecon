// Synthetic HTTP fixtures only: no real notifications, account or cookies.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { build } from "esbuild";
import { ACCOUNT_URL } from "../src/account.js";

const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/notices.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const { noticeList, NOTICES_URL } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text + "\n//# sourceURL=synthetic-notices.js").toString("base64")}`
);
const ajv = new Ajv2020({ strict: true });
addFormats(ajv);
const validate = ajv.compile(
  JSON.parse(readFileSync(new URL("../../../contract/schema/notice.list.schema.json", import.meta.url))),
);
function harness(data, { status = 200, location = null } = {}) {
  const calls = [];
  let saved = JSON.stringify({
    version: 1,
    serviceId: "chaoxing",
    accountId: "123456",
    accountLabel: "Synthetic",
    cookies: [
      { name: "SESSION", value: "SYNTHETIC_COOKIE", domain: "chaoxing.com", path: "/", isSecure: true },
    ],
  });
  let noticeCalls = 0;
  return {
    calls,
    ctx: {
      now: () => 1800000000000,
      credentials: {
        get: async () => ({ value: saved }),
        set: async (_, v) => {
          saved = v;
        },
        delete: async () => {},
      },
      fetch: async (url, init) => {
        calls.push({ url, init });
        assert.ok(
          url === ACCOUNT_URL || url === NOTICES_URL,
          "only identity probe and read-only PC list are requested",
        );
        const body =
          url === ACCOUNT_URL
            ? {
                msg: {
                  puid: 123456,
                  uid: 456789,
                  fid: 789012,
                  name: "Synthetic",
                  hxToken: "SYNTHETIC_TOKEN",
                },
              }
            : typeof data === "function"
              ? data(noticeCalls++, new URLSearchParams(init.body))
              : data;
        const code = url === ACCOUNT_URL ? 200 : status;
        return {
          ok: code === 200,
          status: code,
          headers: { get: (name) => (name === "location" ? location : null), getSetCookie: () => [] },
          text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
        };
      },
    },
  };
}
const row = (id, extra = {}) => ({ idCode: `synthetic-${id}`, sendTag: 0, title: "合成通知", ...extra });
const envelope = (rows, extra = {}) => ({ status: true, notices: { list: rows, ...extra } });
test("PC notifications merge pinned/urgent, keep opaque entity IDs and plain local detail content", async () => {
  const pinned = row("pinned", {
    title: "<b>合成通知</b>",
    content: "<p>第一段 &amp; 合成</p><script>SECRET_SCRIPT()</script><p>第二段<br>换行</p>",
    createrName: "合成作者",
    sendTime: 1800000000000,
    course_name: "合成课程",
  });
  const h = harness({
    ...envelope(
      [pinned, row("pinned", { sendTag: "0" }), row(2, { sourceType: 4000 }), row("pinned", { sendTag: 1 })],
      {
        lastGetId: "synthetic-cursor",
        lastPage: 0,
      },
    ),
    topNotices: [pinned, row("pinned", { sendTag: "0" })],
    urgentNotices: [row(3)],
  });
  const result = await noticeList(h.ctx);
  assert.equal(validate(result), true, JSON.stringify(validate.errors));
  assert.deepEqual(
    result.items.map((r) => JSON.parse(r.id)),
    [
      ["synthetic-pinned", "0"],
      ["synthetic-3", "0"],
      ["synthetic-2", "0"],
      ["synthetic-pinned", "1"],
    ],
  );
  assert.equal(result.items[0].content, "第一段 & 合成\n\n第二段\n换行");
  assert.equal(result.items[0].pinned, true);
  assert.equal(result.items[0].category, "academic");
  assert.equal(result.items[1].importance, "urgent");
  assert.equal(result.items[2].category, "admin");
  assert.equal(result.items[0].publishedAt, "2027-01-15T08:00:00.000Z");
  assert.equal(result.hasNext, true);
  assert.equal(result.total, undefined);
  assert.equal(result.cursor, undefined);
  const req = h.calls.find((c) => c.url === NOTICES_URL);
  const query = new URLSearchParams(req.init.body);
  assert.equal(query.get("type"), "2");
  assert.equal(query.get("lastValue"), "");
  assert.equal(query.get("year"), "2027");
  assert.equal(query.has("puid"), false);
  assert.equal(req.init.method, "POST");
  assert.equal(req.init.headers.Cookie, "SESSION=SYNTHETIC_COOKIE");
  assert.equal(req.init.headers["X-Requested-With"], "XMLHttpRequest");
  assert.equal(req.init.headers.Authorization, undefined);
  assert.equal(h.calls.length, 2, "home first page makes one list POST even when it is short");
  assert.equal(JSON.stringify(result).includes("SYNTHETIC_COOKIE"), false);
});
test("missing dates, empty and category-filtered pages retain honest pagination", async () => {
  const h = harness(envelope([row(3, { insertTime: "2026-11-02 09:00:00" })]));
  const result = await noticeList(h.ctx);
  assert.equal(result.items[0].publishedAt, undefined);
  assert.equal(result.items[0].category, "unknown");
  assert.equal(result.hasNext, undefined);
  assert.deepEqual((await noticeList(h.ctx, { category: "academic" })).items, []);
  for (const lastPage of [true, 1])
    assert.equal((await noticeList(harness(envelope([], { lastPage })).ctx)).hasNext, false);
  for (const lastPage of [false, 0])
    assert.equal((await noticeList(harness(envelope([], { lastPage })).ctx)).hasNext, true);
  assert.equal((await noticeList(harness(envelope([])).ctx)).hasNext, undefined);
});
test("page/size uses bounded internal cursors without inventing params or completion", async () => {
  const h = harness((n, form) => {
    assert.equal(form.get("lastValue"), n ? "synthetic-next" : "");
    return n
      ? envelope([row(3), row(4)], { lastPage: 1 })
      : envelope([row(1), row(2)], { lastGetId: "synthetic-next", lastPage: 0 });
  });
  const result = await noticeList(h.ctx, { page: 2, size: 2 });
  assert.deepEqual(
    result.items.map((r) => JSON.parse(r.id)[0]),
    ["synthetic-3", "synthetic-4"],
  );
  assert.equal(result.hasNext, false);
  assert.equal(h.calls.length, 3);
  const loop = harness(envelope([row(1)], { lastGetId: "loop", lastPage: 0 }));
  await assert.rejects(noticeList(loop.ctx, { page: 2, size: 2 }), { code: "source_response_invalid" });
  const bounded = harness((n) => envelope([row(n)], { lastGetId: `cursor-${n}`, lastPage: 0 }));
  await assert.rejects(noticeList(bounded.ctx, { page: 8, size: 20 }), { code: "source_response_invalid" });
  assert.equal(bounded.calls.length, 9, "one identity check and at most eight list reads");
});
test("source failures and login redirect never replay a POST or erase an authenticated account", async () => {
  for (const [value, code] of [
    [{ status: false, msg: "请重新登录" }, "authentication_required"],
    [{ status: false, msg: "SYNTHETIC IP not allowed" }, "source_response_invalid"],
    [{ status: false, msg: "访问异常，请验证" }, "source_response_invalid"],
    [{ status: false, msg: "请求频繁，稍后重试" }, "source_response_invalid"],
  ])
    await assert.rejects(noticeList(harness(value).ctx), { code });
  for (const [status, location, code] of [
    [302, "https://passport2.chaoxing.com/login?refer=synthetic", "authentication_required"],
    [307, "https://untrusted.invalid/", "source_response_invalid"],
    [401, null, "authentication_required"],
    [403, null, "source_response_invalid"],
    [429, null, "source_response_invalid"],
  ]) {
    const h = harness({}, { status, location });
    await assert.rejects(noticeList(h.ctx), { code });
    assert.equal(h.calls.length, 2);
    assert.equal(JSON.parse((await h.ctx.credentials.get()).value).accountId, "123456");
  }
});
test("malformed/rejected/oversized list never becomes empty success; no read side effects", async () => {
  for (const value of [
    { result: 1, data: { notices: [] } },
    { status: true },
    envelope(null),
    envelope([{ id: 1 }]),
    envelope([row(1, { sendTag: {} })]),
    "<html>login</html>",
    "x".repeat(1024 * 1024 + 1),
  ])
    await assert.rejects(noticeList(harness(value).ctx), { code: "source_response_invalid" });
  for (const params of [
    { page: 0 },
    { size: 101 },
    { page: 9 },
    { category: "other" },
    { markRead: true },
    { cursor: "unsupported" },
  ]) {
    const h = harness({});
    await assert.rejects(noticeList(h.ctx, params), { code: "input_invalid_request" });
    assert.equal(h.calls.length, 0);
  }
});
