/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-061. Independently implemented from protocol facts in Quasar-core
// 96f36b38a2b01b810a2b45d66f0364183a4b7b87 (endpoints and wire field numbers).
// No Go implementation, generated protobuf code or dependency is included.
import { remoteId, requireParams, serviceError } from "../../xidian/src/service_session.js";
import { chaoxingClient } from "./account.js";
import { messageContent } from "./message_content.js";
import { incoming, loginPacket } from "./messages.js";
import { decode, encode, one, str, sub } from "./protobuf.js";

const REST = "https://a1-vip6.easemob.com/cx-dev/cxstudy/";
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
  return {
    conversationId: params.conversationId,
    conversationKind: params.conversationKind,
  };
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
      raw.replace(/("(?:next_key|groupid|id|uid|puid|session_to)"\s*:\s*)([0-9]+)(?=\s*[,}])/g, '$1"$2"'),
    );
  } catch {
    throw serviceError();
  }
}
async function apiRest(ctx, account, path, body, { optional = false } = {}) {
  const response = await ctx.fetch(`${REST}${path}`, {
    method: body === undefined ? "GET" : "POST",
    redirect: "manual",
    headers: {
      Authorization: `Bearer ${account.token}`,
      "Content-Type": "application/json",
    },
    ...(body === undefined ? {} : { body }),
  });
  // Optional enrichment may be disabled by a feature/ACL policy. A 403 there
  // must not revoke the account that successfully fetched the joined directory.
  if (response.status === 401 || (response.status === 403 && !optional))
    throw serviceError("authentication_required");
  if (!response.ok) throw serviceError();
  const value = parseJson(await response.text());
  if (!value || value.error || value.error_description || value.data == null) throw serviceError();
  return value.data;
}
const rest = (ctx, account, suffix, body) =>
  apiRest(ctx, account, `users/${encodeURIComponent(account.tid)}/${suffix}`, body);

async function groupNames(ctx, account, items) {
  const ids = [...items.values()]
    .filter((row) => row.conversationKind === "group" && decimal(row.conversationId))
    .map((row) => row.conversationId);
  for (let offset = 0; offset < ids.length; offset += 50) {
    const batch = ids.slice(offset, offset + 50);
    const admitted = new Set(batch);
    try {
      // Official SDK getGroupInfo supports a bounded comma-separated ID batch.
      const data = await apiRest(ctx, account, `chatgroups/${batch.join(",")}?joined_time=true`, undefined, {
        optional: true,
      });
      if (!Array.isArray(data) || data.length > 50) continue;
      for (const detail of data) {
        const id = detail?.id ?? detail?.groupid;
        const title = bounded(detail?.name || detail?.groupname, 160).trim();
        if (!admitted.has(id) || !title) continue;
        items.get(`group:${id}`).title = title;
      }
    } catch (error) {
      if (error.code === "authentication_required") throw error;
      // Names are optional; a failed batch must not erase the joined directory.
    }
  }
}

// Official Easemob Web SDK 4.12 endpoint/response facts, independently authored.
// A current member mute outranks a group-wide exemption; ACL/network failures
// remain unknown. No group title, affiliation count or cached value authorizes send.
export async function sendPermission(ctx, account, conversation) {
  if (conversation.conversationKind === "direct") return { sendPermission: "allowed" };
  const unknown = {
    sendPermission: "unknown",
    sendPermissionReason: "verification_failed",
  };
  const id = conversation.conversationId;
  try {
    const details = await apiRest(ctx, account, `chatgroups/${id}?joined_time=true`, undefined, {
      optional: true,
    });
    const group = Array.isArray(details) && details.find((row) => (row?.id ?? row?.groupid) === id);
    if (!group) return unknown;
    if (group.disabled === true)
      return {
        sendPermission: "muted",
        sendPermissionReason: "group_disabled",
      };
    const personal = await apiRest(ctx, account, `sdk/chatgroups/${id}/mute/${account.tid}`, undefined, {
      optional: true,
    });
    if (personal === true) return { sendPermission: "muted", sendPermissionReason: "member_muted" };
    if (personal !== false || group.disabled !== false || typeof group.mute !== "boolean") return unknown;
    if (group.mute === false) return { sendPermission: "allowed" };
    const exemption = await apiRest(ctx, account, `chatgroups/${id}/white/users/${account.tid}`, undefined, {
      optional: true,
    });
    if (exemption?.member !== account.tid || typeof exemption.white !== "boolean") return unknown;
    return exemption.white
      ? { sendPermission: "allowed" }
      : { sendPermission: "muted", sendPermissionReason: "group_muted" };
  } catch (error) {
    if (error.code === "authentication_required") throw error;
    return unknown;
  }
}

async function recentConversations(ctx, account, items) {
  const seen = new Set();
  let cursor = "";
  for (let page = 0; page < 5; page++) {
    try {
      const path = `sdk/user/${encodeURIComponent(account.tid)}/user_channels/list?limit=100&cursor=${encodeURIComponent(cursor)}`;
      const data = await apiRest(ctx, account, path, undefined, {
        optional: true,
      });
      if (!Array.isArray(data.channel_infos) || data.channel_infos.length > 100) return;
      for (const channel of data.channel_infos) {
        const kind =
          channel?.session_type === "chat"
            ? "direct"
            : ["groupchat", "groupChat"].includes(channel?.session_type)
              ? "group"
              : undefined;
        const row = kind && items.get(`${kind}:${channel.session_to}`);
        const meta = channel?.meta;
        if (!row || !meta || typeof meta !== "object") continue;
        let payload = meta.payload;
        try {
          if (typeof payload === "string" && payload.length <= 65536) payload = JSON.parse(payload);
        } catch {
          continue;
        }
        if (!payload || !Array.isArray(payload.bodies) || payload.bodies.length > 20) continue;
        const types = payload.bodies.map((body) => body?.type);
        if (
          types.some((type) => ["cmd", "read", "delivery", "recall"].includes(type)) ||
          !types.some((type) => ["txt", "img", "video", "audio", "file", "loc", "custom"].includes(type))
        )
          continue;
        // Only matching directory entries receive metadata, never new strangers.
        if (kind === "group" && payload.to !== undefined && payload.to !== row.conversationId) continue;
        row.hasContent = true;
        const rawTime = meta.timestamp;
        if (
          (typeof rawTime === "number" && Number.isSafeInteger(rawTime)) ||
          (typeof rawTime === "string" && /^[0-9]{1,16}$/.test(rawTime))
        ) {
          const time = stamp(BigInt(rawTime));
          if (time && (!row.lastMessageAt || time > row.lastMessageAt)) row.lastMessageAt = time;
        }
      }
      const next = data.cursor;
      if (next === undefined || next === null || next === "") return;
      if (typeof next !== "string" || next.length > 512 || next === cursor || seen.has(next)) return;
      seen.add(next);
      cursor = next;
    } catch (error) {
      if (error.code === "authentication_required") throw error;
      return; // No per-group history fallback or automatic retry.
    }
  }
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
          sendPermission: kind === "direct" ? "allowed" : "unknown",
          title: kind === "group" ? bounded(row.groupname || row.name, 160).trim() || id : id,
        });
      }
      successful++;
    } catch (error) {
      if (error.code === "authentication_required") throw error;
      partial = true;
    }
  }
  if (!successful) throw serviceError();
  await groupNames(ctx, account, items);
  await recentConversations(ctx, account, items);
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
    items: [...items.values()].sort(
      (a, b) =>
        Number(b.hasContent === true) - Number(a.hasContent === true) ||
        (a.hasContent === true && b.hasContent === true
          ? (b.lastMessageAt || "").localeCompare(a.lastMessageAt || "")
          : 0),
    ),
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
  const content = messageContent(body);
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
  const permission = await sendPermission(ctx, account, conversation);
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
    ...permission,
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
  let attempted = false;
  const result = (status, extra = {}) => ({
    ...identity(ctx, account),
    ...conversation,
    clientId: params.clientId,
    status,
    ...extra,
  });
  const permission = await sendPermission(ctx, account, conversation);
  if (permission.sendPermission !== "allowed") return result("rejected");
  const started = ctx.now();
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
      return result("sent", {
        messageId: id.toString(),
        ...(sentAt ? { sentAt } : {}),
      });
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
