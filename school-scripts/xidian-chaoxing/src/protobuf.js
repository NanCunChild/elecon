/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// Minimal bounded protobuf wire codec. uint64 values always remain BigInt;
// business IDs become decimal strings only after decoding. No generated code.
import { serviceError } from "../../xidian/src/service_session.js";
export const utf8 = (text) => Uint8Array.from(unescape(encodeURIComponent(text)), (c) => c.charCodeAt(0));
export const text = (bytes) =>
  decodeURIComponent(escape(Array.from(bytes, (b) => String.fromCharCode(b)).join("")));
function varint(value) {
  let n = BigInt(value);
  if (n < 0n || n > 0xffffffffffffffffn) throw serviceError();
  const out = [];
  do {
    out.push(Number(n & 127n) | (n > 127n ? 128 : 0));
    n >>= 7n;
  } while (n);
  return out;
}
export function encode(fields) {
  const bytes = [];
  for (const [field, value] of fields) {
    if (!Number.isInteger(field) || field < 1 || field > 536870911) throw serviceError();
    const data = typeof value === "string" ? utf8(value) : value;
    if (data instanceof Uint8Array)
      bytes.push(...varint(BigInt(field) * 8n + 2n), ...varint(data.length), ...data);
    else bytes.push(...varint(BigInt(field) * 8n), ...varint(data));
    if (bytes.length > 65536) throw serviceError();
  }
  return new Uint8Array(bytes);
}
export function decode(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length > 65536) throw serviceError();
  let offset = 0;
  let count = 0;
  const fields = new Map();
  function read() {
    let n = 0n;
    for (let i = 0; i < 10; i++) {
      if (offset >= bytes.length) throw serviceError();
      const b = bytes[offset++];
      if (i === 9 && b > 1) throw serviceError();
      n |= BigInt(b & 127) << BigInt(i * 7);
      if (!(b & 128)) return n;
    }
    throw serviceError();
  }
  while (offset < bytes.length) {
    if (++count > 2048) throw serviceError();
    const key = read();
    const field = Number(key >> 3n);
    const type = Number(key & 7n);
    if (!field || field > 536870911) throw serviceError();
    let value;
    if (type === 0) value = read();
    else {
      const size = type === 2 ? Number(read()) : type === 1 ? 8 : type === 5 ? 4 : -1;
      if (!Number.isSafeInteger(size) || size < 0 || size > bytes.length - offset) throw serviceError();
      value = bytes.slice(offset, offset + size);
      offset += size;
    }
    const list = fields.get(field) ?? [];
    list.push(value);
    fields.set(field, list);
  }
  return fields;
}
export function one(fields, number, fallback) {
  const values = fields.get(number);
  if (!values) return fallback;
  if (values.length !== 1) throw serviceError();
  return values[0];
}
export function sub(fields, number) {
  const v = one(fields, number);
  return decode(v ?? new Uint8Array());
}
export function str(fields, number, fallback = "") {
  const v = one(fields, number);
  return v === undefined ? fallback : text(v);
}
