// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Synthetic public-page layouts only. Tests never connect to a school.
import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

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
const { noticeList, noticeDetail } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString("base64")}`
);
const BASE = "https://jwc.xidian.edu.cn";
const INDEX =
  '<div class="tit">通知公告</div><ul><li><a title="合成完整通知标题" href="info/1012/42.htm"><div class="time lan"><p>13</p><span>2026.10</span></div><p>合成完整通知…</p></a></li><li><a href="info/1012/43.htm"><div class="time"><p>12</p><span>2026.10</span></div><p>无title属性的通知</p></a></li><li><a title="另一合成通知" href="2j-ce-nry.jsp?urltype=news.NewsContentUrl&wbtreeid=1012&wbnewsid=44">通知</a></li></ul>';
const DETAIL =
  '<div class="nry_con"><div class="con"><p class="tit">合成完整通知标题</p><p class="zd">不属于正文</p><div id="vsb_content"><div class="v_news_content"><style>.docx{color:red}</style><p>第一段合成正文。</p><p>第二段<br>换行。</p><script>bad()</script><p><a href="/system/resource/storage/synthetic.pdf">合成附件</a></p></div></div></div></div>';
function context(body) {
  const calls = [];
  return {
    calls,
    async fetch(url, init) {
      calls.push({ url, init });
      return { ok: true, text: async () => (typeof body === "function" ? body(url) : body) };
    },
  };
}

test("list uses full title attribute and excludes nested date text from fallback titles", async () => {
  const ctx = context(INDEX);
  const { items } = await noticeList(ctx);
  assert.equal(items[0].title, "合成完整通知标题");
  assert.equal(items[0].publishedAt, "2026-10-13T00:00:00Z");
  assert.equal(items[1].title, "无title属性的通知");
  assert.equal(items[2].id, "44");
  assert.equal(ctx.calls.length, 1);
});

test("detail fetches selected notice, strips active/style content and preserves paragraphs", async () => {
  const ctx = context(DETAIL);
  const result = await noticeDetail(ctx, { id: "42", url: `${BASE}/info/1012/42.htm` });
  assert.equal(result.id, "42");
  assert.equal(result.title, "合成完整通知标题");
  assert.equal(result.content, "第一段合成正文。\n\n第二段\n换行。\n\n合成附件");
  assert.deepEqual(result.attachments, [
    { name: "合成附件", url: `${BASE}/system/resource/storage/synthetic.pdf` },
  ]);
  assert.equal(ctx.calls.length, 1);
  assert.equal(ctx.calls[0].init, undefined);
});

test("id-only request discovers its link; JSP notices retain their source URL", async () => {
  const ctx = context((url) => (url.endsWith("index.htm") ? INDEX : DETAIL));
  assert.equal((await noticeDetail(ctx, { id: "44" })).id, "44");
  assert.equal(ctx.calls.length, 2);
  assert.ok(ctx.calls[1].url.includes("wbnewsid=44"));
});

test("attachments alongside the article body are retained without fetching downloads", async () => {
  const html =
    '<div class="nry_con"><div class="con"><p class="tit">合成公告</p><ul><li><a href="/system/_content/download.jsp?wbfileid=SYNTHETIC">合成文档.docx</a></li></ul><div class="v_news_content"><p>合成正文</p></div></div></div>';
  const ctx = context(html);
  const result = await noticeDetail(ctx, { id: "42", url: `${BASE}/info/1012/42.htm` });
  assert.equal(result.attachments[0].name, "合成文档.docx");
  assert.equal(result.content, "合成正文");
  assert.equal(ctx.calls.length, 1);
});

test("plain text retains separators between table cells", async () => {
  const ctx = context(
    '<div class="nry_con"><div class="con"><p class="tit">合成表格公告</p><div class="v_news_content"><table><tr><td>时间</td><td>地点</td></tr><tr><td>合成日期</td><td>合成地点</td></tr></table></div></div></div>',
  );
  const result = await noticeDetail(ctx, { id: "42", url: `${BASE}/info/1012/42.htm` });
  assert.equal(result.content, "时间 地点\n\n合成日期 合成地点");
});

test("detail rejects external URLs and mismatched ids before any request", async () => {
  for (const url of [
    "https://example.invalid/info/1012/42.htm",
    `${BASE}/info/1012/43.htm`,
    `${BASE}/index.htm`,
  ]) {
    const ctx = context(DETAIL);
    await assert.rejects(noticeDetail(ctx, { id: "42", url }));
    assert.equal(ctx.calls.length, 0);
  }
});

test("malformed/failed pages remain failures and image-only bodies omit content", async () => {
  await assert.rejects(
    noticeDetail(context("<html>maintenance</html>"), { id: "42", url: `${BASE}/info/1012/42.htm` }),
    /layout_changed/,
  );
  await assert.rejects(
    noticeDetail({ fetch: async () => ({ ok: false }) }, { id: "42", url: `${BASE}/info/1012/42.htm` }),
    /http_failed/,
  );
  const value = await noticeDetail(
    context(
      '<div class="nry_con"><div class="con"><p class="tit">合成图片公告</p><div class="v_news_content"><img src="/synthetic.png"></div></div></div>',
    ),
    { id: "42", url: `${BASE}/info/1012/42.htm` },
  );
  assert.equal(value.content, undefined);
});
