// biome-ignore-all lint/suspicious/noControlCharactersInRegex: Reject control characters in remote protocol identifiers.
/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-066: independently implement the official PC notification frontend protocol.
// Protocol source and the restricted Quasar API are documented in ../README.md.
import { parseDocument } from "elecon:html";
import { requireParams, serviceError } from "../../xidian/src/service_session.js";
import { chaoxingClient } from "./account.js";

export const NOTICES_URL = "https://notice.chaoxing.com/pc/notice/getNoticeList";
function text(value, limit) {
  if (typeof value !== "string") return "";
  function walk(node) {
    if (node.type === "text") return node.data;
    const name = node.name?.toLowerCase();
    if (["script", "style", "noscript", "iframe"].includes(name)) return "";
    if (name === "br") return "\n";
    const value = (node.children || []).map(walk).join("");
    return /^(p|div|li|h[1-6]|section|article|tr)$/.test(name) ? `\n${value}\n` : value;
  }
  return walk(parseDocument(value.slice(0, 100000)))
    .replace(/[^\S\n]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .slice(0, limit);
}
function time(value) {
  if (
    (typeof value === "number" && Number.isSafeInteger(value)) ||
    (typeof value === "string" && /^[0-9]{13}$/.test(value))
  ) {
    const n = Number(value);
    if (n > 0 && n <= 8640000000000000) return new Date(n).toISOString();
  }
  // An unzoned local date cannot safely be assigned a timezone.
  if (typeof value === "string" && /^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(value)) {
    const n = Date.parse(value);
    if (Number.isFinite(n)) return new Date(n).toISOString();
  }
}
const PAGE_URL = "https://notice.chaoxing.com/pc/notice/myNotice";
const MAX_PAGES = 8;
function opaque(value, limit = 256) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= limit &&
    !/[\u0000-\u001f\u007f]/.test(value)
  );
}
function entityId(row) {
  if (!opaque(row.idCode)) throw serviceError();
  // The official frontend deduplicates by idCode + sendTag, not a numeric id.
  const tag = row.sendTag;
  if (
    tag !== undefined &&
    !(typeof tag === "number" && Number.isSafeInteger(tag)) &&
    !(typeof tag === "string" && tag.length <= 32 && !/[\u0000-\u001f\u007f]/.test(tag))
  )
    throw serviceError();
  return JSON.stringify([row.idCode, tag === undefined ? null : String(tag)]);
}
function rejectResponse(value) {
  const msg = typeof value?.msg === "string" ? value.msg : "";
  // Only confirmed authentication failures ask for login. Source ACL/risk/rate
  // failures do not revoke an otherwise valid account, and never echo the body.
  if (
    /未登录|请.{0,12}登录|登录.{0,12}(?:失效|过期)|not logged|unauthenticated|session.{0,12}expired/i.test(
      msg,
    )
  )
    throw serviceError("authentication_required");

  throw serviceError();
}
export async function noticeList(ctx, params = {}) {
  requireParams(params, ["page", "size", "category"]);
  const page = params.page ?? 1,
    size = params.size ?? 20;
  if (
    !Number.isSafeInteger(page) ||
    page < 1 ||
    !Number.isInteger(size) ||
    size < 1 ||
    size > 100 ||
    page * size > 160 ||
    (params.category !== undefined && !["academic", "admin", "event", "unknown"].includes(params.category))
  )
    throw serviceError("input_invalid_request");
  // Limit redirect classification to this read-only POST. serviceClient still
  // owns Cookie scope, Set-Cookie, origins and the no-POST-replay boundary.
  const { client } = await chaoxingClient({
    ...ctx,
    fetch: async (url, init) => {
      const response = await ctx.fetch(url, init);
      if (url === NOTICES_URL && response.status >= 300 && response.status < 400) {
        const location = response.headers.get("location") || "";
        if (/^https:\/\/passport2\.chaoxing\.com\/(?:login|fanyalogin)(?:[/?#]|$)/.test(location))
          throw serviceError("authentication_required");
        throw serviceError("source_response_invalid");
      }
      return response;
    },
  });
  const year = new Date(ctx.now() + 8 * 60 * 60 * 1000).getUTCFullYear();
  const items = new Map();
  const seenCursors = new Set();
  let lastValue = "",
    hasMore;
  for (let requestPage = 0; requestPage < MAX_PAGES; requestPage++) {
    const query = {
      type: "2",
      notice_type: "",
      lastValue,
      sort: "",
      folderUUID: "",
      kw: "",
      startTime: "",
      endTime: "",
      gKw: "",
      gName: "",
      year,
      tag: "",
      fidsCode: "",
      queryFolderNoticePrevYear: "0",
      filterSenderPuids: "",
      filterTags: "",
    };
    const response = await client.request(NOTICES_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-Requested-With": "XMLHttpRequest",
        Referer: PAGE_URL,
      },
      body: Object.entries(query)
        .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
        .join("&"),
    });
    if (response.status === 401) throw serviceError("authentication_required");
    if (response.status === 429) throw serviceError("source_response_invalid");
    if (!response.ok) throw serviceError("source_response_invalid");
    const raw = await response.text();
    if (raw.length > 1024 * 1024) throw serviceError();
    let value;
    try {
      value = JSON.parse(raw);
    } catch {
      throw serviceError();
    }
    if (value?.status !== true) rejectResponse(value);
    const ordinary = value.notices?.list;
    const pinned = value.topNotices ?? [];
    const urgent = value.urgentNotices ?? [];
    if (![ordinary, pinned, urgent].every((list) => Array.isArray(list) && list.length <= 200))
      throw serviceError();
    for (const [list, isPinned, isUrgent] of [
      [pinned, true, false],
      [urgent, false, true],
      [ordinary, false, false],
    ]) {
      for (const row of list) {
        if (!row || typeof row !== "object" || Array.isArray(row)) throw serviceError();
        const id = entityId(row);
        if (items.has(id)) continue;
        const title = text(row.title, 1000) || "学习通知";
        const content = text(row.content, 50000);
        const author = text(row.createrName, 160);
        const course = text(row.course_name, 160);
        const category =
          ["homework", "topicDiscuss"].includes(row.tag) || course
            ? "academic"
            : [4000, 4001, 4002].includes(row.sourceType)
              ? "admin"
              : "unknown";
        const publishedAt = time(row.sendTime) ?? time(row.insertTime);
        items.set(id, {
          id,
          title,
          category,
          source: "学习通",
          pinned: isPinned,
          ...(isUrgent ? { importance: "urgent" } : {}),
          ...(content ? { content, summary: content.slice(0, 240) } : {}),
          ...(author ? { author } : {}),
          ...(course ? { tags: [course] } : {}),
          ...(publishedAt ? { publishedAt } : {}),
        });
      }
    }
    const lastPage = value.notices.lastPage;
    hasMore =
      lastPage === true || lastPage === 1 ? false : lastPage === false || lastPage === 0 ? true : undefined;
    if (items.size >= page * size || hasMore === false || (page === 1 && size <= 20)) break;
    const next = value.notices.lastGetId;
    // A short page alone is not completion. Missing/looping cursor cannot
    // silently turn an incomplete requested page into an empty success.
    if (!opaque(next, 2048) || seenCursors.has(next)) {
      if (hasMore === undefined && page === 1 && requestPage === 0) break;
      throw serviceError();
    }
    seenCursors.add(next);
    lastValue = next;
    if (requestPage === MAX_PAGES - 1) throw serviceError("source_response_invalid");
  }
  const all = [...items.values()];
  return {
    page,
    size,
    sourceSystem: "chaoxing-notice",
    ...(all.length > page * size ? { hasNext: true } : hasMore === undefined ? {} : { hasNext: hasMore }),
    items: all
      .slice((page - 1) * size, page * size)
      .filter((row) => !params.category || row.category === params.category),
  };
}
