// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// All payloads and identifiers are synthetic. No school requests or configuration.

import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

// Resolve the same built-in parser used by the client without replacing it
// with a mock DOM. Production packages keep elecon:html as a host import.
const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/campus.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const { cardBalance, cardTransactions, libraryLoans } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString("base64")}`
);

const NOW = Date.parse("2026-10-30T08:00:00Z");
const LIBRARY = "https://mfindxidian.libsp.cn";
const CARD_NO = "CARD-EXAMPLE-0001";

function response(url, data, { status = 200, headers = {} } = {}) {
  const body = typeof data === "string" ? data : JSON.stringify(data);
  return {
    url,
    status,
    ok: status >= 200 && status < 300,
    headers: {
      getSetCookie: () => headers["set-cookie"] || [],
      get: (name) => headers[String(name).toLowerCase()] || null,
    },
    text: async () => body,
    json: async () => JSON.parse(body),
  };
}

function context(service, data, handle, { cookies = [] } = {}) {
  const records = new Map([
    [
      service,
      {
        value: JSON.stringify({ version: 1, service, cookies, data, updatedAt: NOW }),
      },
    ],
  ]);
  const calls = [];
  const ctx = {
    now: () => NOW,
    log() {},
    credentials: {
      async get(key, address) {
        assert.equal(address.namespace, "xidian.auth");
        return records.get(key) || null;
      },
      async set(key, value, address) {
        assert.equal(address.namespace, "xidian.auth");
        records.set(key, { value });
      },
    },
    async fetch(url, init) {
      const call = { url: new URL(url), init, body: init.body ? JSON.parse(init.body) : undefined };
      calls.push(call);
      if (call.url.pathname === "/oga/userinfo") {
        assert.equal(init.method, "GET");
        assert.equal(call.url.searchParams.get("jwt"), data.token);
        assert.equal(init.headers.jwtOpacAuth, data.token);
        assert.ok(init.headers.Cookie.includes(`jwt=${data.token}`));
        assert.ok(init.headers.Cookie.includes("jwtHeader=jwtOpacAuth"));
        return response(url, { data: {} });
      }
      return handle(call);
    },
  };
  return { ctx, calls, saved: () => JSON.parse(records.get(service).value) };
}

function account(html = "账户余额：￥123.45") {
  return `<html><body>${html}</body></html>`;
}
function borrowed(overrides = {}) {
  return {
    loanId: 1001,
    propNo: "BOOK-EXAMPLE-001",
    title: "Synthetic title",
    loanDate: "2026/10/01",
    normReturnDate: "2026/11/01",
    renewTimes: 1,
    author: "Example author",
    locationName: "Example shelf",
    curLibName: "Example branch",
    ...overrides,
  };
}

test("card balance accepts explicit user card number and converts decimal money exactly", async () => {
  const env = context("card", { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW }, ({ url }) => {
    assert.equal(url.pathname, "/myaccount/openMyAccount");
    assert.equal(url.searchParams.get("openid"), "EXAMPLE_SYNTHETIC_OPENID");
    return response(url.href, account());
  });
  assert.deepEqual(await cardBalance(env.ctx, { cardNumber: CARD_NO }), {
    cardNumber: CARD_NO,
    balance: { amountMinor: 12345, currency: "CNY" },
  });
  assert.equal(env.saved().data.cardNumber, CARD_NO);
});

test("balance-only page omits card number and never substitutes student id", async () => {
  const env = context(
    "card",
    { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW, studentId: "EXAMPLE_SYNTHETIC_STUDENT" },
    ({ url }) => response(url.href, account()),
  );
  assert.deepEqual(await cardBalance(env.ctx), { balance: { amountMinor: 12345, currency: "CNY" } });
  assert.equal(env.saved().data.cardNumber, undefined);
  assert.equal(env.calls.length, 1); // Missing user input must not refresh OAuth.
});

test("balance supports the exact first-li element layout witnessed in the reference", async () => {
  const env = context("card", { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW }, ({ url }) =>
    response(url.href, "<ul><li><div>校园卡</div><div><p>金额</p><p>28.09</p></div></li></ul>"),
  );
  assert.equal((await cardBalance(env.ctx, { cardNumber: CARD_NO })).balance.amountMinor, 2809);
});

test("PDA account cell takes precedence over unrelated page amounts", async () => {
  const env = context("card", { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW }, ({ url }) =>
    response(
      url.href,
      "<p>上次充值：￥999.99</p><ul><li><div>校园卡</div><div><p>金额</p><p>28.09</p></div></li></ul>",
    ),
  );
  assert.equal((await cardBalance(env.ctx, { cardNumber: CARD_NO })).balance.amountMinor, 2809);
});

test("PDA account cell permits explicit currency units and preserves integer cents", async () => {
  for (const [amount, expected] of [
    ["￥ 28.09 元", 2809],
    ["1,234.56（元）", 123456],
    ["余额：¥-0.10元", -10],
  ]) {
    const env = context(
      "card",
      { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW },
      ({ url, init }) => {
        assert.match(init.headers["User-Agent"], /XDYou\/2.0.0/);
        return response(
          url.href,
          `<ul><li><div>校园卡</div><div><p>金额</p><p>${amount}</p></div></li></ul>`,
        );
      },
    );
    assert.equal((await cardBalance(env.ctx)).balance.amountMinor, expected);
  }
});

test("card openid comes from the official hidden field rather than a conflicting URL", async () => {
  const env = context("card", {}, ({ url }) => {
    if (url.pathname === "/home/openXDOAuth2Page")
      return response(
        `${url.href}?openid=EXAMPLE_SYNTHETIC_WRONG`,
        '<input type="hidden" id="openid" value="EXAMPLE_SYNTHETIC_CORRECT">',
      );
    assert.equal(url.searchParams.get("openid"), "EXAMPLE_SYNTHETIC_CORRECT");
    return response(url.href, account("账户余额：￥1.20"));
  });
  assert.equal((await cardBalance(env.ctx)).balance.amountMinor, 120);
});

test("card OAuth can follow the reference's bounded chain beyond eight hops", async () => {
  let hop = 0;
  const env = context("card", {}, ({ url }) => {
    if (url.pathname.startsWith("/myaccount/"))
      return response(url.href, account(`校园卡号：${CARD_NO}；账户余额：￥1.20`));
    if (++hop < 12)
      return response(url.href, "", {
        status: 302,
        headers: { location: `https://v8scan.xidian.edu.cn/oauth/hop-${hop}` },
      });
    return response(url.href, '<input type="hidden" id="openid" value="EXAMPLE_SYNTHETIC_OPENID">');
  });
  assert.equal((await cardBalance(env.ctx)).balance.amountMinor, 120);
  assert.equal(hop, 12);
});

test("factually labelled HTML card number is accepted and account JS is not parsed as facts", async () => {
  const env = context("card", { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW }, ({ url }) =>
    response(
      url.href,
      account(
        `<script>const fake='卡号：WRONG-CARD-0000';</script><a href='https://ids.xidian.edu.cn/authserver/login'>统一身份认证</a><p>校园卡号：${CARD_NO}</p><p>账户余额：¥1,234.56</p>`,
      ),
    ),
  );
  assert.deepEqual(await cardBalance(env.ctx), {
    cardNumber: CARD_NO,
    balance: { amountMinor: 123456, currency: "CNY" },
  });
});

test("card OAuth hidden openid can bootstrap saved card cookies without exposing native credentials", async () => {
  const env = context("card", {}, ({ url }) => {
    if (url.pathname === "/home/openXDOAuth2Page") {
      return response(url.href, '<input value="EXAMPLE_SYNTHETIC_OPENID" id="openid" type="hidden">');
    }
    return response(url.href, account(`校园卡号：${CARD_NO}；账户余额：￥-0.10`));
  });
  assert.equal((await cardBalance(env.ctx)).balance.amountMinor, -10);
  assert.equal(env.saved().data.openid, "EXAMPLE_SYNTHETIC_OPENID");
  assert.equal(env.saved().data.openidFetchedAt, NOW);
  assert.equal(env.calls.length, 2);
});

test("card date-window JSON API supports caller dates and local page slicing", async () => {
  const env = context(
    "card",
    { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW, cardNumber: CARD_NO },
    ({ url, init, body }) => {
      assert.equal(url.pathname, "/selftrade/queryCardSelfTradeList");
      assert.equal(init.method, "POST");
      assert.match(init.headers["Content-Type"], /application\/json/);
      assert.deepEqual(body, {
        beginDate: "2026-10-01",
        endDate: "2026-10-03",
        tradeType: "-1",
        openid: "EXAMPLE_SYNTHETIC_OPENID",
      });
      assert.equal(body.pageNo, undefined);
      return response(url.href, {
        success: true,
        resultData: [
          { id: "A", txdate: "2026-10-01 08:00:00", txamt: "-1.01", mername: "Example merchant" },
          { id: "B", txdate: "2026-10-02 09:00:00", txamt: "2.20", txname: "充值" },
          { id: "C", txdate: "2026-10-03 10:00:00", txamt: "-3.00" },
          { id: "OUTSIDE", txdate: "2026-09-30 23:59:59", txamt: "-9.99" },
        ],
      });
    },
  );
  const result = await cardTransactions(env.ctx, { from: "2026-10-01", to: "2026-10-03", page: 2, size: 1 });
  assert.equal(result.total, 3);
  assert.equal(result.hasNext, true);
  assert.equal(result.page, 2);
  assert.equal(result.items[0].transactionId, "B");
  assert.equal(result.items[0].time, "2026-10-02T01:00:00.000Z");
  assert.equal(result.items[0].direction, "credit");
  assert.equal(result.items[0].amountMinor, 220);
  assert.equal(result.windowStart, "2026-09-30T16:00:00.000Z");
  assert.equal(env.calls.length, 1);
});

test("card number configured in transactions is persisted for the next balance query", async () => {
  for (const supplied of [true, false]) {
    let afterTransactions = false;
    const env = context("card", { openid: "CURRENT", openidFetchedAt: NOW }, ({ url }) => {
      if (url.pathname === "/selftrade/queryCardSelfTradeList") return response(url.href, { resultData: [] });
      return response(
        url.href,
        account(afterTransactions || supplied ? "余额：￥12.34" : `卡号：${CARD_NO}；余额：￥12.34`),
      );
    });
    const transactions = await cardTransactions(env.ctx, supplied ? { cardNumber: CARD_NO } : {});
    assert.equal(env.saved().data.cardNumber, supplied ? CARD_NO : undefined);
    assert.equal(transactions.cardNumber, supplied ? CARD_NO : undefined);
    assert.equal(env.calls.length, 1);
    afterTransactions = true;
    assert.deepEqual(await cardBalance(env.ctx), {
      ...(supplied ? { cardNumber: CARD_NO } : {}),
      balance: { amountMinor: 1234, currency: "CNY" },
    });
  }
});

test("card refreshes five-minute or timestamp-less openid records before querying", async () => {
  for (const timestamp of [undefined, NOW - 5 * 60 * 1000]) {
    const env = context(
      "card",
      { openid: "OLD_OPENID", openidFetchedAt: timestamp, cardNumber: CARD_NO },
      ({ url }) => {
        if (url.pathname === "/home/openXDOAuth2Page")
          return response(url.href, '<input id="openid" type="hidden" value="NEW_OPENID">');
        assert.equal(url.searchParams.get("openid"), "NEW_OPENID");
        return response(url.href, account());
      },
    );
    assert.equal((await cardBalance(env.ctx)).balance.amountMinor, 12345);
    assert.deepEqual(
      env.calls.map(({ url }) => url.pathname),
      ["/home/openXDOAuth2Page", "/myaccount/openMyAccount"],
    );
    assert.equal(env.saved().data.openidFetchedAt, NOW);
    assert.equal(env.saved().data.openid, "NEW_OPENID");
  }
});

test("card read auth failure refreshes openid and retries once, never repeatedly", async () => {
  for (const succeeds of [true, false]) {
    let reads = 0;
    const env = context(
      "card",
      { openid: "OLD_OPENID", openidFetchedAt: NOW, cardNumber: CARD_NO },
      ({ url }) => {
        if (url.pathname === "/home/openXDOAuth2Page")
          return response(url.href, '<input id="openid" type="hidden" value="NEW_OPENID">');
        reads++;
        assert.equal(url.searchParams.get("openid"), reads === 1 ? "OLD_OPENID" : "NEW_OPENID");
        return reads === 2 && succeeds
          ? response(url.href, account())
          : response(url.href, "expired", { status: 403 });
      },
    );
    if (succeeds) assert.equal((await cardBalance(env.ctx)).balance.amountMinor, 12345);
    else await assert.rejects(cardBalance(env.ctx), /xidian_login_required_card/);
    assert.equal(reads, 2);
    assert.equal(env.calls.filter(({ url }) => url.pathname === "/home/openXDOAuth2Page").length, 1);
    assert.equal(env.saved().data.openid, "NEW_OPENID");
  }
});

test("card cancellation and invalid card number never refresh or replay queries", async () => {
  const env = context("card", { openid: "CURRENT", openidFetchedAt: NOW, cardNumber: CARD_NO }, () => {
    throw new Error("script_cancelled");
  });
  await assert.rejects(cardBalance(env.ctx), /script_cancelled/);
  assert.equal(env.calls.length, 1);
  await assert.rejects(cardBalance(env.ctx, { cardNumber: 123 }), /card_number_invalid/);
  assert.equal(env.calls.length, 1);
});

test("card source-only fields infer credit/debit and query failures refresh once", async () => {
  let reads = 0;
  const env = context(
    "card",
    { openid: "OLD", openidFetchedAt: NOW, cardNumber: CARD_NO },
    ({ url, body }) => {
      if (url.pathname === "/home/openXDOAuth2Page")
        return response(url.href, '<input id="openid" type="hidden" value="NEW">');
      reads++;
      if (reads === 1) return response(url.href, { success: false });
      assert.equal(body.openid, "NEW");
      // Exact three fields consumed by reference school_card_session.dart186–188.
      return response(url.href, {
        resultData: [
          { txdate: "2026-10-30 12:00:00", txamt: "10.00", mername: "Synthetic credit" },
          { txdate: "2026-10-30 13:00:00", txamt: "-2.00", mername: "Synthetic debit" },
        ],
      });
    },
  );
  const result = await cardTransactions(env.ctx);
  assert.deepEqual(
    result.items.map(({ direction, amountMinor }) => [direction, amountMinor]),
    [
      ["credit", 1000],
      ["debit", 200],
    ],
  );
  assert.equal(reads, 2);
  assert.equal(env.calls.length, 3);
});

test("card default window is bounded; invalid params and truncated legacy payloads fail", async () => {
  const env = context(
    "card",
    { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW, cardNumber: CARD_NO },
    ({ url, body }) => {
      assert.equal(body.beginDate, "2026-10-01");
      assert.equal(body.endDate, "2026-10-30");
      return response(url.href, { resultData: [] });
    },
  );
  assert.deepEqual((await cardTransactions(env.ctx)).items, []);
  for (const params of [{ from: "2026-02-30" }, { from: "2026-10-31", to: "2026-10-30" }, { page: "1" }]) {
    await assert.rejects(cardTransactions(env.ctx, params), /card_.*invalid/);
  }
  const incomplete = context(
    "card",
    { openid: "EXAMPLE_SYNTHETIC_OPENID", openidFetchedAt: NOW, cardNumber: CARD_NO },
    ({ url }) =>
      response(url.href, {
        resultData: { rows: [{ txamt: "-1", txdate: "2026-10-30 12:00:00" }], total: 2 },
      }),
  );
  await assert.rejects(cardTransactions(incomplete.ctx), /card_transactions_incomplete/);
});

test("new OPAC loans map exact source fields and paginate without per-book cover requests", async () => {
  const env = context(
    "library",
    { token: "EXAMPLE_SYNTHETIC_JWT", groupCode: "EXAMPLE_GROUP" },
    ({ url, init, body }) => {
      assert.equal(url.origin, LIBRARY);
      assert.equal(url.pathname, "/find/loanInfo/loanList");
      assert.equal(init.headers.jwtOpacAuth, "EXAMPLE_SYNTHETIC_JWT");
      assert.equal(init.headers.groupCode, "EXAMPLE_GROUP");
      assert.equal(init.headers.Referer, `${LIBRARY}/`);
      assert.equal(body.rows, 999);
      assert.equal(body.searchType, 1);
      assert.equal(body.startDate, null);
      const row = borrowed(
        body.page === 1 ? {} : { loanId: 1002, propNo: "", title: "Second title", renewTimes: 0 },
      );
      return response(url.href, { data: { searchResult: [row], total: 2 } });
    },
  );
  const result = await libraryLoans(env.ctx);
  assert.equal(result.items.length, 2);
  assert.deepEqual(result.items[0], {
    bookId: "BOOK-EXAMPLE-001",
    title: "Synthetic title",
    borrowedAt: "2026-10-01T00:00:00.000Z",
    dueAt: "2026-11-01T23:59:59.000Z",
    author: "Example author",
    location: "Example shelf",
    branch: "Example branch",
    renewCount: 1,
  });
  assert.equal(result.items[1].bookId, "1002");
  assert.deepEqual(
    env.calls.filter((call) => call.url.pathname === "/find/loanInfo/loanList").map((call) => call.body.page),
    [1, 2],
  );
});

test("missing OPAC group is fetched from actual endpoint and persisted rather than guessed", async () => {
  const env = context("library", { token: "EXAMPLE_SYNTHETIC_JWT" }, ({ url, init, body }) => {
    assert.equal(init.headers.jwtOpacAuth, "EXAMPLE_SYNTHETIC_JWT");
    if (url.pathname === "/find/homePage/getGroupCode") {
      assert.deepEqual(body, { mappingPath: "" });
      assert.equal(init.headers.groupCode, undefined);
      return response(url.href, { data: { groupCode: "FETCHED_GROUP" } });
    }
    assert.equal(init.headers.groupCode, "FETCHED_GROUP");
    return response(url.href, { data: { searchResult: [] } });
  });
  assert.deepEqual(await libraryLoans(env.ctx), { items: [] });
  assert.equal(env.saved().data.groupCode, "FETCHED_GROUP");
  assert.equal(env.calls.length, 3);
});

test("OPAC token absence and malformed loans are failures, not empty successful data", async () => {
  const missing = context("library", {}, () => {
    throw new Error("must not request without token");
  });
  await assert.rejects(libraryLoans(missing.ctx), /xidian_login_required_library/);
  for (const row of [
    borrowed({ loanDate: "" }),
    borrowed({ normReturnDate: "not a date" }),
    borrowed({ propNo: "", loanId: 0 }),
  ]) {
    const env = context("library", { token: "JWT", groupCode: "GROUP" }, ({ url }) =>
      response(url.href, {
        data: { searchResult: [row], total: 1 },
      }),
    );
    await assert.rejects(libraryLoans(env.ctx), /library_loan_|xidian_invalid_/);
  }
});

test("OPAC pagination detects repeated pages and hard limits instead of truncating", async () => {
  const repeated = context("library", { token: "JWT", groupCode: "GROUP" }, ({ url }) =>
    response(url.href, {
      data: { searchResult: [borrowed()] },
    }),
  );
  await assert.rejects(libraryLoans(repeated.ctx), /library_pagination_stalled/);
  const unbounded = context("library", { token: "JWT", groupCode: "GROUP" }, ({ url, body }) =>
    response(url.href, {
      data: { searchResult: [borrowed({ loanId: body.page, propNo: `BOOK-${body.page}` })] },
    }),
  );
  await assert.rejects(libraryLoans(unbounded.ctx), /library_pagination_limit/);
  assert.equal(unbounded.calls.filter((call) => call.url.pathname === "/find/loanInfo/loanList").length, 12);
});

test("OPAC remembered totals reject early empty pages even if later metadata is missing", async () => {
  for (const retainsTotal of [true, false]) {
    const env = context("library", { token: "JWT", groupCode: "GROUP" }, ({ url, body }) =>
      response(url.href, {
        data:
          body.page === 1
            ? { searchResult: [borrowed()], total: 2 }
            : { searchResult: [], ...(retainsTotal ? { total: 2 } : {}) },
      }),
    );
    await assert.rejects(libraryLoans(env.ctx), /library_pagination_incomplete/);
    assert.equal(env.calls.filter((call) => call.url.pathname === "/find/loanInfo/loanList").length, 2);
  }
});

test("OPAC changing totals are rejected rather than treated as a complete snapshot", async () => {
  const env = context("library", { token: "JWT", groupCode: "GROUP" }, ({ url, body }) =>
    response(url.href, {
      data: {
        searchResult: [borrowed({ loanId: body.page, propNo: `EXAMPLE_SYNTHETIC-${body.page}` })],
        total: body.page === 1 ? 3 : 2,
      },
    }),
  );
  await assert.rejects(libraryLoans(env.ctx), /library_pagination_changed/);
  assert.equal(env.calls.filter((call) => call.url.pathname === "/find/loanInfo/loanList").length, 2);
});
