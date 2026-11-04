/*! Copyright 2023-2025 BenderBlog Rodriguez and contributors.
 * Copyright 2025-2026 Traintime PDA authors.
 * Copyright 2026 elecon contributors.
 * SPDX-License-Identifier: MPL-2.0
 * Protocol/field mapping adapted from Traintime PDA e780e4d0:
 * lib/repository/ids_session/{classtable,score,exam,semester,empty_classroom}_session.dart
 * and lib/model/xidian_ids/{classtable,score,exam}.dart. See ../LICENSE.
 */

import { classroomDirectory } from "./classroom_directory.js";
import { failure } from "./errors.js";
import { dateOnly, integer, number, schoolDateTime, text } from "./normalize.js";
import { createClient, parseUrl } from "./session.js";
import { applyQueryFilters } from "./query_filters.js";

const EH = "https://ehall.xidian.edu.cn";
const PG = "https://yjspt.xidian.edu.cn/gsapp/sys";
const SCHEDULE = `${EH}/jwapp/sys/wdkb/modules`;
const CLASSROOM = `${EH}/jwapp/sys/kxjas/modules/kxjas`;
const EXAMS = `${EH}/jwapp/sys/studentWdksapApp/modules/wdksap`;
const PAGE_SIZE = 200;
const MAX_PAGES = 8;
const MAX_WEEKS = 100;
// Traintime PDA lib/model/time_list.dart; wall clock in Asia/Shanghai.
const TIMES = [
  ["08:30", "09:15"],
  ["09:20", "10:05"],
  ["10:25", "11:10"],
  ["11:15", "12:00"],
  ["14:00", "14:45"],
  ["14:50", "15:35"],
  ["15:55", "16:40"],
  ["16:45", "17:30"],
  ["19:00", "19:45"],
  ["19:50", "20:35"],
  ["20:40", "21:25"],
];

function postgraduate(params) {
  const role = params.role ?? "undergraduate";
  if (role !== "undergraduate" && role !== "postgraduate") throw new Error("academic_role_invalid");
  return role === "postgraduate";
}

function positive(value, label, max = 10000) {
  const result = integer(value, label);
  if (result < 1 || result > max) throw new Error(`academic_${label}_invalid`);
  return result;
}

function termCode(value) {
  const result = text(value);
  const match = /^(\d{4})-(\d{4})-([12])$/.exec(result);
  if (!match || Number(match[2]) !== Number(match[1]) + 1) throw new Error("academic_term_invalid");
  return result;
}

function optional(out, key, value) {
  const result = text(value);
  if (result) out[key] = result;
}

async function studentId(ctx, client, params) {
  let value = text(params.studentId ?? client.session?.data?.studentId);
  if (!value && ctx.ui) {
    // ADR-037: only this school script knows which query needs the identifier.
    const input = await ctx.ui.requestInput({
      title: "补充学号",
      message: "学校接口需要学号以查询当前账号的课表或考试。填写后仅保存在当前学校身份中。",
      fields: [{ id: "studentId", label: "学号", type: "text", required: true, maxLength: 128 }],
    });
    if (input === null) throw failure("input_cancelled");
    value = text(input.studentId);
  }
  if (!value) throw failure("student_id_required");
  if (client.session.data.studentId !== value) {
    client.session.data.studentId = value;
    await client.save();
  }
  return value;
}

function queryUrl(url, fields) {
  return `${url}?${Object.entries(fields)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`)
    .join("&")}`;
}

async function openApp(client, pg, app) {
  const url = pg
    ? app === "yjsemaphome"
      ? "https://yjspt.xidian.edu.cn/"
      : `${PG}/${app}/*default/index.do`
    : `${EH}/appShow?appId=${app}`;
  const response = await client.request(url);
  if (response && (response.status === 401 || parseUrl(response.url).host === "ids.xidian.edu.cn"))
    throw failure(`xidian_login_required_${client.session.service}`);
  if (!response || response.status < 200 || response.status >= 300)
    throw new Error("academic_app_open_failed");
}

function resultNode(payload, name, allowUnpublished = false, statusFromEnvelope = false) {
  const node = payload?.datas?.[name];
  const unpublished = text(node?.extParams?.msg ?? payload?.extParams?.msg).includes(
    "查询学年学期的课程未发布",
  );
  if (allowUnpublished && unpublished) return { rows: [], totalSize: 0 };
  if (
    !node ||
    (statusFromEnvelope
      ? String(payload?.code) !== "0"
      : payload.code != null && String(payload.code) !== "0") ||
    (!statusFromEnvelope && node.extParams?.code != null && Number(node.extParams.code) !== 1) ||
    !Array.isArray(node.rows)
  ) {
    // Do not repeat server messages: they may contain account data or login URLs.
    throw failure("academic_response_invalid");
  }
  return node;
}

function pageTotal(node) {
  for (const key of ["totalSize", "total", "totalCount"]) {
    if (node[key] == null || node[key] === "") continue;
    const total = integer(node[key], "page_total");
    if (total < 0) throw new Error("academic_page_total_invalid");
    return total;
  }
  return null;
}

// Emap tables use pageNumber/pageSize and normally totalSize. If an endpoint
// ignores pagination, repeats a page, changes its total, or exceeds the bounded
// budget, fail explicitly instead of returning a plausible truncated result.
async function pages(
  client,
  url,
  fields,
  name,
  { query = false, unpublished = false, statusFromEnvelope = false } = {},
) {
  const all = [];
  const seen = new Set();
  let expected = null;
  for (let page = 1; page <= MAX_PAGES; page++) {
    const args = { ...fields, pageSize: PAGE_SIZE, pageNumber: page };
    const payload = query ? await client.postForm(queryUrl(url, args), {}) : await client.postForm(url, args);
    let node;
    try {
      node = resultNode(payload, name, unpublished, statusFromEnvelope);
    } catch (error) {
      const table = payload?.datas?.[name];
      // Static table names and shape only; no response text or student fields.
      client.log(
        "warn",
        `academic_table_invalid:${name}:${!table ? "missing_table" : !Array.isArray(table.rows) ? "missing_rows" : "rejected"}`,
      );
      // Fixed classifications only; codes/messages/rows may identify a user.
      client.log(
        "warn",
        `academic_table_status:${name}:${String(payload?.code) === "0" ? "top_ok" : payload?.code == null ? "top_missing" : "top_failed"}:${table?.extParams?.code == null ? "table_missing" : Number(table.extParams.code) === 1 ? "table_one" : Number(table.extParams.code) === 0 ? "table_zero" : "table_other"}`,
      );
      throw error;
    }
    const total = pageTotal(node);
    if (total != null) {
      if (expected != null && total !== expected) throw new Error("academic_pagination_changed");
      expected = total;
    }
    if (node.rows.length) {
      const fingerprint = JSON.stringify(node.rows);
      if (seen.has(fingerprint)) throw new Error("academic_pagination_repeated");
      seen.add(fingerprint);
      all.push(...node.rows);
    }
    if (all.length > PAGE_SIZE * MAX_PAGES || (expected != null && all.length > expected)) {
      throw new Error("academic_pagination_inconsistent");
    }
    if (expected != null && all.length === expected) return all;
    if (node.rows.length === 0) {
      if (expected != null) throw new Error("academic_pagination_incomplete");
      return all;
    }
    // A short page is the usual terminal signal where no total is supplied.
    if (expected == null && node.rows.length < PAGE_SIZE) return all;
  }
  throw new Error("academic_pagination_limit");
}

async function currentTerm(client, pg) {
  if (pg) {
    const payload = await client.postForm(`${PG}/yjsemaphome/modules/pubWork/getUserInfo.do`, {});
    if (String(payload?.code) !== "0") throw new Error("academic_current_term_failed");
    return termCode(payload?.data?.xnxqdm);
  }
  const payload = await client.postForm(`${SCHEDULE}/jshkcb/dqxnxq.do`, {});
  return termCode(resultNode(payload, "dqxnxq").rows[0]?.DM);
}

async function resolveTerm(client, pg, params) {
  if (text(params.term)) return termCode(params.term);
  await openApp(client, pg, pg ? "yjsemaphome" : "4770397878132218");
  return currentTerm(client, pg);
}

async function termStart(client, pg, term) {
  let raw;
  if (pg) {
    const payload = await client.postForm(`${PG}/yjsemaphome/homeAppend/getSchoolCalendar.do`, {
      xnxqdm: term,
    });
    let calendar = payload?.msg;
    if (typeof calendar === "string") {
      try {
        calendar = JSON.parse(calendar);
      } catch {
        throw new Error("academic_calendar_invalid");
      }
    }
    raw = calendar?.QSRQ;
  } else {
    const payload = await client.postForm(`${SCHEDULE}/jshkcb/cxjcs.do`, {
      XN: term.slice(0, 9),
      XQ: term.slice(-1),
    });
    raw = resultNode(payload, "cxjcs").rows[0]?.XQKSRQ;
  }
  const match = /^(\d{4}-\d{2}-\d{2})(?:[ T].*)?$/.exec(text(raw));
  if (!match) throw new Error("academic_calendar_invalid");
  return dateOnly(match[1]);
}

function addDays(date, count) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + count * 86400000).toISOString().slice(0, 10);
}

function weeks(value) {
  const input = text(value);
  if (!input) return [];
  // Both known school timetable APIs send bitmap, with index zero = week one.
  // Long zero/one strings must never be parsed as one decimal week number.
  if (/^[01]+$/.test(input)) {
    if (input.length > MAX_WEEKS) throw new Error("academic_week_bitmap_invalid");
    return [...input].flatMap((bit, index) => (bit === "1" ? [index + 1] : []));
  }
  // Keep support for explicit human-readable ranges found in legacy fixtures.
  const selected = new Set();
  const odd = /单/.test(input);
  const even = /双/.test(input);
  const clean = input.replace(/第|周|[()（）]|单|双|\s/g, "");
  if (!/^\d+(?:[-~～]\d+)?(?:[,，、;；]\d+(?:[-~～]\d+)?)*$/.test(clean))
    throw new Error("academic_weeks_invalid");
  for (const piece of clean.split(/[,，、;；]/)) {
    const range = piece.split(/[-~～]/);
    const start = positive(range[0], "week", MAX_WEEKS);
    const end = positive(range[1] ?? range[0], "week", MAX_WEEKS);
    if (end < start) throw new Error("academic_weeks_invalid");
    for (let week = start; week <= end; week++)
      if ((!odd || week % 2 === 1) && (!even || week % 2 === 0)) selected.add(week);
  }
  return [...selected].sort((a, b) => a - b);
}

function arrangement(row, pg) {
  const start = positive(pg ? row.KSJCDM : row.KSJC, "section", 24);
  const end = positive(pg ? row.JSJCDM : row.JSJC, "section", 24);
  if (end < start) throw new Error("academic_section_range_invalid");
  const name = text(pg ? row.KCMC : row.KCM);
  if (!name) throw new Error("academic_course_name_missing");
  return {
    name,
    code: text(pg ? row.KCDM : row.KCH),
    classNo: text(row.KXH),
    teacher: text(pg ? row.JSXM : row.SKJS),
    room: text(row.JASMC),
    start,
    end,
    day: positive(pg ? row.XQ : row.SKXQ, "weekday", 7),
    weeks: weeks(pg ? row.ZCBH : row.SKZC),
    changeType: "none",
  };
}

function sameCourse(slot, row) {
  const code = text(row.KCH);
  const classNo = text(row.KXH);
  return (code ? slot.code === code : slot.name === text(row.KCM)) && (!classNo || slot.classNo === classNo);
}

function mergeAdjacent(base) {
  const groups = new Map();
  for (const slot of base) {
    const key = JSON.stringify([
      slot.name,
      slot.code,
      slot.classNo,
      slot.teacher,
      slot.room,
      slot.day,
      slot.weeks,
    ]);
    const group = groups.get(key) ?? [];
    group.push(slot);
    groups.set(key, group);
  }
  const merged = [];
  for (const group of groups.values()) {
    let previous;
    for (const slot of group.sort((a, b) => a.start - b.start)) {
      if (previous && slot.start <= previous.end + 1) previous.end = Math.max(previous.end, slot.end);
      else {
        previous = { ...slot };
        merged.push(previous);
      }
    }
  }
  return merged;
}

function applyChanges(base, changes) {
  let slots = base.flatMap((slot) => slot.weeks.map((week) => ({ ...slot, week })));
  // The source is requested oldest first so chained A->B->C changes can apply.
  const ordered = changes.every((row) => text(row.SQSJ))
    ? [...changes].sort((a, b) => text(a.SQSJ).localeCompare(text(b.SQSJ)))
    : changes;
  for (const row of ordered) {
    const type = text(row.TKLXDM);
    if (!type) throw new Error("academic_change_type_missing");
    const oldWeeks = weeks(row.SKZC);
    const newWeeks = row.XSKZC == null ? oldWeeks : weeks(row.XSKZC);
    const oldStart = text(row.KSJC) ? positive(row.KSJC, "section", 24) : null;
    const oldEnd = text(row.JSJC) ? positive(row.JSJC, "section", 24) : null;
    const oldDay = text(row.SKXQ) ? positive(row.SKXQ, "weekday", 7) : null;
    let exemplar = slots.find((slot) => sameCourse(slot, row));
    if (type === "01" || type === "02") {
      if (!oldWeeks.length || !oldStart || !oldEnd || !oldDay || oldEnd < oldStart)
        throw new Error("academic_change_invalid");
      const remaining = [];
      for (const slot of slots) {
        const match =
          sameCourse(slot, row) &&
          oldWeeks.includes(slot.week) &&
          slot.day === oldDay &&
          slot.start <= oldEnd &&
          slot.end >= oldStart &&
          (!text(row.JASMC) || slot.room === text(row.JASMC));
        if (!match) {
          remaining.push(slot);
          continue;
        }
        exemplar = slot;
        if (slot.start < oldStart) remaining.push({ ...slot, end: oldStart - 1 });
        if (slot.end > oldEnd) remaining.push({ ...slot, start: oldEnd + 1 });
      }
      slots = remaining;
    }
    if (type === "02") continue; // A stopped class is no longer an active slot.
    const start = positive(text(row.XKSJC) || oldStart, "section", 24);
    const end = positive(text(row.XJSJC) || oldEnd, "section", 24);
    const day = positive(text(row.XSKXQ) || oldDay, "weekday", 7);
    if (end < start || !newWeeks.length) throw new Error("academic_change_invalid");
    const next = {
      ...exemplar,
      name: text(row.KCM) || exemplar?.name,
      code: text(row.KCH) || exemplar?.code || "",
      classNo: text(row.KXH) || exemplar?.classNo || "",
      teacher: text(row.XSKJS) || text(row.YSKJS) || exemplar?.teacher,
      room: text(row.XJASMC) || text(row.JASMC) || exemplar?.room,
      start,
      end,
      day,
      weeks: newWeeks,
      changeType: type === "01" ? "rescheduled" : "makeup",
    };
    if (!next.name) throw new Error("academic_course_name_missing");
    for (const week of newWeeks) {
      // The base response may already contain this destination, merged with
      // adjacent sections. Replace only the overlapping destination sections.
      slots = slots.flatMap((slot) => {
        const overlaps =
          sameCourse(slot, row) &&
          slot.week === week &&
          slot.day === day &&
          slot.start <= end &&
          slot.end >= start &&
          slot.room === next.room;
        if (!overlaps) return [slot];
        return [
          ...(slot.start < start ? [{ ...slot, end: start - 1 }] : []),
          ...(slot.end > end ? [{ ...slot, start: end + 1 }] : []),
        ];
      });
      slots.push({ ...next, week });
    }
  }
  const groups = new Map();
  for (const slot of slots) {
    const key = JSON.stringify([
      slot.name,
      slot.code,
      slot.classNo,
      slot.teacher,
      slot.room,
      slot.day,
      slot.start,
      slot.end,
      slot.changeType,
    ]);
    const group = groups.get(key) ?? new Set();
    group.add(slot.week);
    groups.set(key, group);
  }
  return slots.map((slot) => ({
    ...slot,
    weeks: [
      ...groups.get(
        JSON.stringify([
          slot.name,
          slot.code,
          slot.classNo,
          slot.teacher,
          slot.room,
          slot.day,
          slot.start,
          slot.end,
          slot.changeType,
        ]),
      ),
    ].sort((a, b) => a - b),
  }));
}

function slotOutput(slot, startDate, week) {
  const output = {
    start: String(slot.start),
    end: String(slot.end),
    courseName: slot.name,
    weeks: slot.weeks,
    changeType: slot.changeType,
  };
  optional(output, "courseId", slot.code);
  optional(output, "classNo", slot.classNo);
  optional(output, "teacher", slot.teacher);
  optional(output, "room", slot.room);
  if (TIMES[slot.start - 1]) output.timeStart = TIMES[slot.start - 1][0];
  if (TIMES[slot.end - 1]) output.timeEnd = TIMES[slot.end - 1][1];
  const startWeekday = new Date(`${startDate}T00:00:00Z`).getUTCDay() || 7;
  output.date = addDays(startDate, (week - 1) * 7 + ((slot.day - startWeekday + 7) % 7));
  return output;
}

export async function scheduleWeek(ctx, params = {}) {
  const pg = postgraduate(params);
  // ADR-038 §1: the script resolves its default home query; host stays school-agnostic.
  if (params.week == null) {
    const calendar = await calendarAcademic(ctx, params);
    params = { ...params, term: params.term ?? calendar.term, week: calendar.currentWeek ?? 1 };
  }
  const week = positive(params.week, "week", MAX_WEEKS);
  const client = await createClient(ctx, pg ? "yjspt" : "ehall");
  const term = await resolveTerm(client, pg, params);
  await openApp(client, pg, pg ? "wdkbapp" : "4770397878132218");
  const startDate = await termStart(client, pg, term);
  const rows = await pages(
    client,
    pg ? `${PG}/wdkbapp/modules/xskcb/xspkjgcx.do` : `${SCHEDULE}/xskcb/xskcb.do`,
    pg ? { XNXQDM: term } : { XNXQDM: term, XH: await studentId(ctx, client, params) },
    pg ? "xspkjgcx" : "xskcb",
    { unpublished: true },
  );
  const base = mergeAdjacent(rows.map((row) => arrangement(row, pg)));
  let allSlots;
  if (pg) allSlots = base.flatMap((slot) => slot.weeks.map((week) => ({ ...slot, week })));
  else {
    const changes = await pages(
      client,
      `${SCHEDULE}/xskcb/xsdkkc.do`,
      { XNXQDM: term, "*order": "+SQSJ" },
      "xsdkkc",
    );
    allSlots = applyChanges(base, changes);
  }
  const slots = allSlots.filter((slot) => slot.week === week);
  const days = Array.from({ length: 7 }, (_, i) => ({ dayOfWeek: i + 1, slots: [] }));
  const seen = new Set();
  for (const slot of slots) {
    const output = slotOutput(slot, startDate, week);
    const identity = JSON.stringify([slot.day, output]);
    if (!seen.has(identity)) days[slot.day - 1].slots.push(output);
    seen.add(identity);
  }
  for (const day of days)
    day.slots.sort((a, b) => Number(a.start) - Number(b.start) || a.courseName.localeCompare(b.courseName));
  // The API returned the complete term. Summarize that same result without
  // fetching each week, using the selected week's exact deduplication rule.
  const previewWeeks = new Map();
  let previewEnd = Math.max(25, week);
  for (const slot of allSlots) {
    previewEnd = Math.max(previewEnd, slot.week);
    if (!previewWeeks.has(slot.week))
      previewWeeks.set(
        slot.week,
        Array.from({ length: 7 }, () => new Set()),
      );
    previewWeeks.get(slot.week)[slot.day - 1].add(JSON.stringify(slotOutput(slot, startDate, slot.week)));
  }
  return {
    term,
    week,
    academicYear: term.slice(0, 9),
    termStartDate: startDate,
    teachingWeekStart: addDays(startDate, (week - 1) * 7),
    teachingWeekEnd: addDays(startDate, week * 7 - 1),
    sourceSystem: pg ? "西电研究生院" : "西电本科教务",
    timeSegments: TIMES.map(([timeStart, timeEnd], index) => ({
      label: String(index + 1),
      timeStart,
      timeEnd,
    })),
    weekPreviews: Array.from({ length: previewEnd }, (_, index) => {
      const previewWeek = index + 1;
      return {
        week: previewWeek,
        days: Array.from({ length: 7 }, (_, index) => ({
          dayOfWeek: index + 1,
          courseCount: previewWeeks.get(previewWeek)?.[index].size ?? 0,
        })),
      };
    }),
    // ADR-054 / schedule.week 1.2: the same term response supplies complete
    // week details, including empty weeks. The host can switch weeks locally.
    termWeeks: Array.from({ length: previewEnd }, (_, index) => {
      const cachedWeek = index + 1;
      return {
        week: cachedWeek,
        teachingWeekStart: addDays(startDate, (cachedWeek - 1) * 7),
        teachingWeekEnd: addDays(startDate, cachedWeek * 7 - 1),
        days: Array.from({ length: 7 }, (_, day) => ({
          dayOfWeek: day + 1,
          slots: [...(previewWeeks.get(cachedWeek)?.[day] ?? [])]
            .map((encoded) => JSON.parse(encoded))
            .sort((a, b) => Number(a.start) - Number(b.start) || a.courseName.localeCompare(b.courseName)),
        })),
      };
    }),
    days,
  };
}

function gradeTerm(row) {
  const raw = text(row.XNXQDM) || text(row.XNXQDM_DISPLAY);
  if (/^\d{4}-\d{4}-[12]$/.test(raw)) return termCode(raw);
  const match = /^(\d{4})-(\d{4})学年?第?([12一二])学期$/.exec(raw);
  if (match) return termCode(`${match[1]}-${match[2]}-${{ 一: 1, 二: 2 }[match[3]] ?? match[3]}`);
  throw new Error("academic_grade_term_missing");
}

function sourceStatus(value) {
  if (/重修/.test(value)) return "retake";
  if (/补考|重考/.test(value)) return "makeup";
  if (/缓考/.test(value)) return "deferred";
  if (/免修|免考/.test(value)) return "exempt";
  if (/改分/.test(value)) return "改分";
  if (/退课/.test(value)) return "withdrawn";
  if (/初修|正常|正考/.test(value)) return "normal";
  return "unknown";
}

function gradeScore(row, pg) {
  const raw = text(pg ? row.DYBFZCJ : row.ZCJ);
  const level = text(pg ? row.CJXSZ : row.DJCJMC);
  const kindCode = text(pg ? row.CJFZDM : row.DJCJLXDM);
  const isLevel = kindCode !== "" && Number(kindCode) !== 0;
  const displayed = isLevel && level ? level : raw;
  if (/缺考/.test(displayed)) return { kind: "unknown", value: null, raw: displayed, status: "absent" };
  if (/免修|免考/.test(displayed)) return { kind: "unknown", value: null, raw: displayed, status: "exempt" };
  if (isLevel && level)
    return {
      kind: /合格|通过/.test(level) || Number(kindCode) === 3 ? "passfail" : "letter",
      value: level,
      raw: displayed,
      status: "known",
    };
  if (isLevel && Number(kindCode) === 3 && ["0", "1"].includes(text(row.SFJG))) {
    return { kind: "passfail", value: text(row.SFJG) === "1" ? "通过" : "未通过", raw, status: "known" };
  }
  if (!displayed && ["0", "1"].includes(text(row.SFJG))) {
    return { kind: "passfail", value: text(row.SFJG) === "1" ? "通过" : "未通过", raw: "", status: "known" };
  }
  if (!displayed) return { kind: "unknown", value: null, raw: "", status: "notReleased" };
  if (!isLevel && /^\d+(?:\.\d+)?$/.test(displayed))
    return { kind: "numeric", value: number(displayed, "score"), raw: displayed, max: 100, status: "known" };
  return {
    kind: /合格|通过/.test(displayed) ? "passfail" : isLevel ? "letter" : "unknown",
    value: displayed,
    raw: displayed,
    status: "known",
  };
}

function gradeOutput(row, pg) {
  const courseId = text(row.KCH) || text(row.KCDM) || text(row.JXBID);
  const courseName = text(pg ? row.KCMC : row.XSKCM);
  if (!courseId || !courseName) throw new Error("academic_grade_course_missing");
  const nature = pg
    ? text(row.KCLBMC)
    : text(row.XGXKLBDM_DISPLAY)
      ? `选修 ${text(row.XGXKLBDM_DISPLAY)}`
      : text(row.KCXZDM_DISPLAY);
  const status = sourceStatus(text(pg ? row.KSXZDM_DISPLAY : row.CXCKDM_DISPLAY));
  const credit = number(row.XF, "credit");
  if (credit < 0) throw new Error("academic_credit_invalid");
  const output = {
    courseId,
    courseName,
    credit,
    score: gradeScore(row, pg),
    category: /必修/.test(nature) ? "required" : /选修/.test(nature) ? "elective" : "unknown",
    status: "unknown",
    sourceStatus: status,
  };
  optional(output, "courseNature", nature);
  optional(output, "courseCategory", pg ? row.KCLBMC : row.KCLBDM_DISPLAY);
  optional(output, "classNo", row.JXBID);
  optional(output, "sectionNo", row.KXH);
  if (status !== "unknown") output.retake = status === "retake";
  return output;
}

async function gradeRows(client, pg) {
  await openApp(client, pg, pg ? "wdcjapp" : "4768574631264620");
  // PDA score_session.dart sends one SFYX object for the UG endpoint. This
  // endpoint does not share the array querySetting used by other Emap apps.
  // The grade query and historical term discovery share this bounded fetch.
  const filters = pg ? [] : { name: "SFYX", value: "1", linkOpt: "and", builder: "m_value_equal" };
  return pages(
    client,
    pg ? `${PG}/wdcjapp/modules/wdcj/xscjcx.do` : `${EH}/jwapp/sys/cjcx/modules/cjcx/xscjcx.do`,
    {
      ...(pg ? {} : { "*json": 1, "*order": "+XNXQDM,KCH,KXH" }),
      querySetting: JSON.stringify(filters),
    },
    "xscjcx",
  );
}

export async function gradesList(ctx, params = {}) {
  params = applyQueryFilters("grades.list", params);
  const pg = postgraduate(params);
  const client = await createClient(ctx, pg ? "yjspt" : "ehall");
  const term = await resolveTerm(client, pg, params);
  const rows = await gradeRows(client, pg);
  return {
    term,
    academicYear: term.slice(0, 9),
    gradePointScale: "unknown",
    items: rows.filter((row) => gradeTerm(row) === term).map((row) => gradeOutput(row, pg)),
  };
}

function examOutput(row, pg) {
  const time = text(row.KSSJMS);
  // UG: YYYY-MM-DD HH:mm-HH:mm. PG: YYYY-MM-DD 周四(HH:mm-HH:mm).
  const match = /^(\d{4}-\d{1,2}-\d{1,2})\s+(?:[^\d(（]*[（(])?(\d{1,2})::?(\d{1,2})/.exec(time);
  const output = {
    courseName: text(pg ? row.KCMC : row.KCM),
    status: /cancel|取消/i.test(time) ? "cancelled" : "unknown",
  };
  if (!output.courseName) throw new Error("academic_exam_course_missing");
  if (match && output.status !== "cancelled") {
    const [y, m, d] = match[1].split("-");
    output.examAt = schoolDateTime(
      `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}T${match[2].padStart(2, "0")}:${match[3].padStart(2, "0")}:00`,
    );
    output.status = "scheduled";
  }
  optional(output, "courseId", row.KCH ?? row.KCDM ?? row.JXBID);
  optional(output, "room", row.JASMC);
  optional(output, "seat", row.ZWH);
  optional(output, "examType", pg ? row.KSLXDM_DISPLAY : row.KSMC);
  return output;
}

export async function examList(ctx, params = {}) {
  const pg = postgraduate(params);
  const client = await createClient(ctx, pg ? "yjspt" : "ehall");
  const term = await resolveTerm(client, pg, params);
  await openApp(client, pg, pg ? "wdksapp" : "4768687067472349");
  const fields = pg
    ? {
        querySetting: JSON.stringify([
          { name: "XNXQDM", caption: "学年学期代码", builder: "equal", linkOpt: "AND", value: term },
          { name: "SFFBKSAP", caption: "是否发布考试安排", builder: "equal", linkOpt: "AND", value: "1" },
          {
            name: "XH",
            caption: "学号",
            builder: "equal",
            linkOpt: "AND",
            value: await studentId(ctx, client, params),
          },
          { name: "KSAPWID", caption: "考试安排WID", builder: "notEqual", linkOpt: "AND", value: null },
        ]),
      }
    : { XNXQDM: term, "*order": "-KSRQ,-KSSJMS" };
  const rows = await pages(
    client,
    pg ? `${PG}/wdksapp/modules/ksxxck/wdksxxcx.do` : `${EXAMS}/wdksap.do`,
    fields,
    pg ? "wdksxxcx" : "wdksap",
    // PDA exam_session.dart validates top-level code and rows. The exam
    // table's extParams code does not share the timetable's success=1 rule.
    { query: true, statusFromEnvelope: true },
  );
  const items = rows.map((row) => examOutput(row, pg));
  if (!pg) {
    const pending = await pages(client, `${EXAMS}/cxyxkwapkwdkc.do`, { XNXQDM: term }, "cxyxkwapkwdkc", {
      query: true,
      statusFromEnvelope: true,
    });
    for (const row of pending) {
      const item = { courseName: text(row.KCM), status: "unknown", changeReason: "已选课，考试尚未安排" };
      if (!item.courseName) throw new Error("academic_exam_course_missing");
      optional(item, "courseId", row.KCH);
      items.push(item);
    }
  }
  return { term, items };
}

function campusFilter(items, campus) {
  return campus
    ? items.filter(
        (item) =>
          item.campus === campus ||
          item.building.includes(campus) ||
          (item.buildingId ?? "").includes(campus),
      )
    : items;
}

export async function classroomBuildings(_ctx, params = {}) {
  postgraduate(params); // Both roles use the shared undergraduate classroom app.
  const output = { items: campusFilter(classroomDirectory(), text(params.campus)) };
  optional(output, "campus", params.campus);
  if (text(params.term)) output.term = termCode(params.term);
  return output;
}

/** Live discovery for the new form; legacy classroom.buildings stays offline. */
export async function classroomBuildingsLive(ctx, existingClient) {
  const client = existingClient ?? await createClient(ctx, "ehall");
  await openApp(client, false, "4768402106681759");
  const rows = await pages(client, `${CLASSROOM}/jxlcx.do`, { "*order": "+XXXQDM,+PX,+JXLDM" }, "jxlcx");
  const items = rows.map((row) => {
    const buildingId = text(row.JXLDM);
    const building = text(row.JXLJC) || text(row.JXLMC);
    if (!buildingId || !building) throw new Error("academic_building_identity_missing");
    const item = { buildingId, building };
    optional(item, "campus", row.XXXQDM);
    optional(item, "campusLabel", row.XXXQDM_DISPLAY ?? row.XXXQMC);
    return item;
  });
  if (new Set(items.map((item) => item.buildingId)).size !== items.length)
    throw new Error("academic_building_identity_duplicate");
  return items;
}

function classroomCapacity(value) {
  if (value == null || text(value) === "") return undefined;
  const result = integer(value, "classroom_capacity");
  if (result < 0) throw new Error("academic_classroom_capacity_invalid");
  return result;
}

function classroomReason(ctx, raw) {
  const names = {
    "01": ["classroom.reasonCourse", "上课占用"],
    "02": ["classroom.reasonExam", "考试占用"],
    "03": ["classroom.reasonRescheduled", "调课占用"],
    "04": ["classroom.reasonBorrowed", "教室借用"],
    "05": ["classroom.reasonBlocked", "教室屏蔽"],
  };
  const codes = [...new Set(String(raw).split(",").filter((value) => value.startsWith("1_")).map((value) => value.slice(2)))];
  return codes.map((code) => {
    const [key, fallback] = names[code] ?? ["classroom.occupiedReason", "教务系统记录本节占用"];
    return ctx.i18n?.t(key) ?? fallback;
  }).join(" / ");
}

function sectionWindow(params) {
  let first = positive(params.sectionStart ?? 1, "section", 11);
  let last = positive(params.sectionEnd ?? 11, "section", 11);
  if (first > last) throw new Error("academic_section_range_invalid");
  const start = text(params.start);
  const end = text(params.end);
  if (start || end) {
    const clock = /^(?:[01]\d|2[0-3]):[0-5]\d$/;
    if (!clock.test(start) || !clock.test(end) || start >= end)
      throw new Error("classroom_time_window_invalid");
    if (params.timeZone != null && params.timeZone !== "Asia/Shanghai")
      throw new Error("classroom_timezone_unsupported");
    const overlaps = TIMES.flatMap(([s, e], i) =>
      s < end && e > start && i + 1 >= first && i + 1 <= last ? [i + 1] : [],
    );
    if (!overlaps.length) {
      // New school-owned time ranges can start at the current clock after the
      // final known class. No mapped section means unknown, never free time.
      // Preserve the historical top-level start/end rejection separately.
      if (params.filters?.timeRange) return { start, end };
      throw new Error("classroom_time_window_no_sections");
    }
    first = overlaps[0];
    last = overlaps[overlaps.length - 1];
  }
  return { first, last, start, end };
}

export async function classroomAvailable(ctx, params = {}) {
  params = applyQueryFilters("classroom.available", params);
  const pg = postgraduate(params);
  const client = await createClient(ctx, "ehall");
  let known = classroomDirectory().find((item) => item.buildingId === params.buildingId);
  if (params.filters?.building || params.filters?.campus) {
    known = (await classroomBuildingsLive(ctx, client)).find((item) => item.buildingId === params.buildingId);
    if (!known || (params.filters.campus && known.campus !== params.filters.campus))
      throw new Error("classroom_campus_building_conflict");
  }
  // Classroom APIs are shared, but the caller's term defaults follow its role.
  const termClient = pg && !text(params.term) ? await createClient(ctx, "yjspt") : client;
  const term = await resolveTerm(termClient, pg, params);
  const date = text(params.date) ? dateOnly(params.date) : "";
  const window = sectionWindow(params);
  const buildingId = text(params.buildingId);
  const buildingName = text(params.building);
  if (!buildingId && !buildingName) throw new Error("classroom_building_required");
  await openApp(client, false, "4768402106681759");
  let building;
  if (buildingId) {
    building = { buildingId, building: buildingName || known?.building || buildingId };
    optional(building, "campus", params.campus ?? known?.campus);
  } else {
    const choices = campusFilter(classroomDirectory(), text(params.campus));
    const exact = choices.filter((b) => b.building === buildingName);
    const matches = exact.length ? exact : choices.filter((b) => b.building.includes(buildingName));
    if (matches.length !== 1 || !matches[0].buildingId) throw new Error("classroom_building_not_unique");
    building = matches[0];
  }
  let week;
  let weekday;
  if (date) {
    const payload = await client.postForm(`${CLASSROOM}/rqzhzcjc.do`, {
      RQ: date,
      XN: term.slice(0, 9),
      XQ: term.slice(-1),
    });
    week = positive(payload?.datas?.rqzhzcjc?.ZC, "week", MAX_WEEKS);
    weekday = positive(payload?.datas?.rqzhzcjc?.XQJ, "weekday", 7);
    if (
      (params.week != null && Number(params.week) !== week) ||
      (params.weekday != null && Number(params.weekday) !== weekday)
    )
      throw new Error("classroom_date_week_conflict");
  } else {
    week = positive(params.week, "week", MAX_WEEKS);
    weekday = positive(params.weekday, "weekday", 7);
  }
  const rows = await pages(
    client,
    `${CLASSROOM}/cxjsqk.do`,
    {
      XNXQDM: term,
      ZC: week,
      XQ: weekday,
      querySetting: JSON.stringify([
        {
          name: "JXLDM",
          caption: "教学楼代码",
          builder: "equal",
          linkOpt: "AND",
          value: building.buildingId,
        },
        { name: "XNXQDM", builder: "equal", linkOpt: "AND", value: term },
        { name: "ZC", builder: "equal", linkOpt: "AND", value: week },
        { name: "XQ", builder: "equal", linkOpt: "AND", value: weekday },
        ...(params.filters?.campus ? [{ name: "XXXQDM", builder: "equal", linkOpt: "AND", value: params.filters.campus }] : []),
      ]),
      "*order": "+LC,+JASMC",
    },
    "cxjsqk",
  );
  let items = rows.map((row) => {
    // Explicit null cells are observed on-device; follow PDA's occupancy
    // predicate for present fields. An absent key remains unknown.
    const sections = TIMES.flatMap(([timeStart, timeEnd], i) =>
      !Object.hasOwn(row, `JC${i + 1}`)
        ? []
        : [
            {
              index: i + 1,
              occupied: String(row[`JC${i + 1}`]).includes("1_"),
              label: `第${i + 1}节`,
              timeStart,
              timeEnd,
            },
          ],
    );
    const selected = window.first === undefined ? [] :
      sections.filter((s) => s.index >= window.first && s.index <= window.last);
    const complete = window.first !== undefined && selected.length === window.last - window.first + 1;
    const any = selected.some((s) => s.occupied);
    const item = {
      ...building,
      room: text(row.JASMC) || "-",
      sections,
      status: !complete
        ? "unknown"
        : !any
          ? "available"
          : selected.every((s) => s.occupied)
            ? "occupied"
            : "partial",
    };
    if (complete || any) item.occupied = any;
    if (date) {
      // Only observed sections are covered. Breaks and missing cells stay
      // unknown; an empty timetable is not evidence that the room is open.
      item.intervals = sections.map((section) => ({
        startAt: new Date(`${date}T${section.timeStart}:00+08:00`).toISOString(),
        endAt: new Date(`${date}T${section.timeEnd}:00+08:00`).toISOString(),
        status: section.occupied ? "occupied" : "available",
        reason: section.occupied
          ? classroomReason(ctx, row[`JC${section.index}`])
          : (ctx.i18n?.t("classroom.availableReason") ?? "教务系统未记录本节占用；不代表教室开放"),
      }));
    }
    optional(item, "roomId", row.JASDM);
    optional(item, "floor", row.LC);
    const typeLabel = text(row.JASLXDM_DISPLAY);
    if (typeLabel) {
      item.roomType = { label: typeLabel };
      optional(item.roomType, "code", row.JASLXDM);
    }
    const teachingCapacity = classroomCapacity(row.SKZWS);
    const examCapacity = classroomCapacity(row.KSZWS);
    if (teachingCapacity !== undefined) item.teachingCapacity = teachingCapacity;
    if (examCapacity !== undefined) item.examCapacity = examCapacity;
    return item;
  });
  if (text(params.roomId)) items = items.filter((item) => item.roomId === text(params.roomId));
  else if (text(params.room)) items = items.filter((item) => item.room.includes(text(params.room)));
  if (params.onlyAvailable === true) items = items.filter((item) => item.status === "available");
  const filters = params.filters ?? {};
  for (const [condition, field] of [["minimumTeachingSeats", "teachingCapacity"], ["minimumExamSeats", "examCapacity"]]) {
    if (filters[condition] !== undefined)
      items = items.filter((item) => item[field] !== undefined && item[field] >= filters[condition]);
  }
  if (filters.roomTypes?.length) items = items.filter((item) => filters.roomTypes.includes(item.roomType?.code));
  const output = {
    term,
    week,
    weekday,
    ...(window.first !== undefined ? { sectionStart: window.first, sectionEnd: window.last } : {}),
    sourceSystem: "西电教务空教室",
    timeZone: "Asia/Shanghai",
    items,
    appliedFilters: { ...filters },
    coverage: {
      complete: true,
      description: `${building.building} · ${date || `${term} / ${week} / ${weekday}`} · 已完成本次楼栋、日期和条件范围的分页；不是全校结果${window.first === undefined ? "；查询时段超出已知课程节次，无法判断空闲" : ""}`,
    },
  };
  if (date) output.date = date;
  if (window.start) {
    output.start = window.start;
    output.end = window.end;
    output.timeZone = "Asia/Shanghai";
  }
  return output;
}

export async function termList(ctx, params = {}) {
  if (params.includePast != null && typeof params.includePast !== "boolean")
    throw new Error("academic_include_past_invalid");
  const pg = postgraduate(params);
  const client = await createClient(ctx, pg ? "yjspt" : "ehall");
  await openApp(client, pg, pg ? "yjsemaphome" : "4770397878132218");
  const term = await currentTerm(client, pg);
  const terms = new Map([[term, { id: term, name: term, academicYear: term.slice(0, 9) }]]);
  // The current-term endpoint cannot enumerate history. Only an explicit
  // includePast request reads the complete grade pages; never invent years.
  if (params.includePast === true) {
    const rows = await gradeRows(client, pg);
    for (const row of rows) {
      const id = gradeTerm(row);
      if (id > term) continue;
      let name = id;
      const display = text(row.XNXQDM_DISPLAY);
      if (display) {
        try {
          // Keep a source label only when it denotes the same normalized term.
          if (gradeTerm({ XNXQDM_DISPLAY: display }) === id) name = display;
        } catch {
          // Optional invalid labels cannot override the verified identifier.
        }
      }
      if (!terms.has(id) || terms.get(id).name === id)
        terms.set(id, { id, name, academicYear: id.slice(0, 9) });
    }
  }
  return { currentTerm: term, items: [...terms.values()].sort((a, b) => b.id.localeCompare(a.id)) };
}

export async function calendarAcademic(ctx, params = {}) {
  const pg = postgraduate(params);
  const client = await createClient(ctx, pg ? "yjspt" : "ehall");
  const term = await resolveTerm(client, pg, params);
  await openApp(client, pg, pg ? "wdkbapp" : "4770397878132218");
  const startDate = await termStart(client, pg, term);
  // No inferred end date/holidays: neither proven API provides those fields.
  // PDA classtable_controller.dart getCurrentWeek: elapsed calendar days / 7.
  // School days use Asia/Shanghai regardless of the device's current timezone.
  const today = new Date(ctx.now() + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const elapsedDays = (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${startDate}T00:00:00Z`)) / 86400000;
  const currentWeek = Math.floor(elapsedDays / 7) + 1;
  return { term, startDate, ...(currentWeek >= 1 ? { currentWeek } : {}) };
}
