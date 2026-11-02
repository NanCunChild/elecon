/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-066: independent implementation of notice.go protocol facts in
// Quasar-core 96f36b38a2b01b810a2b45d66f0364183a4b7b87 (GPL-3.0).
import { parseDocument } from "elecon:html";
import { remoteId, requireParams, serviceError } from "../../xidian/src/service_session.js";
import { chaoxingClient } from "./account.js";

export const NOTICES_URL = "https://notice.chaoxing.com/apis/notice/myNotices_v2";
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
export async function noticeList(ctx, params = {}) {
  requireParams(params, ["page", "size", "category"]);
  const page = params.page ?? 1,
    size = params.size ?? 20;
  if (
    !Number.isSafeInteger(page) ||
    page < 1 ||
    page > 10000 ||
    !Number.isInteger(size) ||
    size < 1 ||
    size > 100 ||
    (params.category !== undefined && !["academic", "admin", "event", "unknown"].includes(params.category))
  )
    throw serviceError("input_invalid_request");
  const { client, account } = await chaoxingClient(ctx);
  const query = {
    puid: account.id,
    lastGetId: "",
    type: "",
    notice_type: "",
    from: "",
    folderId: "",
    read: "",
    kw: "",
    tag: "",
    pageSize: size,
    page: page - 1,
    mMaxW: "10",
    contSize: "30",
  };
  const response = await client.request(
    `${NOTICES_URL}?${Object.entries(query)
      .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
      .join("&")}`,
  );
  if ([401, 403].includes(response.status)) throw serviceError("authentication_required");
  if (!response.ok) throw serviceError();
  const raw = await response.text();
  if (raw.length > 1024 * 1024) throw serviceError();
  let value;
  try {
    value = JSON.parse(raw.replace(/("id"\s*:\s*)([0-9]+)(?=\s*[,}])/g, '$1"$2"'));
  } catch {
    throw serviceError();
  }
  const data = value?.data;
  if (value?.result !== 1 || !data || typeof data !== "object") throw serviceError();
  const ordinary = Array.isArray(data.notices) ? data.notices : data.notices?.list;
  const pinned = data.topNotices ?? [];
  if (!Array.isArray(ordinary) || !Array.isArray(pinned) || ordinary.length > 200 || pinned.length > 200)
    throw serviceError();
  const items = new Map();
  for (const [list, isPinned] of [
    [pinned, true],
    [ordinary, false],
  ]) {
    for (const row of list) {
      if (!row || typeof row !== "object") throw serviceError();
      const id = remoteId(row.id);
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
        ...(content ? { content, summary: content.slice(0, 240) } : {}),
        ...(author ? { author } : {}),
        ...(course ? { tags: [course] } : {}),
        ...(publishedAt ? { publishedAt } : {}),
      });
    }
  }
  // Neither a short page nor lastGetId proves completeness. Do not invent
  // hasNext/total; do not mark notifications read while listing or caching.
  return {
    page,
    size,
    sourceSystem: "chaoxing-notice",
    items: [...items.values()].filter((row) => !params.category || row.category === params.category),
  };
}
