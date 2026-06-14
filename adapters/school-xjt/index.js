/**
 * school-xjt（西安交通大学教务处）—— 首个 **fetch 模式** adapter（spike）。
 *
 * 目标：公开通知 notice.list。需要 fetch 模式是因为站点有 **JS 反爬挑战**（多步握手），
 * 数据本身公开、**不碰学生凭证**（credentials 块为空，全程 passthrough）。
 *
 * ⚠️ 现状：**尚不可端到端运行**——运行时的受限 `ctx.fetch`（Broker）属 Track B（ADR-009
 * 承重路径，未实现）。本文件是 Track A 的逻辑 spike：流程见 ./FLOW.md。
 *
 * ⚠️ 设计缺口（FLOW.md §3）：挑战返回的 client_id 可能只在 **响应体**、无 `Set-Cookie`。
 * 若如此，per-execution jar 抓不到它、后续请求带不上 → 流程断，需 ADR-009 修订。
 * 本实现按 **ADR-009 合规方式**写（adapter 不自设 cookie，依赖 jar 抓 Set-Cookie）；
 * 缺口落点已在下方标注。待真实抓包（FLOW.md §5）确认 Set-Cookie 是否存在后再定。
 */

import { parseDocument, selectAll, getText, getAttributeValue } from "elecon:html";

const ORIGIN = "https://dean.xjtu.edu.cn";

export const capabilities = {
  /**
   * @param {CtxFetch} ctx  受限 fetch（Broker 注入/脱敏；本 adapter 全 passthrough）
   * @param {unknown} _params
   */
  "notice.list": async (ctx, _params) => {
    // [1] GET 首页（passthrough，不注入凭证）——可能命中 JS 挑战页
    let html = await (await ctx.fetch(ORIGIN + "/")).text();

    // [2] 若是挑战页：解析 challengeId / answer（answer 直接给在页面，无需算 JS）
    if (html.includes("var challengeId")) {
      const cid = matchOne(/var challengeId\s*=\s*"([^"]+)"/, html);
      const ansStr = matchOne(/var answer\s*=\s*(\d+)/, html);
      if (cid === null || ansStr === null) {
        // 页面结构变了：交给宿主按 parse_failed 处理（adapter 抛错）
        throw new Error("challenge page structure changed: challengeId/answer not found");
      }

      // [3] POST 挑战端点（passthrough）。browser_info 是反爬指纹（official 独占 fetch
      //     才允许这类伪造，ADR-009 §2.4 第 3 条）。
      await ctx.fetch(ORIGIN + "/dynamic_challenge", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          challenge_id: cid,
          answer: Number(ansStr),
          browser_info: {
            userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
            language: "zh-CN",
            platform: "Linux x86_64",
            cookieEnabled: true,
            hardwareConcurrency: 8,
            deviceMemory: 8,
            timezone: "Asia/Shanghai",
          },
        }),
      });

      // ⚠️ 缺口（FLOW.md §3）：此处依赖 origin 在上面的 POST 响应里 **Set-Cookie: client_id=...**，
      // 由 per-execution jar 自动捕获并在下一个请求携带。**若 client_id 只在 POST 响应体（JSON）、
      // 没有 Set-Cookie**，jar 抓不到、下面这个 GET 不会带 client_id → 仍是挑战页 → 失败。
      // adapter **不能**自己 set cookie（ADR-009 §2.3 宿主剥除 Cookie 头）。
      // → 待抓包确认；若缺口为真，按 FLOW.md §4 方向修订 ADR-009 后再补此处。

      // [5] 带 jar 中的会话 cookie 重新 GET 首页 → 真实通知页
      html = await (await ctx.fetch(ORIGIN + "/")).text();
    }

    // [6] 解析通知列表：div.tz（含「通知公告」）→ li → a[title] / i / span
    return { items: parseNotices(html) };
  },
};

function parseNotices(html) {
  const doc = parseDocument(html);
  const blocks = selectAll("div.tz", doc);
  const target = blocks.find((el) => getText(el).includes("通知公告")); // 通知公告
  if (!target) return [];

  const items = [];
  for (const li of selectAll("li", target)) {
    const a = selectAll("a", li).find((el) => getAttributeValue(el, "title"));
    if (!a) continue;

    const title = (getAttributeValue(a, "title") || "").trim();
    const href = getAttributeValue(a, "href") || "";
    const url = href.startsWith("http") ? href : ORIGIN + "/" + href.replace(/^\//, "");

    const span = selectAll("span", li)[0];
    const dateStr = span ? getText(span).trim() : "";

    const idMatch = href.match(/(\d+)\.html?$/);
    items.push({
      id: idMatch ? idMatch[1] : href,
      title,
      url,
      publishedAt: normalizeDate(dateStr),
      category: "academic", // dean 通知统一归 academic；细分留待 generic/扩展
      source: "教务处", // 教务处
    });
  }
  return items;
}

/** "2026-06-12" → RFC3339/UTC。无法识别则返回空串（schema 容忍缺省由宿主校验把关）。 */
function normalizeDate(s) {
  const m = s.match(/(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}T00:00:00Z` : "";
}

function matchOne(re, s) {
  const m = re.exec(s);
  return m ? m[1] : null;
}
