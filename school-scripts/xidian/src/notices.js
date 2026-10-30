/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { getAttributeValue, getText, nextElementSibling, parseDocument, selectAll } from "elecon:html";
import { dateOnly } from "./normalize.js";
import { parseUrl, resolveUrl } from "./session.js";

const BASE = "https://jwc.xidian.edu.cn/index.htm";

function noticeId(href) {
  return (
    href.match(/(?:^|\/)(\d+)\.htm(?:[?#]|$)/)?.[1] || href.match(/[?&]wbnewsid=(\d+)(?:&|$)/)?.[1] || href
  );
}

// ADR-025 §2.2: school HTML becomes plain schema text, never executable UI.
function plainText(node, skipTime = false) {
  if (node.type === "text") return node.data;
  const name = node.name?.toLowerCase();
  if (
    ["script", "style", "noscript"].includes(name) ||
    (skipTime && (node.attribs?.class || "").split(/\s+/).includes("time"))
  )
    return "";
  if (name === "br") return "\n";
  const text = (node.children || []).map((child) => plainText(child, skipTime)).join("");
  if (name === "td" || name === "th") return `${text}\t`;
  return /^(p|div|section|article|h[1-6]|li|tr|table|blockquote)$/.test(name) ? `\n${text}\n` : text;
}

function readableText(node, skipTime = false) {
  return plainText(node, skipTime)
    .replace(/[^\S\n]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export async function noticeList(ctx, params = {}) {
  if ((params.page ?? 1) !== 1) throw new Error("xidian_notice_page_unsupported");
  const size = params.size ?? 100;
  if (!Number.isInteger(size) || size < 1 || size > 100) throw new Error("xidian_invalid_size");
  const response = await ctx.fetch(BASE);
  if (!response.ok) throw new Error("xidian_notice_http_failed");
  const doc = parseDocument(await response.text());
  const title = selectAll("div.tit", doc).find((node) => getText(node).includes("通知公告"));
  const list = title && nextElementSibling(title);
  if (!list) throw new Error("xidian_notice_layout_changed");
  const items = [];
  for (const row of selectAll("li", list)) {
    const anchor = selectAll("a", row)[0];
    const href = anchor && getAttributeValue(anchor, "href");
    const name = anchor && (getAttributeValue(anchor, "title")?.trim() || readableText(anchor, true));
    if (!href || !name) continue;
    const item = {
      id: noticeId(href),
      title: name,
      url: resolveUrl(href, BASE),
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

/** ADR-025 §2.2: fetch the selected notice only after a detail request. */
export async function noticeDetail(ctx, params = {}) {
  if (typeof params.id !== "string" || !params.id) throw new Error("xidian_notice_invalid_id");
  let url = params.url;
  if (url == null) {
    const list = await noticeList(ctx);
    url = list.items.find((item) => item.id === params.id)?.url;
  }
  if (typeof url !== "string") throw new Error("xidian_notice_missing");
  const target = parseUrl(url);
  if (
    target.origin !== "https://jwc.xidian.edu.cn" ||
    !(/^\/info\/\d+\/\d+\.htm$/.test(target.path) || target.path === "/2j-ce-nry.jsp") ||
    noticeId(url) !== params.id
  )
    throw new Error("xidian_notice_invalid_url");
  // Public school content is fetched without the authentication cookie jar.
  const response = await ctx.fetch(url);
  if (!response.ok) throw new Error("xidian_notice_http_failed");
  const doc = parseDocument(await response.text());
  const article = selectAll(".nry_con .con", doc)[0];
  const title = selectAll(".nry_con .con > .tit", doc)[0];
  const body = selectAll(".v_news_content", doc)[0] || selectAll('[id^="vsb_content"]', doc)[0];
  const heading = title && readableText(title);
  if (!heading || !body) throw new Error("xidian_notice_layout_changed");
  const content = readableText(body);
  const attachments = [];
  const seen = new Set();
  // JWC lists downloadable attachments beside the body, inside the article.
  for (const anchor of selectAll("a[href]", article || body)) {
    const href = getAttributeValue(anchor, "href");
    if (
      !href ||
      !/(?:\/system\/resource\/storage\/|\/download\.jsp(?:\?|$)|\.(?:pdf|docx?|xlsx?|zip)(?:[?#]|$))/i.test(
        href,
      )
    )
      continue;
    const name = readableText(anchor);
    if (!name) continue;
    const resolved = resolveUrl(href, url);
    if (!seen.has(resolved)) {
      attachments.push({ name, url: resolved });
      seen.add(resolved);
    }
  }
  return {
    id: params.id,
    title: heading,
    ...(content ? { content } : {}),
    ...(attachments.length ? { attachments } : {}),
  };
}
