/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-098: no school credentials or arbitrary image URL reaches native UI.
import { parseUrl } from "../../xidian/src/session.js";

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

export async function mapConcurrent(values, work) {
  let next = 0;
  let failed = false;
  const output = [];
  await Promise.all(
    Array.from({ length: Math.min(4, values.length) }, async () => {
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
  // fixed public image origins; never forward cookies or follow CDN redirects.
  const url = value.replace(/^http:\/\//, "https://");
  try {
    const parsed = parseUrl(url);
    return ["https://photo.chaoxing.com", "https://p.ananas.chaoxing.com"].includes(parsed.origin)
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
  for (const row of items.values()) {
    const ids =
      row.conversationKind === "group" ? members.get(row.conversationId) || [] : [row.conversationId];
    for (const id of ids.slice(0, 4)) {
      const person = profiles.get(id);
      const url = imageUrl(person?.pic120) || imageUrl(person?.pic);
      if (url && loaded.size < 64) loaded.set(url, null);
    }
  }
  await mapConcurrent([...loaded.keys()], async (url) => {
    try {
      const response = await ctx.fetch(url, { redirect: "manual", headers: {} });
      if (!response.ok) return;
      const size = Number(response.headers.get("content-length"));
      if (size > 16384) return;
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (!bytes.length || bytes.length > 16384) return;
      const mime = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
      const png = bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => bytes[i] === v);
      const jpeg = bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
      if (!((mime === "image/png" && png) || (mime === "image/jpeg" && jpeg))) return;
      loaded.set(url, `data:${mime};base64,${base64(bytes)}`);
    } catch (error) {
      optionalFailure(error);
    }
  });
  for (const row of items.values()) {
    const ids =
      row.conversationKind === "group" ? members.get(row.conversationId) || [] : [row.conversationId];
    const images = [];
    for (const id of ids.slice(0, 4)) {
      const person = profiles.get(id);
      const url = imageUrl(person?.pic120) || imageUrl(person?.pic);
      if (!url) continue;
      const data = loaded.get(url);
      if (data && outputBytes + data.length <= 1024 * 1024) {
        images.push(data);
        outputBytes += data.length;
      }
    }
    if (images.length) row.avatarImages = images;
  }
}
