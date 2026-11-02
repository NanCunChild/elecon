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
function harness(data, { status = 200 } = {}) {
  const calls = [];
  let saved = JSON.stringify({
    version: 1,
    serviceId: "chaoxing",
    accountId: "123456",
    accountLabel: "Synthetic",
    cookies: [
      {
        name: "SESSION",
        value: "SYNTHETIC_COOKIE",
        domain: "chaoxing.com",
        path: "/",
        isSecure: true,
      },
    ],
  });
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
          url === ACCOUNT_URL || url.startsWith(`${NOTICES_URL}?`),
          "only identity probe and HTTP notification list are requested",
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
            : data;
        const code = url === ACCOUNT_URL ? 200 : status;
        return {
          ok: code === 200,
          status: code,
          headers: { get: () => null, getSetCookie: () => [] },
          text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
        };
      },
    },
  };
}
test("HTTP notifications merge pinned first, keep exact IDs and plain local detail content", async () => {
  const h = harness(
    '{"result":1,"data":{"topNotices":[{"id":9007199254740993,"title":"<b>合成通知</b>","content":"<p>第一段 &amp; 合成</p><script>SECRET_SCRIPT()</script><p>第二段<br>换行</p>","createrName":"合成作者","sendTime":1800000000000,"course_name":"合成课程"}],"notices":{"list":[{"id":9007199254740993,"title":"重复"},{"id":2,"title":"合成审批","sourceType":4000}],"lastGetId":"unproven-cursor"}}}',
  );
  const result = await noticeList(h.ctx, { page: 2, size: 10 });
  assert.equal(validate(result), true, JSON.stringify(validate.errors));
  assert.deepEqual(
    result.items.map((row) => row.id),
    ["9007199254740993", "2"],
  );
  assert.equal(result.items[0].content, "第一段 & 合成\n\n第二段\n换行");
  assert.equal(result.items[0].pinned, true);
  assert.equal(result.items[0].category, "academic");
  assert.equal(result.items[1].category, "admin");
  assert.equal(result.items[0].publishedAt, "2027-01-15T08:00:00.000Z");
  assert.equal(result.hasNext, undefined);
  assert.equal(result.total, undefined);
  assert.equal(result.cursor, undefined);
  const req = h.calls.find((c) => c.url.startsWith(NOTICES_URL));
  const query = new URL(req.url).searchParams;
  assert.equal(query.get("page"), "1");
  assert.equal(query.get("pageSize"), "10");
  assert.equal(query.get("puid"), "123456");
  assert.equal(req.init.method, "GET");
  assert.equal(req.init.headers.Cookie, "SESSION=SYNTHETIC_COOKIE");
  assert.equal(req.init.headers.Authorization, undefined);
  assert.equal(JSON.stringify(result).includes("SYNTHETIC_COOKIE"), false);
});
test("array shape, unknown dates, empty and category-filtered pages retain honest pagination", async () => {
  const h = harness({
    result: 1,
    data: {
      notices: [{ id: 3, title: "合成通知", insertTime: "2026-11-02 09:00:00" }],
    },
  });
  const result = await noticeList(h.ctx);
  assert.equal(result.items[0].publishedAt, undefined);
  assert.equal(result.items[0].category, "unknown");
  assert.deepEqual((await noticeList(h.ctx, { category: "academic" })).items, []);
  assert.deepEqual((await noticeList(harness({ result: 1, data: { notices: [] } }).ctx)).items, []);
});
test("malformed/rejected/oversized list never becomes an empty success; no read side effects", async () => {
  for (const value of [
    { result: 0, errorMsg: "SYNTHETIC_ERROR" },
    { result: 1, data: {} },
    { result: 1, data: { notices: null } },
    { result: 1, data: { notices: [{ id: 0 }] } },
    "<html>login</html>",
    "x".repeat(1024 * 1024 + 1),
  ]) {
    await assert.rejects(noticeList(harness(value).ctx), {
      code: "source_response_invalid",
    });
  }
  await assert.rejects(noticeList(harness({}, { status: 401 }).ctx), {
    code: "authentication_required",
  });
  for (const params of [{ page: 0 }, { size: 101 }, { category: "other" }, { markRead: true }]) {
    const h = harness({});
    await assert.rejects(noticeList(h.ctx, params), {
      code: "input_invalid_request",
    });
    assert.equal(h.calls.length, 0);
  }
});
