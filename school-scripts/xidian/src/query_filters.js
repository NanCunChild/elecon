/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-082: school-owned input names, never host instructions or raw querySetting.
import { dateOnly } from "./normalize.js";
import { serviceError } from "./service_session.js";

export const classroomFilterIds = [
  "date", "building", "room", "timeRange", "minimumTeachingSeats",
  "minimumExamSeats", "roomTypes", "onlyAvailable",
];
const invalid = () => { throw serviceError("input_invalid_request"); };
const object = (value) => value && typeof value === "object" && !Array.isArray(value);
const string = (value, max = 512) =>
  typeof value === "string" && Array.from(value).length <= max && !/[\u0000-\u001f\u007f]/.test(value);

export function validateQueryFilters(target, value = {}) {
  const allowed = target === "grades.list" ? ["term"] : classroomFilterIds;
  if (!object(value) || Object.keys(value).some((key) => !allowed.includes(key))) invalid();
  for (const [key, item] of Object.entries(value)) {
    if (key === "minimumTeachingSeats" || key === "minimumExamSeats") {
      if (!Number.isSafeInteger(item) || item < 0 || item > 100000) invalid();
    } else if (key === "onlyAvailable") {
      if (typeof item !== "boolean") invalid();
    } else if (key === "roomTypes") {
      if (!Array.isArray(item) || item.length > 32 || new Set(item).size !== item.length ||
          item.some((entry) => !string(entry, 128) || !entry)) invalid();
    } else if (key === "timeRange") {
      const clock = /^(?:[01]\d|2[0-3]):[0-5]\d$/;
      if (!object(item) || Object.keys(item).length !== 2 ||
          !string(item.start, 5) || !string(item.end, 5) ||
          !clock.test(item.start) || !clock.test(item.end) || item.start >= item.end) invalid();
    } else {
      if (!string(item, key === "room" ? 512 : 128)) invalid();
      if (key !== "room" && !item) invalid();
      if (key === "date") {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(item)) invalid();
        try { if (dateOnly(item) !== item) invalid(); } catch { invalid(); }
      }
      if (key === "term") {
        const parts = /^(\d{4})-(\d{4})-([12])$/.exec(item);
        if (!parts || Number(parts[2]) !== Number(parts[1]) + 1) invalid();
      }
    }
  }
  return value;
}

export function applyQueryFilters(target, params) {
  if (params.filters === undefined) return params;
  const filters = { ...validateQueryFilters(target, params.filters) };
  if (filters.room !== undefined) filters.room = filters.room.trim();
  const output = { ...params, filters };
  if (target === "grades.list") {
    if (filters.term !== undefined) output.term = filters.term;
    return output;
  }
  for (const field of ["date", "room", "onlyAvailable"]) {
    if (filters[field] !== undefined) output[field] = filters[field];
  }
  if (filters.building !== undefined) {
    output.buildingId = filters.building;
    // A prior native selection's label must not rename the new school id.
    delete output.building;
  }
  if (filters.timeRange !== undefined) {
    output.start = filters.timeRange.start;
    output.end = filters.timeRange.end;
    output.timeZone = "Asia/Shanghai";
  }
  return output;
}
