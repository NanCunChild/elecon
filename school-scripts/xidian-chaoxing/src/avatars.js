/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-098: no school credentials or arbitrary image URL reaches native UI.
import { parseUrl, resolveUrl } from "../../xidian/src/session.js";
import { chatProbe } from "./chat_probe.js";

export function optionalFailure(error) {
  if (
    error?.code === "authentication_required" ||
    error?.code === "invocation_cancelled" ||
    error?.code === "input_cancelled" ||
    error?.code?.endsWith("_limit") ||
    error?.code === "wall_timeout"
  )
    throw error;
}

export async function mapConcurrent(values, work, concurrency = 4) {
  let next = 0;
  let failed = false;
  const output = [];
  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, async () => {
      while (!failed && next < values.length) {
        const index = next++;
        try {
          output[index] = await work(values[index]);
        } catch (error) {
          failed = true;
          throw error;
        }
      }
    }),
  );
  return output;
}

function imageUrl(value) {
  if (typeof value !== "string" || value.length > 2048) return null;
  // Historical profile responses contain HTTP image URLs. Upgrade only these
  // fixed public image origins; never forward cookies. Redirects are separately
  // limited to one explicit hop through this same origin check.
  const url = value
    .replace(/^http:\/\//, "https://")
    .replace(/([?&]psize=)[^&#]*/, (_, key) => `${key}120_120c`);
  try {
    const parsed = parseUrl(url);
    return ["https://photo.chaoxing.com", "https://p.ananas.chaoxing.com", "https://p.cldisk.com"].includes(
      parsed.origin,
    )
      ? url
      : null;
  } catch {
    return null;
  }
}

function base64(bytes) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let result = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
    result += alphabet[n >>> 18] + alphabet[(n >>> 12) & 63];
    result += i + 1 < bytes.length ? alphabet[(n >>> 6) & 63] : "=";
    result += i + 2 < bytes.length ? alphabet[n & 63] : "=";
  }
  return result;
}

export async function conversationImages(ctx, items, members, profiles) {
  const loaded = new Map();
  let outputBytes = 0;
  // Give each requested conversation one image before filling mosaics, so a
  // small optional budget cannot always go to the first large group alone.
  for (let index = 0; index < 4; index++)
    for (const row of items.values()) {
      const ids =
        row.conversationKind === "group" ? members.get(row.conversationId) || [] : [row.conversationId];
      for (const id of ids.slice(index, index + 1)) {
        const person = profiles.get(id);
        const url = imageUrl(person?.pic120) || imageUrl(person?.pic);
        if (url && loaded.size < 64) loaded.set(url, null);
      }
    }
  // Complete each bounded image transaction, including its possible second
  // hop, before spending the optional budget on another first hop.
  await mapConcurrent(
    [...loaded.keys()],
    async (url) => {
      try {
        let response = await ctx.fetch(url, { redirect: "manual", headers: {} });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const location = response.headers.get("location");
          const destination = location && imageUrl(resolveUrl(location, url));
          if (!destination || destination === url) return;
          response = await ctx.fetch(destination, { redirect: "manual", headers: {} });
        }
        if (!response.ok) return;
        const size = Number(response.headers.get("content-length"));
        if (size > 16384) {
          chatProbe(ctx, 23, "skipped", response.status, [undefined, false]);
          return;
        }
        const bytes = new Uint8Array(await response.arrayBuffer());
        const mime = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
        const png = bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => bytes[i] === v);
        const jpeg = bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
        const allowedMime = mime === "image/png" || mime === "image/jpeg";
        const matchingMime = (mime === "image/png" && png) || (mime === "image/jpeg" && jpeg);
        chatProbe(ctx, 23, "ok", response.status, [
          bytes.length > 0,
          bytes.length <= 16384,
          allowedMime,
          png || jpeg,
          matchingMime,
        ]);
        if (!bytes.length || bytes.length > 16384) return;
        if (!allowedMime || !(png || jpeg)) return;
        // The source may label a processed thumbnail with the original MIME.
        // Normalize to the actual permitted bytes before the native validator.
        loaded.set(url, `data:${png ? "image/png" : "image/jpeg"};base64,${base64(bytes)}`);
      } catch (error) {
        optionalFailure(error);
      }
    },
    1,
  );
  for (const row of items.values()) {
    const ids =
      row.conversationKind === "group" ? members.get(row.conversationId) || [] : [row.conversationId];
    const images = [];
    const flags = [ids.length > 0, false, false, false, false, false];
    for (const id of ids.slice(0, 4)) {
      const person = profiles.get(id);
      flags[1] ||= !!person;
      const url = imageUrl(person?.pic120) || imageUrl(person?.pic);
      if (!url) continue;
      flags[2] = true;
      flags[3] ||= loaded.has(url);
      const data = loaded.get(url);
      flags[4] ||= typeof data === "string";
      if (data && outputBytes + data.length <= 1024 * 1024) {
        images.push(data);
        outputBytes += data.length;
      }
    }
    flags[5] = images.length > 0;
    chatProbe(ctx, 28, "ok", 0, flags);
    if (images.length) row.avatarImages = images;
  }
}
