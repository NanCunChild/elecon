/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-061. Independently implemented from protocol facts in Quasar-core
// 96f36b38a2b01b810a2b45d66f0364183a4b7b87 (endpoints and wire field numbers).
// No Go implementation, generated protobuf code or dependency is included.
import { remoteId, requireParams, serviceError } from "../../xidian/src/service_session.js";
import { chaoxingClient } from "./account.js";
import { conversationImages, mapConcurrent, optionalFailure } from "./avatars.js";
import { chatContext, chatProbe } from "./chat_probe.js";
import { messageContent } from "./message_content.js";
import { incoming, loginPacket } from "./messages.js";
import { profileRequestUrl } from "./profile_request.js";
import { decode, encode, one, str, sub } from "./protobuf.js";

const REST = "https://a1-vip6.easemob.com/cx-dev/cxstudy/";
const SOCKET = "wss://im-api-wechat-vip6.easemob.com/websocket";
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
      raw.replace(
        /("(?:next_key|groupid|id|uid|puid|session_to|owner|admin|member)"\s*:\s*)([0-9]+)(?=\s*[,}])/g,
        '$1"$2"',
      ),
    );
  } catch {
    throw serviceError();
  }
}
async function apiRest(ctx, account, path, body, { optional = false, withCursor = false } = {}) {
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
  return withCursor ? { items: value.data, cursor: value.cursor } : value.data;
}
const rest = (ctx, account, suffix, body) =>
  apiRest(ctx, account, `users/${encodeURIComponent(account.tid)}/${suffix}`, body);

const namedGroup = (title, id) => title && title !== id && !title.endsWith(`_${id}`);

async function enrichmentCache(ctx, account) {
  try {
    const record = await ctx.credentials.get("chat-enrichment", { namespace: "xidian.services" });
    const value = record && JSON.parse(record.value);
    if (
      value?.version === 2 &&
      value.accountId === account.id &&
      value.items &&
      typeof value.items === "object" &&
      !Array.isArray(value.items)
    )
      return value.items;
  } catch (error) {
    optionalFailure(error);
  }
  return {};
}

async function groupNames(ctx, account, items) {
  const details = new Map();
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
      chatProbe(ctx, 19, "ok", 0, [
        Array.isArray(data),
        Array.isArray(data) && data.length > 0,
        Array.isArray(data) && data.some((v) => admitted.has(v?.id ?? v?.groupid)),
        Array.isArray(data) && data.some((v) => typeof (v?.name ?? v?.groupname) === "string"),
        Array.isArray(data) && data.some((v) => decimal(v?.owner)),
        Array.isArray(data) && data.some((v) => Array.isArray(v?.affiliations)),
      ]);
      if (!Array.isArray(data) || data.length > 50) continue;
      for (const detail of data) {
        const id = detail?.id ?? detail?.groupid;
        const title = bounded(detail?.name || detail?.groupname, 160).trim();
        if (!admitted.has(id)) continue;
        details.set(id, detail);
        if (namedGroup(title, id)) items.get(`group:${id}`).title = title;
      }
    } catch (error) {
      optionalFailure(error);
      // Names are optional; a failed batch must not erase the joined directory.
    }
  }
  return details;
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
    optionalFailure(error);
    return unknown;
  }
}

async function recentConversations(ctx, account, items, maxPages = 5) {
  const seen = new Set();
  let cursor = "";
  for (let page = 0; page < maxPages; page++) {
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
      optionalFailure(error);
      return; // No per-group history fallback or automatic retry.
    }
  }
}
async function profiles(ctx, client, account, ids) {
  const result = new Map();
  const unique = [...new Set(ids.filter(decimal))].slice(0, 500);
  for (let offset = 0; offset < unique.length; offset += 50) {
    try {
      const admitted = new Set(unique.slice(offset, offset + 50));
      const raw = await client.post(profileRequestUrl(ctx.now()), {
        puid: account.id,
        tuids: unique.slice(offset, offset + 50).join(","),
        puids: "",
      });
      chatProbe(ctx, 27, "ok", 0, [
        raw.trimStart().startsWith("{"),
        raw.trimStart().startsWith("<"),
        /passport2\.chaoxing\.com|用户登录|用户登陆/.test(raw),
        raw.length === 0,
      ]);
      const value = parseJson(raw);
      chatProbe(ctx, 26, "ok", 0, [
        Array.isArray(value?.data),
        !!value?.data && typeof value.data === "object" && !Array.isArray(value.data),
        Array.isArray(value?.data) && value.data.length > 0,
        value?.result === 1 || value?.result === true,
        Array.isArray(value?.data) && value.data.some((v) => admitted.has(v?.uid)),
        Array.isArray(value?.data) && value.data.some((v) => !!(v?.name || v?.nick)),
        Array.isArray(value?.data) && value.data.some((v) => !!(v?.pic || v?.pic120)),
        value?.data !== undefined,
      ]);
      if (!Array.isArray(value?.data)) continue;
      for (const person of value.data.slice(0, 50)) {
        if (!admitted.has(person?.uid)) continue;
        result.set(person.uid, {
          name: bounded(person.name || person.nick, 160).trim(),
          pic120:
            typeof person.pic120 === "string" && person.pic120.length <= 2048 ? person.pic120 : undefined,
          pic: typeof person.pic === "string" && person.pic.length <= 2048 ? person.pic : undefined,
        });
      }
    } catch (error) {
      chatProbe(ctx, 26, "failed");
      optionalFailure(error);
      /* Display names are optional; retain stable IDs on failure. */
    }
  }
  return result;
}

async function groupMembers(ctx, account, items, details, cached) {
  const result = new Map();
  // A bounded sample for display, never a claim to enumerate a large group.
  await mapConcurrent(
    [...items.values()].filter((row) => row.conversationKind === "group").slice(0, 8),
    async (row) => {
      const id = row.conversationId;
      const saved = cached[`group:${id}`];
      const age = ctx.now() - Date.parse(saved?.fetchedAt);
      if (
        age >= 0 &&
        age < 300000 &&
        Array.isArray(saved?.sample?.ids) &&
        saved.sample.ids.length > 0 &&
        saved.sample.ids.length <= 4 &&
        saved.sample.ids.every(decimal)
      ) {
        result.set(id, saved.sample);
        return;
      }
      const detail = details.get(id) || {};
      const ordered = [];
      const add = (value) => {
        if (decimal(value) && !ordered.includes(value)) ordered.push(value);
      };
      add(detail.owner);
      const affiliations = Array.isArray(detail.affiliations) ? detail.affiliations.slice(0, 100) : [];
      for (const entry of affiliations) add(entry?.owner);
      for (const entry of affiliations) add(entry?.admin);
      for (const entry of affiliations) add(entry?.member);
      let more = ordered.length > 4 || detail.affiliations_count > 4;
      if (ordered.length < 4) {
        try {
          const members = await apiRest(
            ctx,
            account,
            `chatgroups/${id}/users?limit=4&joined_time=true`,
            undefined,
            {
              optional: true,
              withCursor: true,
            },
          );
          if (Array.isArray(members.items) && members.items.length <= 50) {
            const rows = members.items;
            for (const entry of rows) add(entry?.owner);
            for (const entry of rows) add(entry?.admin);
            for (const entry of rows) add(typeof entry === "string" ? entry : entry?.member);
            more ||= ordered.length > 4 || (typeof members.cursor === "string" && members.cursor.length > 0);
            chatProbe(ctx, 24, "ok", 0, [
              true,
              rows.some((v) => decimal(v?.owner)),
              rows.some((v) => decimal(v?.admin)),
              ordered.length > 0,
              more,
            ]);
          }
        } catch (error) {
          optionalFailure(error);
        }
      }
      result.set(id, { ids: ordered.slice(0, 4), more });
    },
  );
  return result;
}

export async function messagesConversations(ctx, params = {}) {
  ctx = chatContext(ctx);
  requireParams(params, ["accountId"]);
  const { account } = await authenticated(ctx, params);
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
          title:
            kind === "group" && namedGroup(bounded(row.groupname || row.name, 160).trim(), id)
              ? bounded(row.groupname || row.name, 160).trim()
              : id,
        });
      }
      successful++;
    } catch (error) {
      optionalFailure(error);
      partial = true;
    }
  }
  if (!successful) throw serviceError();
  await groupNames(ctx, account, items);
  const cached = await enrichmentCache(ctx, account);
  for (const [key, row] of items) {
    const previous = cached[key]?.patch?.title;
    if (
      !namedGroup(row.title, row.conversationId) &&
      typeof previous === "string" &&
      namedGroup(previous, row.conversationId)
    )
      row.title = bounded(previous, 160);
  }
  return {
    ...identity(ctx, account),
    coverage: partial ? "partial" : "complete",
    items: [...items.values()],
  };
}

// Metadata is optional for every backend. School protocol and cache policy stay here.
export async function messagesEnrich(ctx, params = {}) {
  ctx = chatContext(ctx);
  requireParams(params, ["accountId", "items"]);
  if (!Array.isArray(params.items) || params.items.length < 1 || params.items.length > 8)
    throw serviceError("input_invalid_request");
  const requested = new Map();
  for (const raw of params.items) {
    const row = target(raw || {});
    const key = `${row.conversationKind}:${row.conversationId}`;
    if (requested.has(key)) throw serviceError("input_invalid_request");
    requested.set(key, { ...row, title: row.conversationId });
  }
  const { client, account } = await authenticated(ctx, params);
  const address = { namespace: "xidian.services" };
  const cached = await enrichmentCache(ctx, account);
  let fetchedAt = ctx.now();
  const fresh = new Map(),
    pending = new Map();
  for (const [key, row] of requested) {
    const saved = cached[key];
    const age = ctx.now() - Date.parse(saved?.fetchedAt);
    // A metadata-only result cannot prove that the native archive still has
    // images (e.g. source update or archive pruning). Retry missing images.
    if (age >= 0 && age < 300000 && saved?.patch?.avatarImages?.length) {
      fresh.set(key, saved.patch);
      fetchedAt = Math.min(fetchedAt, Date.parse(saved.fetchedAt));
    } else pending.set(key, row);
  }
  if (pending.size) {
    const details = await groupNames(ctx, account, pending);
    await recentConversations(ctx, account, pending, 1);
    const available = ctx.budget ? (await ctx.budget.remaining()).requests : 40;
    let optional = Math.min(8, Math.max(0, available - 4));
    const limited = (cap) => {
      let used = 0;
      return {
        ...ctx,
        fetch: async (...args) => {
          if (used >= cap || optional <= 0) throw serviceError("optional_budget_exhausted");
          used++;
          optional--;
          return ctx.fetch(...args);
        },
      };
    };
    const samples = await groupMembers(limited(Math.min(4, optional)), account, pending, details, cached);
    const labels = await profiles(ctx, client, account, [
      ...[...pending.values()]
        .filter((row) => row.conversationKind === "direct")
        .map((row) => row.conversationId),
      ...[...samples.values()].flatMap((sample) => sample.ids),
    ]);
    for (const row of pending.values()) {
      if (row.conversationKind === "direct") row.title = labels.get(row.conversationId)?.name || row.title;
      else if (!namedGroup(row.title, row.conversationId)) {
        const sample = samples.get(row.conversationId);
        const names = (sample?.ids || []).map((id) => labels.get(id)?.name).filter(Boolean);
        if (names.length) row.title = bounded(names.join("、") + (sample.more ? "..." : ""), 160);
      }
    }
    await conversationImages(
      limited(optional),
      pending,
      new Map([...samples].map(([id, sample]) => [id, sample.ids])),
      labels,
    );
    for (const [key, row] of pending) {
      const patch = { conversationId: row.conversationId, conversationKind: row.conversationKind };
      for (const field of ["title", "avatarImages", "hasContent", "lastMessageAt"])
        if (row[field] !== undefined && !(field === "title" && row.title === row.conversationId))
          patch[field] = row[field];
      fresh.set(key, patch);
      chatProbe(ctx, 25, "ok", 0, [
        typeof patch.title === "string",
        !!patch.avatarImages?.length,
        patch.hasContent === true,
      ]);
      // Replay complete small results; metadata-only entries still retry images.
      // Oversized image results remain in the native archive.
      const { avatarImages, ...metadata } = patch;
      cached[key] = {
        fetchedAt: new Date(ctx.now()).toISOString(),
        patch: JSON.stringify(patch).length <= 8000 ? patch : metadata,
        ...(row.conversationKind === "group" && samples.get(row.conversationId)?.ids.length
          ? { sample: samples.get(row.conversationId) }
          : {}),
      };
    }
    const entries = Object.entries(cached).sort(
      (a, b) => Date.parse(b[1].fetchedAt) - Date.parse(a[1].fetchedAt),
    );
    const kept = {};
    for (const [key, value] of entries.slice(0, 128)) {
      kept[key] = value;
      if (JSON.stringify(kept).length > 12000) {
        delete kept[key];
        break;
      }
    }
    await ctx.credentials.set(
      "chat-enrichment",
      JSON.stringify({ version: 2, accountId: account.id, items: kept }),
      { ...address, type: "query", expiresAt: null },
    );
  }
  return {
    ...identity(ctx, account),
    fetchedAt: new Date(fetchedAt).toISOString(),
    items: [...requested.keys()].map((key) => fresh.get(key)),
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
  const labels = await profiles(
    ctx,
    client,
    account,
    [...items.values()].map((row) => row.senderId),
  );
  for (const row of items.values())
    if (labels.get(row.senderId)?.name) row.senderLabel = labels.get(row.senderId).name;
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
