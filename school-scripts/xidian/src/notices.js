/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { getAttributeValue, getText, nextElementSibling, parseDocument, selectAll } from "elecon:html";
import { dateOnly } from "./normalize.js";
import { resolveUrl } from "./session.js";

export async function noticeList(ctx, params = {}) {
  if ((params.page ?? 1) !== 1) throw new Error("xidian_notice_page_unsupported");
  const size = params.size ?? 100;
  if (!Number.isInteger(size) || size < 1 || size > 100) throw new Error("xidian_invalid_size");
  const response = await ctx.fetch("https://jwc.xidian.edu.cn/index.htm");
  if (!response.ok) throw new Error("xidian_notice_http_failed");
  const doc = parseDocument(await response.text());
  const title = selectAll("div.tit", doc).find((node) => getText(node).includes("通知公告"));
  const list = title && nextElementSibling(title);
  if (!list) throw new Error("xidian_notice_layout_changed");
  const items = [];
  for (const row of selectAll("li", list)) {
    const anchor = selectAll("a", row)[0];
    const href = anchor && getAttributeValue(anchor, "href");
    const name = anchor && getText(anchor).trim();
    if (!href || !name) continue;
    const item = {
      id: href.match(/(?:^|\/)(\d+)\.htm(?:[?#]|$)/)?.[1] || href,
      title: name,
      url: resolveUrl(href, "https://jwc.xidian.edu.cn/index.htm"),
      category: "academic",
      source: "西电教务处",
    };
    const time = selectAll("div.time", row)[0];
    const month = time && selectAll("span", time)[0];
    const day = time && selectAll("p", time)[0];
    const raw = month && day ? `${getText(month).trim()}.${getText(day).trim()}` : getText(row);
    const match = raw.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
    if (match) {
      try {
        item.publishedAt = `${dateOnly(`${match[1]}-${match[2]}-${match[3]}`)}T00:00:00Z`;
      } catch {
        /* Missing/invalid publication day is optional. */
      }
    }
    items.push(item);
  }
  return {
    items: params.category && params.category !== "academic" ? [] : items.slice(0, size),
    sourceSystem: "xidian-jwc",
  };
}
