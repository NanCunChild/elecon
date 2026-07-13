/**
 * school-xidian（西安电子科技大学教务处）—— parser 模式 adapter。
 *
 * 目标：公开通知 notice.list。站点为纯静态 HTML，不需要 fetch 模式。核心代取并脱敏后
 * 传入原始响应，adapter 只做 HTML → 标准 schema 的纯解析。
 *
 * 现状：**已端到端跑通**——QuickJS-wasm 沙箱对录制夹具产出等于 golden，通过 contract schema
 * （server `npm run smoke:sandbox` testXidianNoticeList）。
 */

import {
  getAttributeValue,
  getText,
  makeUrlAbsolute,
  nextElementSibling,
  normalizeDate,
  parseDocument,
  selectAll,
} from "elecon:html";

const ORIGIN = "https://jwc.xidian.edu.cn";

/**
 * 提取 li 内的日期文本。已见两种页面结构：
 *   ① <li>…<span>2026-06-10</span></li> —— span 即完整日期
 *   ② <li>…<div class="time"><p>30</p><span>2026.06</span></div> —— span 年月 + p 日，需拼合
 */
function extractDateStr(li) {
  const time = selectAll("div.time", li)[0];
  if (time) {
    const span = selectAll("span", time)[0];
    const p = selectAll("p", time)[0];
    const yearMonth = span ? getText(span).trim() : "";
    const day = p ? getText(p).trim() : "";
    if (yearMonth && day) return `${yearMonth}.${day}`;
    return yearMonth || day;
  }
  const span = selectAll("span", li)[0];
  return span ? getText(span).trim() : "";
}

export const capabilities = {
  "notice.list": (ctx, params, responses) => {
    try {
      const doc = parseDocument(responses.page.body);
      const tits = selectAll("div.tit", doc);
      const noticeTit = tits.find((el) => getText(el).includes("通知公告"));
      if (!noticeTit) return { items: [] }; // 通知公告

      const ul = nextElementSibling(noticeTit);
      if (!ul) return { items: [] };

      const lis = selectAll("li", ul);
      const items = [];
      for (const li of lis) {
        const a = selectAll("a", li)[0];
        if (!a) continue;

        const href = getAttributeValue(a, "href") || "";
        const title = getText(a).trim();
        const dateStr = extractDateStr(li);
        const idMatch = href.match(/\/?(\d+)\.htm$/);
        const id = idMatch ? idMatch[1] : href;
        const url = makeUrlAbsolute(href, ORIGIN);

        const item = {
          id,
          title,
          url,
          category: "academic",
          source: "教务处",
        };
        const publishedAt = normalizeDate(dateStr);
        if (publishedAt !== null) item.publishedAt = publishedAt;
        items.push(item);
      }

      return { items };
    } catch (e) {
      throw new Error(`parse failed: ${e.message || e}`);
    }
  },
};
