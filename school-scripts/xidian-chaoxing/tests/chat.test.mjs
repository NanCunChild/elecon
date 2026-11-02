import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { ACCOUNT_URL } from "../src/account.js";
import { messagesConversations, messagesHistory, messagesSend } from "../src/chat.js";
import { decode, encode, one, str, sub } from "../src/protobuf.js";

const ajv = new Ajv2020({ strict: true, addUsedSchema: false });
addFormats(ajv);
function valid(cap, data) {
  const validator = ajv.compile(
    JSON.parse(readFileSync(new URL(`../../../contract/schema/${cap}.schema.json`, import.meta.url))),
  );
  assert.equal(validator(data), true, JSON.stringify(validator.errors));
}
const target = { accountId: "123456", conversationId: "789012", conversationKind: "group" };
const jid = (id) => encode([[2, id]]);
function message({
  id = 9007199254740993n,
  from = "456789",
  to = "789012",
  type = 2,
  content = 0,
  text = "Synthetic text",
  recalled,
  attachment,
  ns = 2,
} = {}) {
  return encode([
    [1, id],
    [2, jid(from)],
    [3, jid(to)],
    [4, 1800000000000n + (id % 100n)],
    [5, ns],
    [
      6,
      encode([
        [1, type],
        [2, jid(from)],
        [3, jid(to)],
        [
          4,
          encode([
            [1, content],
            [2, text],
          ]),
        ],
        ...(recalled ? [[6, recalled]] : []),
        ...(attachment
          ? [
              [
                5,
                encode([
                  [1, "attachment"],
                  [6, JSON.stringify(attachment)],
                ]),
              ],
            ]
          : []),
      ]),
    ],
  ]);
}
const encoded = (bytes) => ({ msg: Buffer.from(bytes).toString("base64") });
const provision = (code = 0) =>
  encode([
    [8, 3],
    [9, encode([[8, encode([[1, code]])]])],
  ]);
const ack = (clientId, code = 0) =>
  encode([
    [8, 0],
    [
      9,
      encode([
        [1, encode([[1, code]])],
        [2, BigInt(clientId)],
        [3, 9007199254740999n],
        [8, 1800000000100n],
      ]),
    ],
  ]);
function harness({
  history,
  groups = [{ groupid: "789012", groupname: "Synthetic group" }],
  contacts = ["456780"],
  fail,
  events = [],
} = {}) {
  const records = new Map([
    [
      "chaoxing",
      JSON.stringify({
        version: 1,
        serviceId: "chaoxing",
        accountId: "123456",
        accountLabel: "Synthetic",
        cookies: [
          { name: "SESSION", value: "SYNTHETIC_COOKIE", domain: "chaoxing.com", path: "/", isSecure: true },
        ],
      }),
    ],
  ]);
  const calls = [],
    sent = [];
  let closed = 0,
    now = 1800000000000;
  const ctx = {
    now: () => now++,
    credentials: {
      get: async (k) => (records.has(k) ? { value: records.get(k) } : null),
      set: async (k, v) => records.set(k, v),
      delete: async (k) => records.delete(k),
    },
    fetch: async (url, init) => {
      calls.push({ url, init });
      const path = new URL(url).pathname;
      if (fail?.(url)) throw new Error("SYNTHETIC_FAILURE");
      let body;
      if (url === ACCOUNT_URL)
        body = {
          msg: { puid: 123456, uid: 456789, fid: 789012, name: "Synthetic", hxToken: "SYNTHETIC_TOKEN" },
        };
      else if (path.endsWith("joined_chatgroups")) body = { data: groups };
      else if (path.endsWith("contacts/users")) body = { data: contacts };
      else if (path.endsWith("messageroaming")) body = history;
      else if (path.endsWith("getUsers4C"))
        body = {
          result: 1,
          data: [
            { uid: 456789, name: "Synthetic sender" },
            { uid: 456780, name: "Synthetic peer" },
          ],
        };
      else throw new Error("unexpected_endpoint");
      return {
        ok: true,
        status: 200,
        headers: { get: () => null, getSetCookie: () => [] },
        text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
      };
    },
    websocket: {
      open: async () => {},
      send: async (bytes) => sent.push(bytes),
      receive: async () => events.shift() ?? null,
      close: async () => {
        closed++;
      },
    },
  };
  return { ctx, records, calls, sent, closed: () => closed };
}
test("conversation discovery separates groups/contacts, names and IM credentials", async () => {
  const h = harness({ groups: [{ id: "9007199254740999", name: "Big group" }] });
  const result = await messagesConversations(h.ctx, { accountId: "123456" });
  valid("messages.conversations", result);
  assert.equal(result.coverage, "complete");
  assert.deepEqual(
    result.items.map((row) => [row.conversationKind, row.title]),
    [
      ["group", "Big group"],
      ["direct", "Synthetic peer"],
    ],
  );
  for (const { url, init } of h.calls.filter(({ url }) => url.includes("easemob"))) {
    assert.equal(init.headers.Cookie, undefined);
    assert.equal(init.headers.Authorization, "Bearer SYNTHETIC_TOKEN");
    assert.equal(new URL(url).hostname, "a1-vip6.easemob.com");
    assert.equal(init.redirect, "manual");
  }
  assert.ok(!h.records.get("chaoxing").includes("SYNTHETIC_TOKEN"));
});
test("partial discovery is explicit; total failure is not an empty list", async () => {
  const h = harness({ fail: (u) => u.endsWith("contacts/users") });
  assert.equal((await messagesConversations(h.ctx, { accountId: "123456" })).coverage, "partial");
  await assert.rejects(
    messagesConversations(harness({ fail: (u) => u.includes("easemob") }).ctx, { accountId: "123456" }),
  );
});
test("history keeps uint64 cursor exact, deduplicates messages and filters receipts/commands", async () => {
  const rows = [
    message(),
    message(),
    message({ type: 4 }),
    message({ content: 6 }),
    message({ ns: 3 }),
    message({
      id: 9007199254740994n,
      from: "456780",
      attachment: { att_homework: { title: "Synthetic homework", url: "https://secret.invalid/" } },
    }),
  ];
  const h = harness({
    history: `{"data":{"msgs":${JSON.stringify(rows.map(encoded))},"is_last":false,"next_key":9007199254740993}}`,
  });
  const result = await messagesHistory(h.ctx, { ...target, cursor: "9007199254740995" });
  valid("messages.history", result);
  assert.equal(result.nextCursor, "9007199254740993");
  assert.equal(result.items.length, 2);
  assert.equal(result.items[0].direction, "outgoing");
  assert.equal(result.items[0].senderLabel, "Synthetic sender");
  assert.equal(result.items[1].kind, "homework");
  assert.ok(result.items[1].text.includes("Synthetic homework"));
  assert.ok(!JSON.stringify(result).includes("secret.invalid"));
  assert.match(
    h.calls.find(({ url }) => url.endsWith("messageroaming")).init.body,
    /"start":9007199254740995,/,
  );
});
test("private history binds both participants and preserves recall tombstones", async () => {
  const p = { ...target, conversationId: "456780", conversationKind: "direct" };
  const h = harness({
    history: {
      data: {
        is_last: true,
        next_key: "undefined",
        msgs: [
          encoded(message({ from: "456780", to: "456789", type: 1, ns: 1 })),
          encoded(message({ id: 9007199254740994n, from: "456789", to: "456780", type: 1, ns: 1 })),
          encoded(
            message({
              id: 9007199254740995n,
              from: "456780",
              to: "456789",
              type: 6,
              ns: 1,
              recalled: 9007199254740993n,
            }),
          ),
          encoded(message({ from: "999999", to: "456789", type: 1, ns: 1 })),
        ],
      },
    },
  });
  const result = await messagesHistory(h.ctx, p);
  valid("messages.history", result);
  assert.deepEqual(result.recalledIds, ["9007199254740993"]);
  assert.deepEqual(
    result.items.map((row) => row.id),
    ["9007199254740994"],
  );
  assert.equal(result.hasMore, false);
  assert.ok(
    h.calls.find(({ url }) => url.endsWith("messageroaming")).init.body.includes("456780@easemob.com"),
  );
});
test("terminal cursor variants and non-progressing cursors", async () => {
  for (const next_key of [undefined, null, "undefined", "NaN", "0"]) {
    const result = await messagesHistory(
      harness({ history: { data: { msgs: [], is_last: false, next_key } } }).ctx,
      target,
    );
    assert.equal(result.hasMore, false);
  }
  for (const next_key of ["9007199254740995", "9007199254740996", "malformed"]) {
    await assert.rejects(
      messagesHistory(harness({ history: { data: { msgs: [], is_last: false, next_key } } }).ctx, {
        ...target,
        cursor: "9007199254740995",
      }),
    );
  }
});
test("wrong account/invalid target fails before history or send", async () => {
  const h = harness();
  await assert.rejects(messagesHistory(h.ctx, { ...target, accountId: "999999" }), {
    code: "authentication_required",
  });
  await assert.rejects(messagesHistory(h.ctx, { ...target, conversationId: "123@evil.invalid" }), {
    code: "input_invalid_request",
  });
  assert.ok(!h.calls.some(({ url }) => url.includes("easemob")));
});
test("send transmits exactly one text upload and requires matching server confirmation", async () => {
  const params = { ...target, clientId: "9007199254740993", text: "Synthetic outgoing" };
  const h = harness({ events: [provision(), ack("777"), ack(params.clientId)] });
  const result = await messagesSend(h.ctx, params);
  valid("messages.send", result);
  assert.equal(result.status, "sent");
  assert.equal(result.messageId, "9007199254740999");
  assert.equal(h.sent.length, 2);
  assert.equal(h.closed(), 1);
  const meta = sub(sub(decode(h.sent[1]), 9), 1);
  assert.equal(one(meta, 1), 9007199254740993n);
  assert.equal(one(meta, 5), 1n);
  assert.equal(str(sub(meta, 3), 3), "conference.easemob.com");
  assert.equal(str(decode(one(sub(meta, 6), 4)), 2), params.text);
});
test("send rejection, lost ACK, write failure and close failure never retry or invent success", async () => {
  const params = { ...target, clientId: "123", text: "Synthetic outgoing" };
  for (const [events, status] of [
    [[provision(), ack("123", 403)], "rejected"],
    [[provision(), ack("999")], "unknown"],
  ]) {
    const h = harness({ events });
    assert.equal((await messagesSend(h.ctx, params)).status, status);
    assert.equal(h.sent.length, 2);
  }
  const lost = harness({ events: [provision()] });
  let attempts = 0;
  lost.ctx.websocket.send = async () => {
    if (++attempts === 2) throw new Error("SYNTHETIC_TIMEOUT");
  };
  assert.equal((await messagesSend(lost.ctx, params)).status, "unknown");
  assert.equal(attempts, 2);
  const closed = harness({ events: [provision(), ack("123")] });
  closed.ctx.websocket.close = async () => {
    throw new Error("SYNTHETIC_CLOSE");
  };
  assert.equal((await messagesSend(closed.ctx, params)).status, "sent");
  const auth = harness({ events: [provision(401)] });
  await assert.rejects(messagesSend(auth.ctx, params), { code: "authentication_required" });
  assert.equal(auth.sent.length, 1);
});
