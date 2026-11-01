// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Synthetic teachers only; never contacts a school or reads saved credentials.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { build } from "esbuild";

const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/faculty.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const { facultySearch } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString("base64")}`
);
const ajv = new Ajv({ strict: true });
addFormats(ajv);
const validate = ajv.compile(
  JSON.parse(readFileSync(new URL("../../../contract/schema/faculty.search.schema.json", import.meta.url))),
);
const row = (id = 101) => ({
  teacherId: id,
  teacherName: "合成同名教师",
  collegeName: "合成学院",
  prorank: "教授",
  profile: "<p>合成简介</p><script>secret()</script><p>第二段</p>",
  discipline: "计算机科学, 合成学科",
  researchDirectionList: [{ researchDirectionTitle: "<b>合成方向</b>" }, { researchDirectionTitle: "" }],
  url: `http://faculty.xidian.edu.cn:80/SYNTHETIC${id}/zh_CN/index.htm`,
  mobilephone: "MUST-NOT-RETURN",
  email: "not-returned@example.invalid",
});
function context(body = { totalnum: 21, totalpage: 3, pageindex: 1, teacherData: [row(), row(102)] }) {
  const calls = [];
  return {
    calls,
    get credentials() {
      throw new Error("must not read credentials");
    },
    async fetch(url, init) {
      calls.push({ url, init });
      return { ok: true, json: async () => body };
    },
  };
}

test("query uses one public request, escapes filters and keeps same-name identities", async () => {
  const ctx = context();
  const result = await facultySearch(ctx, { query: " 合成 & 教师 ", researchArea: "图像+识别", page: 2 });
  assert.equal(ctx.calls.length, 1);
  const url = new URL(ctx.calls[0].url);
  assert.equal(url.origin, "https://faculty.xidian.edu.cn");
  assert.equal(url.searchParams.get("teacherName"), "合成 & 教师");
  assert.equal(url.searchParams.get("searchDirection"), "图像+识别");
  assert.equal(url.searchParams.get("pageindex"), "2");
  assert.equal(url.searchParams.get("pagesize"), "10");
  assert.deepEqual(ctx.calls[0].init, { redirect: "error" });
  assert.deepEqual(
    result.items.map((x) => x.id),
    ["101", "102"],
  );
  assert.equal(result.items[0].summary, "合成简介 第二段");
  assert.deepEqual(result.items[0].researchAreas, ["合成方向"]);
  assert.equal(result.items[0].profileUrl, "https://faculty.xidian.edu.cn/SYNTHETIC101/zh_CN/index.htm");
  assert.equal(result.page, 2);
  assert.equal(result.hasMore, true);
  assert.equal(result.total, 21);
  assert.ok(!JSON.stringify(result).includes("MUST-NOT-RETURN"));
  assert.ok(!JSON.stringify(result).includes("not-returned"));
  assert.ok(validate(result), JSON.stringify(validate.errors));
});

test("empty search results preserve valid zero total and no next page", async () => {
  const result = await facultySearch(context({ totalnum: 0, totalpage: 1, pageindex: 0, teacherData: [] }), {
    researchArea: "合成不存在",
  });
  assert.deepEqual(result.items, []);
  assert.equal(result.total, 0);
  assert.equal(result.hasMore, false);
  assert.ok(validate(result));
});

test("omitted optional fields remain absent and final page does not continue", async () => {
  const result = await facultySearch(
    context({
      totalnum: 1,
      totalpage: 1,
      pageindex: 0,
      teacherData: [{ teacherId: 3, showName: "合成教师" }],
    }),
    { query: "合成" },
  );
  assert.deepEqual(result.items, [{ id: "3", name: "合成教师" }]);
  assert.equal(result.hasMore, false);
});

test("invalid inputs fail before requesting and never allow full-directory preload", async () => {
  for (const params of [
    {},
    { query: null, researchArea: "合成" },
    { query: " " },
    { query: 1 },
    { query: "x", page: 0 },
    { query: "x", page: null },
    { query: "x", pageSize: null },
    { query: "x", pageSize: 21 },
    { query: "x", page: 1.5 },
    { query: "x", url: "https://evil.invalid/" },
    { query: "x".repeat(81) },
  ]) {
    const ctx = context();
    await assert.rejects(facultySearch(ctx, params), /invalid_params/);
    assert.equal(ctx.calls.length, 0);
  }
});

test("broken JSON, pagination, duplicate identity and external profiles remain failures", async () => {
  const examples = [
    {},
    { totalnum: 0, totalpage: 1 },
    { totalnum: 0, totalpage: 1, teacherData: [row()] },
    { totalnum: 2, totalpage: 1, teacherData: [row(), row()] },
    {
      totalnum: 1,
      totalpage: 1,
      teacherData: [{ ...row(), url: "https://evil.invalid/SYNTHETIC/zh_CN/index.htm" }],
    },
    { totalnum: 1, totalpage: 1, teacherData: [{ ...row(), teacherId: null }] },
  ];
  for (const body of examples)
    await assert.rejects(facultySearch(context({ pageindex: 0, ...body }), { query: "合成" }));
  await assert.rejects(facultySearch({ fetch: async () => ({ ok: false }) }, { query: "合成" }));
  await assert.rejects(
    facultySearch(
      {
        fetch: async () => ({
          ok: true,
          json: async () => {
            throw new Error("malformed");
          },
        }),
      },
      { query: "合成" },
    ),
    /response_invalid/,
  );
});

test("source must confirm the requested page rather than relabeling page one", async () => {
  for (const pageindex of [0, undefined, "1"]) {
    await assert.rejects(
      facultySearch(context({ totalnum: 21, totalpage: 3, pageindex, teacherData: [row()] }), {
        query: "合成",
        page: 2,
      }),
      /response_invalid/,
    );
  }
});
