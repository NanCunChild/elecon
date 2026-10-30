// Copyright 2023-2025 BenderBlog Rodriguez and contributors
// Copyright 2025 Traintime PDA authors.
// Copyright 2026 elecon contributors.
// SPDX-License-Identifier: MPL-2.0
// Protocols and OPAC field mappings adapted from traintime_pda's
// school_card_session.dart and library_session.dart. No reference configuration,
// live credentials, payment QR, renewal, or device-write operation is included.

import { getChildren, getText, isTag, parseDocument, selectAll } from "elecon:html";
import { failure } from "./errors.js";
import { dateOnly, integer, moneyMinor, schoolDateTime, text } from "./normalize.js";
import { PDA_UA } from "./pda_constants.js";
import { createClient, mergeCookies, normalizeBrowserCookies } from "./session.js";

const CARD = "https://v8scan.xidian.edu.cn";
const LIBRARY = "https://mfindxidian.libsp.cn";
const DAY_MS = 24 * 60 * 60 * 1000;
const LOAN_PAGE_SIZE = 999;
const MAX_LOAN_PAGES = 12;
const OPENID_TTL_MS = 5 * 60 * 1000;

function fail(code) {
  throw failure(code);
}

function decodeHTML(value) {
  return String(value).replace(/&(?:nbsp|amp|lt|gt|quot|apos|yen|#\d+|#x[0-9a-f]+);/gi, (entity) => {
    const named = {
      "&nbsp;": " ",
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": '"',
      "&apos;": "'",
      "&yen;": "¥",
    };
    const normalized = entity.toLowerCase();
    if (named[normalized] !== undefined) return named[normalized];
    const hex = normalized.startsWith("&#x");
    const code = parseInt(normalized.slice(hex ? 3 : 2, -1), hex ? 16 : 10);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : "";
  });
}

function pageText(html) {
  return decodeHTML(
    String(html)
      .replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, " ")
      .replace(/<[^>]*>/g, " "),
  )
    .replace(/\s+/g, " ")
    .trim();
}

function hiddenInput(html, id) {
  for (const tag of String(html).match(/<input\b[^>]*>/gi) || []) {
    const attrs = {};
    for (const match of tag.matchAll(/([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
      attrs[match[1].toLowerCase()] = decodeHTML(match[2] ?? match[3] ?? match[4]);
    }
    if (attrs.id === id && String(attrs.type || "").toLowerCase() === "hidden") return attrs.value || "";
  }
  return "";
}

async function responseText(response, code) {
  if (!response.ok) fail(code);
  const html = await response.text();
  const visible = pageText(html);
  if (
    /^https:\/\/ids\.xidian\.edu\.cn(?:[/:]|$)/i.test(response.url || "") ||
    (/统一身份认证/.test(visible) &&
      !/(?:账户余额|卡余额|余额)/.test(visible) &&
      !hiddenInput(html, "openid"))
  )
    fail(code);
  return html;
}

async function cardClient(ctx) {
  // PDA followIDSRedirects permits 30 school hops. Host request/time budgets
  // still apply, and each hop retains the shared origin/cookie/replay checks.
  const client = await createClient(ctx, "card", { maxRedirects: 30, userAgent: PDA_UA });
  const fetchedAt = client.session.data.openidFetchedAt;
  const age = ctx.now() - fetchedAt;
  if (!text(client.session.data.openid) || !Number.isFinite(fetchedAt) || age < 0 || age >= OPENID_TTL_MS)
    await refreshOpenId(ctx, client);
  return client;
}

async function refreshOpenId(ctx, client) {
  client.log("info", "xidian_card_stage:openid_start");
  const response = await client.request(`${CARD}/home/openXDOAuth2Page`);
  const html = await responseText(response, "xidian_login_required_card");
  // PDA school_card_session.dart uses the authenticated page's hidden field,
  // not a possibly stale intermediary's URL parameter.
  const openid = hiddenInput(html, "openid");
  if (!openid) fail("xidian_login_required_card");
  client.session.data.openid = openid;
  client.session.data.openidFetchedAt = ctx.now();
  await client.save();
  client.log("info", "xidian_card_stage:openid_ready");
}

async function cardQuery(ctx, client, action) {
  try {
    return await action();
  } catch (error) {
    // Source school_card_session.dart _withOpenIdRetry: refresh once after a
    // failed read. Input, output-normalization, cancellation and budget errors
    // are not authentication attempts and must not trigger another request.
    const retryable = [
      "xidian_login_required_card",
      "xidian_http_failed",
      "xidian_non_json_response",
      "card_balance_missing",
      "card_transactions_failed",
      "card_transactions_invalid",
      "connection_failed",
      "request_timeout",
    ];
    if (!retryable.includes(error?.message)) throw error;
    await refreshOpenId(ctx, client);
    return action();
  }
}

function explicitCardNumber(params, session, html = "") {
  let value;
  if (params.cardNumber !== undefined) {
    if (typeof params.cardNumber !== "string") fail("card_number_invalid");
    value = params.cardNumber.trim();
    if (!value || value.length > 128 || Array.from(value).some((char) => char.charCodeAt(0) < 32))
      fail("card_number_invalid");
    return value;
  }
  value = text(session.data.cardNumber);
  if (value) return value;
  // These labels identify a card number; account/student ids are never guessed.
  const content = pageText(html);
  return (
    /(?:校园卡号|卡号|卡账户)\s*[：:]?\s*([A-Za-z0-9-]{4,32})/.exec(content)?.[1] ||
    /card\s*(?:number|no\.?)\s*[：:]?\s*([A-Za-z0-9-]{4,32})/i.exec(content)?.[1] ||
    ""
  );
}

function cardMoney(value) {
  const raw = text(value);
  if (raw.includes(",") && !/^[+-]?\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?$/.test(raw)) fail("card_money_invalid");
  return moneyMinor(raw.replace(/,/g, ""));
}

function balanceMinor(html, log) {
  // Match PDA _fetchOverview's selected account cell before considering page
  // labels; unrelated wallet/transaction amounts elsewhere are not a balance.
  const first = selectAll("li", parseDocument(html))[0];
  const group = first && getChildren(first).filter(isTag)[1];
  const cell = group && getChildren(group).filter(isTag)[1];
  const value = cell && getText(cell).trim();
  const cellAmount =
    /^(?:(?:账户余额|卡余额|余额|金额)[：:]?)?(?:人民币|CNY|RMB|¥|￥)?([+-]?[0-9][0-9,]*(?:\.\d{1,2})?)(?:元|[（(]元[）)]|CNY|RMB)?$/i.exec(
      (value || "").replace(/\s+/g, ""),
    );
  if (cellAmount) return cardMoney(cellAmount[1]);
  const content = pageText(html);
  const amount =
    /(?:账户余额|卡余额|余额)\s*[：:]?\s*(?:CNY|RMB|¥|￥)?\s*(-?[0-9][0-9,]*(?:\.\d{1,2})?)/i.exec(
      content,
    )?.[1];
  if (amount) return cardMoney(amount);
  log?.(
    "warn",
    `xidian_card_balance_shape:${first ? "li" : "no_li"}:${group ? "group" : "no_group"}:${cell ? "cell" : "no_cell"}:${/[0-9]/.test(value || "") ? "digits" : "no_digits"}:${/元/.test(value || "") ? "yuan" : "no_yuan"}`,
  );
  fail("card_balance_missing");
}

/** ADR-036: account reads do not require or invent a physical card number. */
export async function cardBalance(ctx, params = {}) {
  if (params.cardNumber !== undefined) explicitCardNumber(params, { data: {} });
  const client = await cardClient(ctx);
  return cardQuery(ctx, client, async () => {
    client.log("info", "xidian_card_stage:account_start");
    const response = await client.request(
      `${CARD}/myaccount/openMyAccount?openid=${encodeURIComponent(client.session.data.openid)}`,
    );
    const html = await responseText(response, "xidian_login_required_card");
    const cardNumber = explicitCardNumber(params, client.session, html);
    const amountMinor = balanceMinor(html, client.log);
    client.log("info", "xidian_card_stage:account_ready");
    if (cardNumber && client.session.data.cardNumber !== cardNumber) {
      client.session.data.cardNumber = cardNumber;
      await client.save();
    }
    return { ...(cardNumber ? { cardNumber } : {}), balance: { amountMinor, currency: "CNY" } };
  });
}

function day(value, code) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) fail(code);
  const stamp = Date.parse(`${value}T00:00:00Z`);
  if (!Number.isFinite(stamp) || new Date(stamp).toISOString().slice(0, 10) !== value) fail(code);
  return value;
}

function cardWindow(ctx, params) {
  const today = new Date(ctx.now() + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const to = params.to === undefined ? today : day(params.to, "card_to_invalid");
  const from =
    params.from === undefined
      ? new Date(Date.parse(`${to}T00:00:00Z`) - 29 * DAY_MS).toISOString().slice(0, 10)
      : day(params.from, "card_from_invalid");
  if (from > to) fail("card_date_range_invalid");
  return { from, to };
}

function transaction(row) {
  if (!row || typeof row !== "object") fail("card_transaction_invalid");
  const signed = cardMoney(row.txamt);
  const type = text(row.txname ?? row.tradeType);
  let direction = "unknown";
  if (/退款/.test(type)) direction = "refund";
  else if (/冲正|撤销/.test(type)) direction = "reversal";
  else if (/补助|补贴/.test(type)) direction = "subsidy";
  else if (/充值|入账|转入|收入/.test(type)) direction = "credit";
  else if (/消费|扣款|支出/.test(type) || signed < 0) direction = "debit";
  else if (signed > 0) direction = "credit";
  const result = {
    time: schoolDateTime(row.txdate),
    amountMinor: Math.abs(signed),
    currency: "CNY",
    direction,
  };
  if (text(row.mername)) result.merchant = text(row.mername);
  if (text(row.id)) result.transactionId = text(row.id);
  if (type) result.type = type;
  return result;
}

/** The source returns a date-window array; page/size are applied locally. */
export async function cardTransactions(ctx, params = {}) {
  const { from, to } = cardWindow(ctx, params);
  const page = params.page ?? 1;
  const size = params.size ?? 20;
  if (
    !Number.isSafeInteger(page) ||
    page < 1 ||
    !Number.isSafeInteger(size) ||
    size < 1 ||
    !Number.isSafeInteger(page * size)
  ) {
    fail("card_pagination_invalid");
  }
  if (params.cardNumber !== undefined) explicitCardNumber(params, { data: {} });
  const client = await cardClient(ctx);
  return cardQuery(ctx, client, async () => {
    const cardNumber = explicitCardNumber(params, client.session);
    if (cardNumber && client.session.data.cardNumber !== cardNumber) {
      client.session.data.cardNumber = cardNumber;
      await client.save();
    }
    const payload = await client.postJSON(
      `${CARD}/selftrade/queryCardSelfTradeList?openid=${encodeURIComponent(client.session.data.openid)}`,
      {
        beginDate: from,
        endDate: to,
        tradeType: "-1",
        openid: client.session.data.openid,
      },
    );
    if (!payload || payload.success === false) fail("card_transactions_failed");
    const source = payload.resultData;
    const rows = Array.isArray(source) ? source : source?.rows;
    if (!Array.isArray(rows)) fail("card_transactions_invalid");
    if (
      !Array.isArray(source) &&
      source.total !== undefined &&
      integer(source.total, "card_total_invalid") > rows.length
    ) {
      fail("card_transactions_incomplete");
    }
    const all = rows.map(transaction).filter((item) => {
      const date = new Date(Date.parse(item.time) + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);
      return date >= from && date <= to;
    });
    return {
      ...(cardNumber ? { cardNumber } : {}),
      page,
      size,
      total: all.length,
      hasNext: page * size < all.length,
      windowStart: schoolDateTime(`${from} 00:00:00`),
      windowEnd: schoolDateTime(`${to} 23:59:59`),
      items: all.slice((page - 1) * size, page * size),
    };
  });
}

function libraryHeaders(client) {
  const token = text(client.session.data.token);
  if (!token) fail("xidian_login_required_library");
  const headers = {
    "Content-Type": "application/json;charset=utf-8",
    Referer: `${LIBRARY}/`,
    jwtOpacAuth: token,
    mappingPath: "",
  };
  if (text(client.session.data.groupCode)) headers.groupCode = text(client.session.data.groupCode);
  return headers;
}

async function libraryJSON(client, path, data) {
  const response = await client.request(`${LIBRARY}${path}`, {
    method: "POST",
    headers: libraryHeaders(client),
    body: JSON.stringify(data),
  });
  if (!response.ok) fail("library_query_failed");
  return response.json();
}

async function libraryClient(ctx) {
  const client = await createClient(ctx, "library");
  libraryHeaders(client); // Explicitly require the JWT collected by login.js.
  // The reference sends both the OPAC JWT header and these cookie names. A
  // token collected from the login URL may not yet exist as a native cookie.
  const token = client.session.data.token;
  client.session.cookies = mergeCookies(
    client.session.cookies,
    normalizeBrowserCookies(`${LIBRARY}/`, [
      { name: "jwt", value: token, path: "/", isSecure: true },
      { name: "jwtHeader", value: "jwtOpacAuth", path: "/", isSecure: true },
    ]),
  );
  await client.save();
  // Witnessed best-effort SSO warm-up; a temporary failure does not turn an
  // otherwise authenticated loan response into an invented empty list.
  try {
    await client.request(`${LIBRARY}/oga/userinfo?jwtHeader=jwtOpacAuth&jwt=${encodeURIComponent(token)}`, {
      headers: libraryHeaders(client),
    });
  } catch (_) {
    /* The authoritative read below reports authentication errors. */
  }
  if (!text(client.session.data.groupCode)) {
    const response = await libraryJSON(client, "/find/homePage/getGroupCode", { mappingPath: "" });
    const groupCode = text(response?.data?.groupCode);
    if (!groupCode) fail("library_group_code_required");
    client.session.data.groupCode = groupCode;
    await client.save();
  }
  return client;
}

function libraryDate(value, endOfDay = false) {
  const raw = text(value).replace(/\//g, "-");
  if (!raw) fail("library_loan_date_missing");
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(raw)) {
    const valid = dateOnly(raw);
    // contract/library.loans: date-only borrow=00:00Z; due=23:59:59Z.
    return `${valid}T${endOfDay ? "23:59:59" : "00:00:00"}.000Z`;
  }
  return schoolDateTime(raw);
}

function loan(row) {
  const barcode = text(row.propNo);
  const loanId = text(row.loanId);
  const bookId = barcode || (loanId && loanId !== "0" ? loanId : "");
  if (!bookId) fail("library_loan_id_missing");
  const title = text(row.title);
  if (!title) fail("library_loan_title_missing");
  const result = {
    bookId,
    title,
    borrowedAt: libraryDate(row.loanDate),
    dueAt: libraryDate(row.normReturnDate, true),
  };
  if (text(row.author)) result.author = text(row.author);
  if (text(row.locationName)) result.location = text(row.locationName);
  if (text(row.curLibName)) result.branch = text(row.curLibName);
  if (row.renewTimes !== undefined && row.renewTimes !== null && row.renewTimes !== "") {
    const count = integer(row.renewTimes, "library_renew_count_invalid");
    if (count < 0) fail("library_renew_count_invalid");
    result.renewCount = count;
  }
  return result;
}

/** Read-only new OPAC loan list. Cover lookups are intentionally not fan-out. */
export async function libraryLoans(ctx, _params = {}) {
  const client = await libraryClient(ctx);
  const raw = [];
  const ids = new Set();
  let expectedTotal = null;
  for (let page = 1; page <= MAX_LOAN_PAGES; page++) {
    const payload = await libraryJSON(client, "/find/loanInfo/loanList", {
      page,
      rows: LOAN_PAGE_SIZE,
      searchType: 1,
      searchContent: "",
      sortType: 0,
      startDate: null,
      endDate: null,
    });
    const data = payload?.data;
    const rows = data?.searchResult;
    if (!Array.isArray(rows)) fail("library_loans_invalid");
    if (data.total !== undefined && data.total !== null) {
      const total = integer(data.total, "library_total_invalid");
      if (total < 0) fail("library_total_invalid");
      if (expectedTotal !== null && total !== expectedTotal) fail("library_pagination_changed");
      expectedTotal = total;
    }
    if (!rows.length) {
      if (expectedTotal !== null && raw.length < expectedTotal) fail("library_pagination_incomplete");
      return { items: raw.map(loan) };
    }
    for (const row of rows) {
      if (!row || typeof row !== "object" || Array.isArray(row)) fail("library_loan_invalid");
      const loanId = text(row.loanId);
      const id = loanId && loanId !== "0" ? loanId : text(row.propNo);
      if (!id) fail("library_loan_id_missing");
      if (ids.has(id)) fail("library_pagination_stalled");
      ids.add(id);
      raw.push(row);
    }
    if (expectedTotal !== null) {
      if (expectedTotal < raw.length) fail("library_total_invalid");
      if (expectedTotal === raw.length) return { items: raw.map(loan) };
    }
  }
  fail("library_pagination_limit");
}
