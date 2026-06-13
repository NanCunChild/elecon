import { parseDocument, selectAll, getText, getAttributeValue, nextElementSibling } from "elecon:html";

const BASE_URL = "https://jwc.xidian.edu.cn";

export const capabilities = {
  "notice.list": (ctx, params, responses) => {
    const doc = parseDocument(responses.page.body);
    const tits = selectAll("div.tit", doc);
    const noticeTit = tits.find((el) => getText(el).includes("\u901A\u77E5\u516C\u544A"));
    if (!noticeTit) return { items: [] };

    const ul = nextElementSibling(noticeTit);
    if (!ul) return { items: [] };

    const lis = selectAll("li", ul);
    const items = lis.map((li) => {
      const a = selectAll("a", li)[0];
      const span = selectAll("span", li)[0];
      const href = a ? getAttributeValue(a, "href") || "" : "";
      const title = a ? getText(a).trim() : "";
      const dateStr = span ? getText(span).trim() : "";
      const idMatch = href.match(/\/(\d+)\.htm$/);
      const id = idMatch ? idMatch[1] : href;
      return {
        id,
        title,
        url: BASE_URL + href,
        publishedAt: dateStr ? dateStr + "T00:00:00Z" : "",
        category: "academic",
        source: "\u6559\u52A1\u5904",
      };
    });

    return { items };
  },
};
