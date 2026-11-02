/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-061. Independently implemented from protocol facts in Quasar-core
// 96f36b38a2b01b810a2b45d66f0364183a4b7b87 (endpoints and wire field numbers).
// No Go implementation, generated protobuf code or dependency is included.
import { remoteId, requireParams, serviceError } from "../../xidian/src/service_session.js";
import { chaoxingClient } from "./account.js";
import { incoming, loginPacket } from "./messages.js";
import { decode, encode, one, str, sub } from "./protobuf.js";

const REST = "https://a1-vip6.easemob.com/cx-dev/cxstudy/users/";
const SOCKET = "wss://im-api-wechat-vip6.easemob.com/websocket";
const PROFILES = "https://useryd.chaoxing.com/apis/user/getUsers4C";
const decimal = (value) => typeof value === "string" && /^[1-9][0-9]{0,39}$/.test(value);
const stamp = (value) =>
  typeof value === "bigint" && value > 0n && value <= 8640000000000000n
    ? new Date(Number(value)).toISOString()
    : undefined;
const bounded = (value, limit) => (typeof value === "string" ? value.slice(0, limit) : "");
const identity = (ctx, account) => ({
  serviceId: "chaoxing",
  accountId: account.id,
  accountLabel: account.label,
  fetchedAt: new Date(ctx.now()).toISOString(),
});
function target(params) {
  if (!decimal(params.conversationId) || !["group", "direct"].includes(params.conversationKind))
    throw serviceError("input_invalid_request");
  return { conversationId: params.conversationId, conversationKind: params.conversationKind };
}
async function authenticated(ctx, params) {
  if (!decimal(params.accountId)) throw serviceError("input_invalid_request");
  const session = await chaoxingClient(ctx);
  if (session.account.id !== params.accountId) throw serviceError("authentication_required");
  return session;
}
// Preserve integer identifiers and cursors before JSON.parse, including values
// beyond JS's safe integer range. Never stringify a rounded JSON number.
function parseJson(raw) {
  if (typeof raw !== "string" || raw.length > 1024 * 1024) throw serviceError();
  try {
    return JSON.parse(
      raw.replace(/("(?:next_key|groupid|id|uid|puid)"\s*:\s*)([0-9]+)(?=\s*[,}])/g, '$1"$2"'),
    );
  } catch {
    throw serviceError();
  }
}
async function rest(ctx, account, suffix, body) {
  const response = await ctx.fetch(`${REST}${encodeURIComponent(account.tid)}/${suffix}`, {
    method: body === undefined ? "GET" : "POST",
    redirect: "manual",
    headers: { Authorization: `Bearer ${account.token}`, "Content-Type": "application/json" },
    ...(body === undefined ? {} : { body }),
  });
  if ([401, 403].includes(response.status)) throw serviceError("authentication_required");
  if (!response.ok) throw serviceError();
  const value = parseJson(await response.text());
  if (!value || value.error || value.error_description || value.data == null) throw serviceError();
  return value.data;
}
async function names(client, account, ids) {
  const result = new Map();
  const unique = [...new Set(ids.filter(decimal))].slice(0, 500);
  for (let offset = 0; offset < unique.length; offset += 50) {
    try {
      const value = parseJson(
        await client.post(PROFILES, {
          puid: account.id,
          tuids: unique.slice(offset, offset + 50).join(","),
          puids: "",
        }),
      );
      if (!Array.isArray(value?.data)) continue;
      for (const person of value.data.slice(0, 50)) {
        const name = bounded(person.name || person.nick, 160);
        if (decimal(person.uid) && name) result.set(person.uid, name);
      }
    } catch {
      /* Display names are optional; retain stable IDs on failure. */
    }
  }
  return result;
}

export async function messagesConversations(ctx, params = {}) {
  requireParams(params, ["accountId"]);
  const { client, account } = await authenticated(ctx, params);
  const items = new Map();
  let successful = 0;
  let partial = false;
  for (const kind of ["group", "direct"]) {
    try {
      const data = await rest(ctx, account, kind === "group" ? "joined_chatgroups" : "contacts/users");
      if (!Array.isArray(data)) throw serviceError();
      for (const row of data) {
        const id = remoteId(kind === "group" ? (row?.groupid ?? row?.id) : row);
        if (items.size >= 500 && !items.has(`${kind}:${id}`)) {
          partial = true;
          break;
        }
        items.set(`${kind}:${id}`, {
          conversationId: id,
          conversationKind: kind,
          title: kind === "group" ? bounded(row.groupname || row.name, 160) || id : id,
        });
      }
      successful++;
    } catch (error) {
      if (error.code === "authentication_required") throw error;
      partial = true;
    }
  }
  if (!successful) throw serviceError();
  const labels = await names(
    client,
    account,
    [...items.values()].filter((row) => row.conversationKind === "direct").map((row) => row.conversationId),
  );
  for (const row of items.values())
    if (row.conversationKind === "direct") row.title = labels.get(row.conversationId) || row.title;
  return {
    ...identity(ctx, account),
    coverage: partial ? "partial" : "complete",
    items: [...items.values()],
  };
}

function fromBase64(value) {
  if (
    typeof value !== "string" ||
    value.length > 87384 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(value) ||
    value.length % 4 === 1
  )
    throw serviceError();
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const bytes = [];
  let bits = 0,
    acc = 0;
  for (const c of value.replace(/=+$/, "")) {
    acc = (acc << 6) | alphabet.indexOf(c);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((acc >>> bits) & 255);
    }
  }
  return Uint8Array.from(bytes);
}
function extensions(body) {
  const result = new Map();
  for (const raw of body.get(5) ?? []) {
    const kv = decode(raw);
    result.set(str(kv, 1), str(kv, 6));
  }
  return result;
}
function summary(body) {
  const content = (body.get(4) ?? []).map(decode);
  // Commands/read receipts are transport state, never ordinary chat text.
  if (content.some((c) => one(c, 1, 0n) === 6n)) return null;
  const kinds = ["text", "image", "video", "location", "voice", "file"];
  let kind = kinds[Number(one(content[0] ?? new Map(), 1, 0n))] || "unknown";
  const chunks = content.map((c) => str(c, 2) || str(c, 23) || str(c, 6)).filter(Boolean);
  const ext = extensions(body);
  try {
    const attachment = JSON.parse(ext.get("attachment") || "null");
    if (attachment && typeof attachment === "object") {
      for (const [key, category] of [
        ["att_chat_course", "activity"],
        ["att_course", "course"],
        ["att_homework", "homework"],
        ["att_task", "task"],
        ["att_cloudDisk", "file"],
      ]) {
        const value = attachment[key];
        if (!value || typeof value !== "object") continue;
        kind = category;
        const title = bounded(value.title || value.name || value.courseName, 1000);
        if (title && !chunks.includes(title)) chunks.push(title);
      }
    }
  } catch {
    /* No raw attachment JSON/URLs/keys in output. */
  }
  const fallback = {
    text: "[非文本消息]",
    image: "[图片]",
    video: "[视频]",
    voice: "[语音]",
    location: "[位置]",
    file: "[文件]",
    activity: "[活动]",
    course: "[课程]",
    homework: "[作业]",
    task: "[任务]",
    unknown: "[非文本消息]",
  };
  return { text: chunks.join("\n").slice(0, 8000) || fallback[kind], kind };
}
export function historyMessage(raw, selfId, conversation) {
  const meta = decode(raw);
  if (![1n, 2n].includes(one(meta, 5))) return null;
  const body = sub(meta, 6);
  const type = one(body, 1);
  const from = str(sub(meta, 2), 2) || str(sub(body, 2), 2);
  const to = str(sub(meta, 3), 2) || str(sub(body, 3), 2);
  if (conversation.conversationKind === "group") {
    if (to !== conversation.conversationId) return null;
  } else if (
    !(
      (from === selfId && to === conversation.conversationId) ||
      (to === selfId && from === conversation.conversationId)
    )
  )
    return null;
  if (type === 6n) {
    const recalled = one(body, 6);
    return typeof recalled === "bigint" && recalled > 0n ? { recalled: recalled.toString() } : null;
  }
  if (type !== (conversation.conversationKind === "group" ? 2n : 1n)) return null;
  const content = summary(body);
  if (!content) return null;
  const id = one(meta, 1);
  if (typeof id !== "bigint" || id <= 0n) throw serviceError();
  const sentAt = stamp(one(meta, 4));
  return {
    id: id.toString(),
    ...content,
    direction: from === selfId ? "outgoing" : "incoming",
    ...(from ? { senderId: from } : {}),
    ...(sentAt ? { sentAt } : {}),
  };
}
export async function messagesHistory(ctx, params = {}) {
  requireParams(params, ["accountId", "conversationId", "conversationKind", "cursor"]);
  const conversation = target(params);
  if (
    params.cursor !== undefined &&
    (!decimal(params.cursor) || BigInt(params.cursor) > 9223372036854775807n)
  )
    throw serviceError("input_invalid_request");
  const { client, account } = await authenticated(ctx, params);
  const queue = `${conversation.conversationId}@${conversation.conversationKind === "group" ? "conference.easemob.com" : "easemob.com"}`;
  const page = await rest(
    ctx,
    account,
    "messageroaming",
    `{"queue":${JSON.stringify(queue)},"start":${params.cursor ?? "-1"},"end":-1}`,
  );
  if (!Array.isArray(page.msgs) || page.msgs.length > 200 || typeof page.is_last !== "boolean")
    throw serviceError();
  const noCursor = [undefined, null, "undefined", "NaN", "0", "-1", -1].includes(page.next_key);
  let nextCursor;
  if (!page.is_last && !noCursor) {
    if (
      !decimal(page.next_key) ||
      BigInt(page.next_key) > 9223372036854775807n ||
      (params.cursor && BigInt(page.next_key) >= BigInt(params.cursor))
    )
      throw serviceError();
    nextCursor = page.next_key;
  }
  const items = new Map(),
    recalled = new Set();
  for (const row of page.msgs) {
    if (!row.msg) continue;
    const item = historyMessage(fromBase64(row.msg), account.tid, conversation);
    if (item?.recalled) recalled.add(item.recalled);
    else if (item) items.set(item.id, item);
  }
  for (const id of recalled) items.delete(id);
  const labels = await names(
    client,
    account,
    [...items.values()].map((row) => row.senderId),
  );
  for (const row of items.values()) if (labels.has(row.senderId)) row.senderLabel = labels.get(row.senderId);
  return {
    ...identity(ctx, account),
    ...conversation,
    hasMore: !!nextCursor,
    ...(nextCursor ? { nextCursor } : {}),
    items: [...items.values()].sort(
      (a, b) => (a.sentAt || "").localeCompare(b.sentAt || "") || (BigInt(a.id) < BigInt(b.id) ? -1 : 1),
    ),
    recalledIds: [...recalled],
  };
}

const packet = (payload) =>
  encode([
    [1, 0],
    [8, 0],
    [9, payload],
    [11, 0],
  ]);
export function textPacket(account, params) {
  const jid = (name, domain) =>
    encode([
      [1, "cx-dev#cxstudy"],
      [2, name],
      [3, domain],
    ]);
  const group = params.conversationKind === "group";
  const from = jid(account.tid, "easemob.com");
  const to = jid(params.conversationId, group ? "conference.easemob.com" : "easemob.com");
  const body = encode([
    [1, group ? 2 : 1],
    [2, from],
    [3, to],
    [
      4,
      encode([
        [1, 0],
        [2, params.text],
      ]),
    ],
  ]);
  // Easemob Web SDK 4.12.0 uses CHAT namespace (1) for both send targets;
  // group routing is expressed by destination domain and MessageBody.type.
  return packet(
    encode([
      [
        1,
        encode([
          [1, BigInt(params.clientId)],
          [2, from],
          [3, to],
          [5, 1],
          [6, body],
        ]),
      ],
    ]),
  );
}
export async function messagesSend(ctx, params = {}) {
  requireParams(params, ["accountId", "conversationId", "conversationKind", "clientId", "text"]);
  const conversation = target(params);
  if (
    typeof params.text !== "string" ||
    !params.text.trim() ||
    params.text.length > 4000 ||
    !decimal(params.clientId) ||
    BigInt(params.clientId) > 0xffffffffffffffffn
  )
    throw serviceError("input_invalid_request");
  const { account } = await authenticated(ctx, params);
  if (!ctx.websocket) throw serviceError("input_unavailable");
  const bytes = textPacket(account, params);
  const started = ctx.now();
  let attempted = false;
  const result = (status, extra = {}) => ({
    ...identity(ctx, account),
    ...conversation,
    clientId: params.clientId,
    status,
    ...extra,
  });
  await ctx.websocket.open(SOCKET);
  try {
    await ctx.websocket.send(loginPacket(account, started));
    for (let i = 0; i < 24 && ctx.now() - started < 15000; i++) {
      const frame = await ctx.websocket.receive(3000);
      if (frame === null) break;
      if (!attempted) {
        if (!incoming(frame).authenticated) throw serviceError("authentication_required");
        attempted = true; // Set BEFORE await: a transport error may follow delivery.
        await ctx.websocket.send(bytes);
        continue;
      }
      const envelope = decode(frame);
      if (one(envelope, 4, 0n) !== 0n || one(envelope, 5, 0n) !== 0n || one(envelope, 11, 0n) !== 0n)
        throw serviceError();
      if (one(envelope, 8, 0n) !== 0n) continue;
      const ack = sub(envelope, 9);
      if (one(ack, 2) !== BigInt(params.clientId) || !(one(ack, 1) instanceof Uint8Array)) continue;
      if (one(sub(ack, 1), 1, 0n) !== 0n) return result("rejected");
      const id = one(ack, 3);
      if (typeof id !== "bigint" || id <= 0n) continue;
      const sentAt = stamp(one(ack, 8));
      return result("sent", { messageId: id.toString(), ...(sentAt ? { sentAt } : {}) });
    }
    if (!attempted) throw serviceError("authentication_required");
    return result("unknown");
  } catch (error) {
    if (attempted) return result("unknown");
    throw error;
  } finally {
    try {
      await ctx.websocket.close();
    } catch {
      /* Closing cannot invalidate an ACK. */
    }
  }
}
