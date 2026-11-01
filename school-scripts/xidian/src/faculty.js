/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { parseDocument } from "elecon:html";
import { parseUrl, resolveUrl } from "./session.js";

const ORIGIN = "https://faculty.xidian.edu.cn";
// Public homepage tsites_load_data_options, observed 2026-11-01. These are
// public component identifiers, not authentication tokens. No remote JS runs.
const SEARCH = `${ORIGIN}/system/resource/tsites/advancesearch.jsp`;

function invalidResponse() {
  const error = new Error("xidian_faculty_response_invalid");
  error.code = "source_response_invalid";
  return error;
}

function textNode(node) {
  if (node.type === "text") return node.data;
  if (["script", "style", "noscript"].includes(node.name?.toLowerCase())) return "";
  const content = (node.children || []).map(textNode).join("");
  return /^(p|div|br|li|section|h[1-6])$/.test(node.name || "") ? `${content}\n` : content;
}

function plain(value, maxLength) {
  if (value == null || value === "") return undefined;
  if (typeof value !== "string") throw invalidResponse();
  const result = textNode(parseDocument(value)).replace(/\s+/g, " ").trim();
  return result ? result.slice(0, maxLength) : undefined;
}

function profileUrl(value) {
  if (value == null || value === "") return undefined;
  let parsed;
  try {
    parsed = parseUrl(resolveUrl(value, `${ORIGIN}/`));
  } catch {
    throw invalidResponse();
  }
  if (
    ![ORIGIN, "http://faculty.xidian.edu.cn"].includes(parsed.origin) ||
    !/^\/[A-Za-z0-9_-]+\/zh_CN\/(?:index|index\/\d+)\.htm$/.test(parsed.path)
  )
    throw invalidResponse();
  // Some school records still contain an HTTP URL; this host serves HTTPS.
  return `${ORIGIN}${parsed.path}`;
}

function teacher(row) {
  if (!row || typeof row !== "object" || Array.isArray(row)) throw invalidResponse();
  if (!Number.isSafeInteger(row.teacherId) || row.teacherId <= 0) throw invalidResponse();
  const name = plain(row.teacherName || row.showName || row.name, 200);
  if (!name) throw invalidResponse();
  const result = { id: String(row.teacherId), name };
  const fields = {
    department: plain(row.collegeName || row.unit, 500),
    title: plain(row.prorank, 200),
    summary: plain(row.profileSummary || row.profile, 2000),
    profileUrl: profileUrl(row.url),
  };
  for (const [key, value] of Object.entries(fields)) if (value) result[key] = value;
  const disciplines = plain(row.discipline, 10000)
    ?.split(/[,，、]/)
    .map((value) => value.trim().slice(0, 200))
    .filter(Boolean);
  if (disciplines?.length) result.disciplines = [...new Set(disciplines)].slice(0, 50);
  if (row.researchDirectionList != null) {
    if (!Array.isArray(row.researchDirectionList)) throw invalidResponse();
    const researchAreas = row.researchDirectionList
      .map((entry) => {
        if (!entry || typeof entry !== "object") throw invalidResponse();
        return plain(entry.researchDirectionTitle || entry.researchDirectionShowTitle, 500);
      })
      .filter(Boolean);
    if (researchAreas.length) result.researchAreas = [...new Set(researchAreas)].slice(0, 50);
  }
  return result;
}

/** Public directory lookup: no cookie jar, credential access or automatic paging. */
export async function facultySearch(ctx, params = {}) {
  const allowed = new Set(["query", "researchArea", "page", "pageSize"]);
  if (Object.keys(params).some((key) => !allowed.has(key))) throw new Error("xidian_faculty_invalid_params");
  for (const key of ["query", "researchArea"]) {
    if (
      Object.hasOwn(params, key) &&
      (typeof params[key] !== "string" || !params[key].trim() || params[key].length > 80)
    )
      throw new Error("xidian_faculty_invalid_params");
  }
  const query = params.query?.trim() || "";
  const researchArea = params.researchArea?.trim() || "";
  const page = Object.hasOwn(params, "page") ? params.page : 1;
  const pageSize = Object.hasOwn(params, "pageSize") ? params.pageSize : 10;
  if (
    (!query && !researchArea) ||
    !Number.isInteger(page) ||
    page < 1 ||
    page > 1000 ||
    !Number.isInteger(pageSize) ||
    pageSize < 1 ||
    pageSize > 20
  )
    throw new Error("xidian_faculty_invalid_params");
  const fields = {
    collegeid: 0,
    disciplineid: 0,
    enrollid: 0,
    pageindex: page,
    pagesize: pageSize,
    rankid: 0,
    degreeid: 0,
    honorid: 0,
    py: "",
    profilelen: 1000,
    teacherName: query,
    searchDirection: researchArea,
    viewmode: 8,
    viewid: 125262,
    siteOwner: 2124906779,
    viewUniqueId: 125262,
    showlang: "zh_CN",
    ispreview: false,
    basenum: 0,
    ellipsis: "...",
    alignright: false,
    productType: 0,
    tutorType: "",
  };
  const encoded = Object.entries(fields)
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join("&");
  const response = await ctx.fetch(`${SEARCH}?${encoded}`, { redirect: "error" });
  if (!response.ok) throw invalidResponse();
  let raw;
  try {
    raw = await response.json();
  } catch {
    throw invalidResponse();
  }
  if (
    !raw ||
    raw.pageindex !== page - 1 ||
    !Array.isArray(raw.teacherData) ||
    raw.teacherData.length > pageSize ||
    !Number.isSafeInteger(raw.totalnum) ||
    raw.totalnum < raw.teacherData.length ||
    !Number.isSafeInteger(raw.totalpage) ||
    raw.totalpage < 1
  )
    throw invalidResponse();
  const items = raw.teacherData.map(teacher);
  if (new Set(items.map((item) => item.id)).size !== items.length) throw invalidResponse();
  return {
    items,
    page,
    pageSize,
    total: raw.totalnum,
    hasMore: items.length > 0 && page < raw.totalpage,
    sourceSystem: "xidian-faculty",
    sourceUrl: `${ORIGIN}/`,
  };
}
