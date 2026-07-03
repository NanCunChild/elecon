import { parseDocument, selectAll, getText, getAttributeValue, nextElementSibling } from "elecon:html";

const BASE_URL = "https://jwc.xidian.edu.cn";

function normalizeDate(s) {
  const m = s.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  return m ? `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}T00:00:00Z` : null;
}

export const capabilities = {
  "notice.list": (ctx, params, responses) => {
    try {
      const doc = parseDocument(responses.page.body);
      const tits = selectAll("div.tit", doc);
      const noticeTit = tits.find((el) => getText(el).includes("\u901A\u77E5\u516C\u544A"));
      if (!noticeTit) return { items: [] };

      const ul = nextElementSibling(noticeTit);
      if (!ul) return { items: [] };

      const lis = selectAll("li", ul);
      const items = [];
      for (const li of lis) {
        const a = selectAll("a", li)[0];
        if (!a) continue;
        const span = selectAll("span", li)[0];

        const href = getAttributeValue(a, "href") || "";
        const title = getText(a).trim();
        const dateStr = span ? getText(span).trim() : "";
        const idMatch = href.match(/\/(\d+)\.htm$/);
        const id = idMatch ? idMatch[1] : href;

        const item = {
          id,
          title,
          url: BASE_URL + href,
          category: "academic",
          source: "\u6559\u52A1\u5904",
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
