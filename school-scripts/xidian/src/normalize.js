/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

export function text(value) {
  return value == null ? "" : String(value).trim();
}

export function number(value, label = "number") {
  const raw = text(value);
  if (!raw || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(raw)) throw new Error(`xidian_invalid_${label}`);
  const result = Number(raw);
  if (!Number.isFinite(result)) throw new Error(`xidian_invalid_${label}`);
  return result;
}

export function integer(value, label = "integer") {
  const result = number(value, label);
  if (!Number.isSafeInteger(result)) throw new Error(`xidian_invalid_${label}`);
  return result;
}

export function dateOnly(value) {
  const raw = text(value);
  const match = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T].*)?$/.exec(raw);
  if (!match) throw new Error("xidian_invalid_date");
  const [, year, month, day] = match;
  const iso = `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
  const date = new Date(`${iso}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== iso)
    throw new Error("xidian_invalid_date");
  return iso;
}

/** School timestamps without an offset are Asia/Shanghai wall time, never UTC. */
export function schoolDateTime(value) {
  const raw = text(value).replace(/::/g, ":");
  const match =
    /^(\d{4}[-/]\d{1,2}[-/]\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2})(\.\d{1,3})?)?(Z|[+-]\d{2}:?\d{2})?$/.exec(
      raw,
    );
  if (!match) throw new Error("xidian_invalid_datetime");
  const day = dateOnly(match[1]);
  const hour = Number(match[2]),
    minute = Number(match[3]),
    second = Number(match[4] || 0);
  if (hour > 23 || minute > 59 || second > 59) throw new Error("xidian_invalid_datetime");
  const offset = match[6] || "+08:00";
  const date = new Date(
    `${day}T${String(hour).padStart(2, "0")}:${match[3]}:${String(second).padStart(2, "0")}${match[5] || ""}${offset}`,
  );
  if (!Number.isFinite(date.getTime())) throw new Error("xidian_invalid_datetime");
  return date.toISOString();
}

/** Decimal arithmetic at the boundary: never round an imprecise float * 100. */
export function moneyMinor(value) {
  const match = /^([+-]?)(\d+)(?:\.(\d{1,2}))?$/.exec(text(value).replace(/^[¥￥]\s*/, ""));
  if (!match) throw new Error("xidian_invalid_money");
  const amount = Number(match[2]) * 100 + Number((match[3] || "").padEnd(2, "0"));
  if (!Number.isSafeInteger(amount)) throw new Error("xidian_invalid_money");
  return match[1] === "-" ? -amount : amount;
}
