/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// Protocol facts: Quasar-core chaoxing/types/im/proto; independently authored
// finite-window implementation, without the reference Go client or its codegen.
import { requireParams, serviceError } from "../../xidian/src/service_session.js";
import { chaoxingClient } from "./account.js";
import { clientIdentity } from "./client_identity.js";
import { messageContent } from "./message_content.js";
import { decode, encode, one, str, sub } from "./protobuf.js";

const SOCKET = "wss://im-api-wechat-vip6.easemob.com/websocket";
const packet = (command, payload) =>
  encode([
    [1, 0],
    [8, command],
    [9, payload],
    [11, 0],
  ]);
export function loginPacket(account, now) {
  const resource = `webim_web_${clientIdentity(account.id ?? account.tid).clientId}-${account.tid}`;
  const auth = `$t$${account.token}`;
  return encode([
    [1, 0],
    [
      2,
      encode([
        [1, "cx-dev#cxstudy"],
        [2, account.tid],
        [3, "easemob.com"],
        [4, resource],
      ]),
    ],
    [3, auth],
    [8, 3],
    [
      9,
      encode([
        [1, 16],
        [2, "4.12.0"],
        [5, 0],
        [6, 0],
        [9, resource],
        [12, resource],
        [13, resource],
        [17, "v5.0"],
        [18, JSON.stringify({ token: auth })],
        [19, `${now}:`],
      ]),
    ],
    [10, 0],
    [11, 0],
  ]);
}
function checkStatus(fields, field) {
  const status = sub(fields, field);
  if (one(status, 1, 0n) !== 0n) throw serviceError("authentication_required");
}
export function incoming(bytes) {
  const envelope = decode(bytes);
  if (one(envelope, 4, 0n) !== 0n || one(envelope, 5, 0n) !== 0n || one(envelope, 11, 0n) !== 0n)
    throw serviceError();
  const command = one(envelope, 8, 0n);
  const payload = sub(envelope, 9);
  if (command === 3n) {
    if (!(one(payload, 8) instanceof Uint8Array)) throw serviceError();
    checkStatus(payload, 8);
    return { authenticated: true, items: [], replies: [] };
  }
  if (command === 2n) {
    const queue = one(payload, 1);
    if (!(queue instanceof Uint8Array)) throw serviceError();
    return { items: [], replies: [packet(0, encode([[3, queue]]))] };
  }
  if (command !== 0n) throw serviceError();
  checkStatus(payload, 1);
  const items = [];
  const replies = [];
  for (const raw of payload.get(4) ?? []) {
    const meta = decode(raw);
    const body = sub(meta, 6);
    // Do not ACK private messages: their receipt/read semantics differ.
    if (one(body, 1) !== 2n) continue;
    const id = one(meta, 1);
    const queue = one(meta, 3) ?? one(meta, 2);
    if (typeof id !== "bigint" || id <= 0n || !(queue instanceof Uint8Array)) throw serviceError();
    const conversationId = str(decode(queue), 2);
    if (!conversationId) throw serviceError();
    const content = messageContent(body);
    let activityId;
    for (const ext of body.get(5) ?? []) {
      const kv = decode(ext);
      if (str(kv, 1) !== "attachment") continue;
      try {
        // Preserve decimal activity IDs before JSON.parse can round uint64.
        const attachment = JSON.parse(
          str(kv, 6).replace(/("aid"\s*:\s*)([0-9]+)(?=\s*[,}])/g, '$1"$2"'),
        )?.att_chat_course;
        if (
          attachment &&
          /^[1-9][0-9]{0,39}$/.test(String(attachment.aid)) &&
          [2, 74].includes(attachment.atype)
        ) {
          activityId = String(attachment.aid);
        }
      } catch {
        /* Optional malformed attachment cannot expose raw content. */
      }
    }
    const timestamp = one(meta, 4);
    const date =
      typeof timestamp === "bigint" && timestamp > 0n && timestamp <= 8640000000000000n
        ? new Date(Number(timestamp))
        : null;
    items.push({
      id: id.toString(),
      conversationId,
      ...content,
      ...(str(sub(body, 2), 2) ? { senderId: str(sub(body, 2), 2) } : {}),
      ...(date ? { sentAt: date.toISOString() } : {}),
      ...(activityId ? { activityId } : {}),
    });
    replies.push(
      packet(
        0,
        encode([
          [2, id],
          [3, queue],
        ]),
      ),
    );
  }
  return { items, replies };
}
export async function messagesList(ctx, params = {}) {
  requireParams(params);
  const { account } = await chaoxingClient(ctx);
  if (!ctx.websocket) throw serviceError("input_unavailable");
  const started = ctx.now();
  const items = new Map();
  let authenticated = false;
  await ctx.websocket.open(SOCKET);
  try {
    await ctx.websocket.send(loginPacket(account, started));
    for (let i = 0; i < 24 && ctx.now() - started < 15000; i++) {
      const bytes = await ctx.websocket.receive(3000);
      if (bytes === null) {
        if (!authenticated) throw serviceError("authentication_required");
        break;
      }
      const event = incoming(bytes);
      if (event.authenticated) authenticated = true;
      else if (!authenticated) throw serviceError("authentication_required");
      if (!event.items.length) {
        for (const reply of event.replies) await ctx.websocket.send(reply);
      } else {
        for (let j = 0; j < event.items.length; j++) {
          const item = event.items[j];
          if (items.size >= 50 && !items.has(item.id)) break;
          items.set(item.id, item);
          await ctx.websocket.send(event.replies[j]);
        }
      }
      if (items.size >= 50) break;
    }
    if (!authenticated) throw serviceError("authentication_required");
    return {
      serviceId: "chaoxing",
      accountId: account.id,
      accountLabel: account.label,
      windowStartedAt: new Date(started).toISOString(),
      fetchedAt: new Date(ctx.now()).toISOString(),
      coverage: "window",
      items: [...items.values()],
    };
  } finally {
    await ctx.websocket.close();
  }
}
