/**
 * school-xjt（西安交通大学教务处）—— 首个 **fetch 模式** adapter（spike）。
 *
 * 目标：公开通知 notice.list。需要 fetch 模式是因为站点有 **JS 反爬挑战**（多步握手），
 * 数据本身公开、**不碰学生凭证**（credentials 块为空，全程 passthrough）。
 *
 * 现状：**已端到端跑通**（首个真实 fetch adapter）——B6 运行时（runFetchAdapter）+ direct
 * Transport 落地后，经录制夹具回放验证解析出真实通知（server `npm run smoke:xjt`）。流程见 ./FLOW.md。
 *
 * body-token 缺口（FLOW.md §3，已修补）：client_id 仅在响应 body、origin 零 Set-Cookie
 * （pac.txt 实锤）。现经 ctx.setEphemeralCookie（ADR-009 §2.4 rev-3 / PR #34 契约 /
 * B4 #37 运行时）写入 jar ephemeral 分区，四重栅栏由 Broker 强制。
 */

import {
  getAttributeValue,
  getText,
  makeUrlAbsolute,
  normalizeDate,
  parseDocument,
  selectAll,
} from "elecon:html";

const ORIGIN = "https://dean.xjtu.edu.cn";

/** safeFetch wraps ctx.fetch with structured error on network failure. */
async function safeFetch(ctx, url, init) {
  try {
    return await ctx.fetch(url, init);
  } catch (e) {
    throw new Error(`fetch failed ${url}: ${e.message || e}`);
  }
}

/** safeJson wraps Response.json() with structured error on parse failure. */
async function safeJson(res) {
  try {
    return await res.json();
  } catch (e) {
    throw new Error(`json parse failed: ${e.message || e}`);
  }
}

export const capabilities = {
  /**
   * @param {CtxFetch} ctx  受限 fetch（Broker 注入/脱敏；本 adapter 全 passthrough）
   * @param {unknown} _params
   */
  "notice.list": async (ctx, _params) => {
    // [1] GET 首页（passthrough，不注入凭证）——可能命中 JS 挑战页
    let html = await (await safeFetch(ctx, ORIGIN + "/")).text();

    // [2] 若是挑战页：解析 challengeId / answer（answer 直接给在页面，无需算 JS）
    if (html.includes("var challengeId")) {
      const cid = matchOne(/var challengeId\s*=\s*"([^"]+)"/, html);
      const ansStr = matchOne(/var answer\s*=\s*(\d+)/, html);
      if (cid === null || ansStr === null || ansStr.length === 0) {
        // 页面结构变了：交给宿主按 parse_failed 处理（adapter 抛错）
        throw new Error("challenge page structure changed: challengeId/answer not found");
      }

      // [3] POST 挑战端点（passthrough）。browser_info 是反爬指纹（official 独占 fetch
      //     才允许这类伪造，ADR-009 §2.4 第 3 条）。
      // TODO(production): browser_info 为硬编码指纹（Chrome 148 / Linux），会随版本过时；
      //   且若 origin 校验 UA header 与 body 一致性可能被拒。production 化时考虑随宿主环境
      //   动态生成或周期更新（spike 阶段硬编码足够）。
      const challengeRes = await safeFetch(ctx, ORIGIN + "/dynamic_challenge", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          challenge_id: cid,
          answer: Number(ansStr),
          browser_info: {
            userAgent:
              "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
            language: "zh-CN",
            platform: "Linux x86_64",
            cookieEnabled: true,
            hardwareConcurrency: 8,
            deviceMemory: 8,
            timezone: "Asia/Shanghai",
          },
        }),
      });
      if (!challengeRes.ok) {
        throw new Error(`challenge submit failed: HTTP ${challengeRes.status}`);
      }

      // [4] 从 POST 响应 body 解出 client_id，经 ctx.setEphemeralCookie 写入 jar。
      // 注：2026-06-16 录制确认 origin 实际有 Set-Cookie（jar 会自动捕获），本调用为
      // 防御性冗余（ephemeral 优先级 < origin，同名以 origin 为准，栅栏 2 无害）——
      // 若 origin 未来改回无 Set-Cookie，本通道仍兜底。
      const challengeBody = await safeJson(challengeRes);
      if (!challengeBody.success || !challengeBody.client_id) {
        throw new Error("challenge response: success=false or missing client_id");
      }
      ctx.setEphemeralCookie("client_id", challengeBody.client_id, {
        domain: "dean.xjtu.edu.cn",
      });

      // [5] 带 jar 中的会话 cookie 重新 GET 首页 → 真实通知页
      html = await (await safeFetch(ctx, ORIGIN + "/")).text();

      // 若仍是挑战页 → 挑战未解成功，明确报错而非静默返回空列表
      // （否则"取数失败"会被伪装成"无通知"；交宿主按 parse_failed 处理）。
      if (html.includes("var challengeId")) {
        throw new Error("challenge not solved: second GET still returns challenge page");
      }
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
    const url = makeUrlAbsolute(href, ORIGIN);

    const span = selectAll("span", li)[0];
    const dateStr = span ? getText(span).trim() : "";

    const idMatch = href.match(/(\d+)\.html?$/);
    const item = {
      id: idMatch ? idMatch[1] : href,
      title,
      url,
      category: "academic", // dean 通知统一归 academic；细分留待 generic/扩展
      source: "教务处", // 教务处
    };
    // 日期不可解析 → 省略 publishedAt（notice.list 1.1：可选；ADR-001 §3.4 缺失语义 / §8.1）。
    // 不再回退空串——"" 非合法 date-time，会被 schema 拒。
    const publishedAt = normalizeDate(dateStr);
    if (publishedAt !== null) item.publishedAt = publishedAt;
    items.push(item);
  }
  return items;
}

function matchOne(re, s) {
  const m = re.exec(s);
  return m ? m[1] : null;
}
