// Copyright 2026 elecon contributors. SPDX-License-Identifier: MIT
// Entirely synthetic responses; no school network or student data.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  calendarAcademic,
  classroomAvailable,
  classroomBuildings,
  examList,
  gradesList,
  scheduleWeek,
  termList,
} from "../src/academic.js";
import { createQueryControls } from "../src/query_controls.js";
import { validateQueryFilters } from "../src/query_filters.js";

const TERM = "2025-2026-1";
const ajv = new Ajv2020({ strict: false });
addFormats(ajv);
const validators = new Map();
function valid(capability, output) {
  let validate = validators.get(capability);
  if (!validate) {
    validate = ajv.compile(
      JSON.parse(
        readFileSync(new URL(`../../../contract/schema/${capability}.schema.json`, import.meta.url), "utf8"),
      ),
    );
    validators.set(capability, validate);
  }
  assert.ok(validate(output), JSON.stringify(validate.errors));
  return output;
}

function payload(name, rows, total = rows.length, extra = {}) {
  return {
    code: "0",
    datas: {
      [name]: { rows, extParams: { code: 1 }, ...(total == null ? {} : { totalSize: total }), ...extra },
    },
  };
}

function fake(route, { studentId = "demo-student" } = {}) {
  const calls = [];
  const records = new Map(
    ["ehall", "yjspt"].map((service) => [
      service,
      {
        value: JSON.stringify({ version: 1, service, cookies: [], data: studentId ? { studentId } : {} }),
      },
    ]),
  );
  return {
    calls,
    credentials: {
      async get(key, options) {
        assert.equal(options.namespace, "xidian.auth");
        return records.get(key) ?? null;
      },
      async set(key, value) {
        records.set(key, { value });
      },
    },
    now: () => Date.parse("2025-09-20T00:00:00Z"),
    async fetch(url, init = {}) {
      const parsed = new URL(url);
      const call = {
        url: parsed,
        init,
        form: Object.fromEntries(new URLSearchParams(init.body ?? "")),
        query: Object.fromEntries(parsed.searchParams),
      };
      calls.push(call);
      let response;
      if ((init.method ?? "GET") === "GET") response = {};
      else response = await route(call);
      assert.notEqual(response, undefined, `Unexpected request: ${parsed.pathname}`);
      return {
        status: 200,
        ok: true,
        url,
        headers: { get: () => null, getSetCookie: () => [] },
        json: async () => response,
        text: async () => JSON.stringify(response),
      };
    },
  };
}

function ugCalendar(call) {
  if (call.url.pathname.endsWith("/cxjcs.do")) return payload("cxjcs", [{ XQKSRQ: "2025-09-01" }]);
  if (call.url.pathname.endsWith("/dqxnxq.do")) return payload("dqxnxq", [{ DM: TERM }]);
}

const ugCourse = {
  KCM: "合成课程甲",
  KCH: "course-a",
  KXH: "01",
  SKJS: "合成教师",
  JASMC: "合成教室一",
  KSJC: "1",
  JSJC: "4",
  SKXQ: "1",
  SKZC: "111",
};

test("UG bitmap week indexing, actual dates, empty week, and exact student id", async () => {
  const ctx = fake((call) => {
    const calendar = ugCalendar(call);
    if (calendar) return calendar;
    if (call.url.pathname.endsWith("/xskcb.do")) {
      assert.equal(call.form.XH, "demo-student");
      return payload("xskcb", [{ ...ugCourse, SKZC: "101", SKXQ: "2", JSJC: "2" }]);
    }
    if (call.url.pathname.endsWith("/xsdkkc.do")) return payload("xsdkkc", []);
  });
  const result = valid("schedule.week", await scheduleWeek(ctx, { term: TERM, week: 3 }));
  assert.equal(result.days[1].slots[0].date, "2025-09-16");
  assert.deepEqual(result.days[1].slots[0].weeks, [1, 3]);
  assert.equal(result.days[1].slots[0].timeStart, "08:30");
  assert.equal(result.timeSegments.length, 11);
  assert.deepEqual(result.timeSegments[0], { label: "1", timeStart: "08:30", timeEnd: "09:15" });
  assert.equal(result.weekPreviews[0].days[1].courseCount, 1);
  assert.equal(result.weekPreviews[1].days[1].courseCount, 0);
  assert.equal(result.weekPreviews[2].days[1].courseCount, 1);
  assert.deepEqual(result.termWeeks[2].days, result.days);
  assert.equal(result.termWeeks[1].days.flatMap((day) => day.slots).length, 0);
  assert.equal(result.termWeeks[2].teachingWeekStart, result.teachingWeekStart);
  assert.equal(ctx.calls.filter((c) => c.url.pathname.endsWith("/xskcb.do")).length, 1);
  const empty = await scheduleWeek(ctx, { term: TERM, week: 2 });
  assert.equal(empty.days.flatMap((day) => day.slots).length, 0);
});

test("home schedule query resolves the current week within the script", async () => {
  const ctx = fake((call) => {
    if (call.url.pathname.endsWith("/xskcb.do")) return payload("xskcb", []);
    if (call.url.pathname.endsWith("/xsdkkc.do")) return payload("xsdkkc", []);
    return ugCalendar(call);
  });
  const result = valid("schedule.week", await scheduleWeek(ctx, { term: TERM }));
  assert.equal(result.week, 3);
  assert.equal(result.term, TERM);
});

test("calendar starts need not be Monday when deriving a slot date", async () => {
  const ctx = fake((call) => {
    if (call.url.pathname.endsWith("/cxjcs.do")) return payload("cxjcs", [{ XQKSRQ: "2025-08-31" }]);
    if (call.url.pathname.endsWith("/xskcb.do")) return payload("xskcb", [ugCourse]);
    return payload("xsdkkc", []);
  });
  const result = valid("schedule.week", await scheduleWeek(ctx, { term: TERM, week: 1 }));
  assert.equal(result.teachingWeekStart, "2025-08-31");
  assert.equal(result.days[0].slots[0].date, "2025-09-01");
});

test("UG partial stop, chained moves, different class numbers, and a new makeup course", async () => {
  const changes = [
    {
      TKLXDM: "02",
      KCH: "course-a",
      KXH: "01",
      KCM: ugCourse.KCM,
      SKZC: "010",
      KSJC: "2",
      JSJC: "3",
      SKXQ: "1",
      JASMC: "合成教室一",
      SQSJ: "2025-09-01 08:00:00",
    },
    {
      TKLXDM: "01",
      KCH: "course-a",
      KXH: "01",
      KCM: ugCourse.KCM,
      SKZC: "001",
      XSKZC: "001",
      KSJC: "1",
      JSJC: "4",
      SKXQ: "1",
      JASMC: "合成教室一",
      XKSJC: "5",
      XJSJC: "6",
      XSKXQ: "3",
      XJASMC: "合成教室二",
      SQSJ: "2025-09-02 08:00:00",
    },
    {
      TKLXDM: "01",
      KCH: "course-a",
      KXH: "01",
      KCM: ugCourse.KCM,
      SKZC: "001",
      XSKZC: "001",
      KSJC: "5",
      JSJC: "6",
      SKXQ: "3",
      JASMC: "合成教室二",
      XKSJC: "7",
      XJSJC: "8",
      XSKXQ: "5",
      XJASMC: "合成教室三",
      SQSJ: "2025-09-03 08:00:00",
    },
    {
      TKLXDM: "03",
      KCH: "course-b",
      KXH: "01",
      KCM: "合成补课",
      XSKZC: "010",
      XKSJC: "9",
      XJSJC: "10",
      XSKXQ: "2",
      XJASMC: "合成教室四",
      SQSJ: "2025-09-04 08:00:00",
    },
  ];
  const ctx = fake(
    (call) =>
      ugCalendar(call) ??
      (call.url.pathname.endsWith("/xskcb.do")
        ? payload("xskcb", [ugCourse, { ...ugCourse, KXH: "02" }])
        : payload("xsdkkc", [...changes].reverse())),
  );
  const week2 = valid("schedule.week", await scheduleWeek(ctx, { term: TERM, week: 2 }));
  assert.deepEqual(
    week2.days[0].slots.filter((s) => s.classNo === "01").map((s) => [s.start, s.end]),
    [
      ["1", "1"],
      ["4", "4"],
    ],
  );
  assert.equal(week2.days[1].slots[0].changeType, "makeup");
  assert.deepEqual(week2.days[0].slots.find((s) => s.classNo === "02").weeks, [1, 2, 3]);
  const week3 = valid("schedule.week", await scheduleWeek(ctx, { term: TERM, week: 3 }));
  assert.equal(week3.days[0].slots.length, 1);
  assert.equal(week3.days[2].slots.length, 0);
  assert.equal(week2.weekPreviews[1].days[0].courseCount, week2.days[0].slots.length);
  assert.equal(week2.weekPreviews[2].days[0].courseCount, week3.days[0].slots.length);
  assert.deepEqual(week2.termWeeks[2].days, week3.days);
  assert.equal(week2.weekPreviews[2].days[2].courseCount, 0);
  assert.deepEqual(
    week3.days[4].slots.map((s) => [s.start, s.end, s.room, s.changeType]),
    [["7", "8", "合成教室三", "rescheduled"]],
  );
});

test("schedule schema retains 1.0 and rejects malformed 1.1 hints", () => {
  const schema = JSON.parse(
    readFileSync(new URL("../../../contract/schema/schedule.week.schema.json", import.meta.url), "utf8"),
  );
  const validate = new Ajv2020({ strict: false, validateFormats: false }).compile(schema);
  const oldSchema = JSON.parse(
    readFileSync(
      new URL("../../../contract/schema-versions/schedule.week/1.0.schema.json", import.meta.url),
      "utf8",
    ),
  );
  const validateOld = new Ajv2020({ strict: false, validateFormats: false }).compile(oldSchema);
  const data = { term: TERM, week: 1, days: [] };
  assert.ok(validate(data));
  assert.ok(validateOld(data));
  assert.equal(
    validate({ ...data, timeSegments: [{ label: "1", timeStart: "25:00", timeEnd: "26:00" }] }),
    false,
  );
  assert.equal(
    validate({ ...data, weekPreviews: [{ week: 1, days: [{ dayOfWeek: 8, courseCount: 0 }] }] }),
    false,
  );
  assert.equal(
    validate({ ...data, weekPreviews: [{ week: 1, days: [{ dayOfWeek: 1, courseCount: -1 }] }] }),
    false,
  );
});

test("makeup prefers explicit original teacher and room over another arrangement of the course", async () => {
  const original = { ...ugCourse, SKZC: "1", JSJC: "2" };
  const makeup = {
    TKLXDM: "03",
    KCH: original.KCH,
    KXH: original.KXH,
    KCM: original.KCM,
    SKZC: "1",
    YSKJS: "合成教师乙",
    JASMC: "合成教室乙",
    XKSJC: "3",
    XJSJC: "4",
    XSKXQ: "3",
  };
  const ctx = fake(
    (call) =>
      ugCalendar(call) ??
      (call.url.pathname.endsWith("/xskcb.do")
        ? payload("xskcb", [original, { ...original, SKXQ: "2", SKJS: makeup.YSKJS, JASMC: makeup.JASMC }])
        : payload("xsdkkc", [makeup])),
  );
  const result = valid("schedule.week", await scheduleWeek(ctx, { term: TERM, week: 1 }));
  assert.equal(result.days[2].slots.length, 1);
  assert.equal(result.days[2].slots[0].teacher, makeup.YSKJS);
  assert.equal(result.days[2].slots[0].room, makeup.JASMC);
  assert.equal(result.days[2].slots[0].changeType, "makeup");
});

test("an already applied move replaces overlapping destination sections without duplicating adjacent ones", async () => {
  const destination = { ...ugCourse, SKZC: "1", SKXQ: "3", JASMC: "合成目的教室", JSJC: "2" };
  const move = {
    TKLXDM: "01",
    KCH: ugCourse.KCH,
    KXH: ugCourse.KXH,
    KCM: ugCourse.KCM,
    SKZC: "1",
    XSKZC: "1",
    KSJC: "1",
    JSJC: "2",
    SKXQ: "1",
    JASMC: ugCourse.JASMC,
    XKSJC: "1",
    XJSJC: "2",
    XSKXQ: "3",
    XJASMC: destination.JASMC,
  };
  const ctx = fake(
    (call) =>
      ugCalendar(call) ??
      (call.url.pathname.endsWith("/xskcb.do")
        ? payload("xskcb", [destination, { ...destination, KSJC: "3", JSJC: "4" }])
        : payload("xsdkkc", [move])),
  );
  const result = valid("schedule.week", await scheduleWeek(ctx, { term: TERM, week: 1 }));
  assert.equal(result.days[0].slots.length, 0);
  assert.deepEqual(
    result.days[2].slots.map((slot) => [slot.start, slot.end, slot.changeType]),
    [
      ["1", "2", "rescheduled"],
      ["3", "4", "none"],
    ],
  );
  assert.ok(result.days[2].slots.every((slot) => slot.room === destination.JASMC));
});

test("PG timetable uses its own fields and JSON-string calendar, no XH required", async () => {
  const ctx = fake(
    (call) => {
      assert.equal(call.url.hostname, "yjspt.xidian.edu.cn");
      if (call.url.pathname.endsWith("/getSchoolCalendar.do"))
        return { msg: JSON.stringify({ QSRQ: "2025-09-01 00:00:00" }) };
      return payload(
        "xspkjgcx",
        [3, 4].map((section) => ({
          KCMC: "合成研究课程",
          KCDM: "pg-a",
          KSJCDM: section,
          JSJCDM: section,
          XQ: 3,
          ZCBH: "0101",
          JSXM: "合成教师",
          JASMC: "研究教室",
        })),
      );
    },
    { studentId: null },
  );
  const result = valid(
    "schedule.week",
    await scheduleWeek(ctx, { role: "postgraduate", term: TERM, week: 2 }),
  );
  assert.equal(result.days[2].slots[0].courseId, "pg-a");
  assert.equal(result.days[2].slots.length, 1);
  assert.deepEqual([result.days[2].slots[0].start, result.days[2].slots[0].end], ["3", "4"]);
  assert.deepEqual(result.days[2].slots[0].weeks, [2, 4]);
});

function grade(index, extra = {}) {
  return {
    XNXQDM: TERM,
    KCH: `example-synthetic-${index}`,
    XSKCM: `合成课程${index}`,
    XF: "2.5",
    ZCJ: "90",
    DJCJLXDM: "00",
    KCXZDM_DISPLAY: "必修",
    ...extra,
  };
}

test("grades follow multiple pages, retain levels/zero/retake semantics and filter terms", async () => {
  const rows = Array.from({ length: 201 }, (_, i) => grade(i));
  rows[0] = grade(0, { DJCJLXDM: "01", DJCJMC: "优秀", ZCJ: "85", CXCKDM_DISPLAY: "重修" });
  rows[1] = grade(1, { ZCJ: "0" });
  rows[2] = grade(2, { DJCJLXDM: "03", DJCJMC: "不合格", SFJG: "0" });
  rows[3] = grade(3, { XNXQDM: "2024-2025-2" });
  rows[4] = grade(4, { ZCJ: "", SFJG: "1" });
  const ctx = fake((call) => {
    const page = Number(call.form.pageNumber);
    assert.equal(Number(call.form.pageSize), 200);
    assert.deepEqual(JSON.parse(call.form.querySetting), {
      name: "SFYX",
      value: "1",
      linkOpt: "and",
      builder: "m_value_equal",
    });
    assert.equal(call.form["*json"], "1");
    assert.equal(call.form["*order"], "+XNXQDM,KCH,KXH");
    return payload("xscjcx", rows.slice((page - 1) * 200, page * 200), 201);
  });
  const result = valid("grades.list", await gradesList(ctx, { term: TERM }));
  assert.equal(result.items.length, 200);
  assert.equal(result.gradePointScale, "unknown");
  assert.deepEqual(result.items[0].score, { kind: "letter", value: "优秀", raw: "优秀", status: "known" });
  assert.equal(result.items[0].retake, true);
  assert.equal(result.items[0].status, "unknown");
  assert.equal(result.items[0].sourceStatus, "retake");
  assert.equal(result.items[1].score.value, 0);
  assert.equal(result.items[2].score.kind, "passfail");
  assert.equal(result.items[3].score.value, "通过");
  assert.ok(result.items.every((item) => item.gradePoint === undefined));
});

test("PG scores use display term, source grading kind and exam source", async () => {
  const ctx = fake((call) => {
    assert.deepEqual(JSON.parse(call.form.querySetting), []);
    assert.equal(call.form["*json"], undefined);
    assert.equal(call.form["*order"], undefined);
    return payload("xscjcx", [
      {
        KCDM: "pg-score",
        KCMC: "研究课程",
        XNXQDM_DISPLAY: "2025-2026学年第一学期",
        XF: 2,
        DYBFZCJ: 85,
        CJFZDM: "2",
        CJXSZ: "良好",
        SFJG: 1,
        KCLBMC: "专业必修",
        KSXZDM_DISPLAY: "补考",
      },
    ]);
  });
  const result = valid("grades.list", await gradesList(ctx, { role: "postgraduate", term: TERM }));
  assert.equal(result.items[0].score.value, "良好");
  assert.equal(result.items[0].sourceStatus, "makeup");
  assert.equal(result.items[0].category, "required");
});

test("missing grade term is rejected rather than mixing all terms", async () => {
  const ctx = fake(() => payload("xscjcx", [grade(1, { XNXQDM: "" })]));
  await assert.rejects(gradesList(ctx, { term: TERM }), /academic_grade_term_missing/);
});

test("pagination rejects repeated pages, early termination, and budget exhaustion", async () => {
  const repeated = Array.from({ length: 200 }, (_, i) => grade(i));
  await assert.rejects(
    gradesList(
      fake(() => payload("xscjcx", repeated, 401)),
      { term: TERM },
    ),
    /academic_pagination_repeated/,
  );
  await assert.rejects(
    gradesList(
      fake((call) => payload("xscjcx", Number(call.form.pageNumber) === 1 ? [grade(1)] : [], 2)),
      { term: TERM },
    ),
    /academic_pagination_incomplete/,
  );
  await assert.rejects(
    gradesList(
      fake((call) => payload("xscjcx", [grade(call.form.pageNumber)], 9)),
      { term: TERM },
    ),
    /academic_pagination_limit/,
  );
});

test("UG exams preserve pending courses and convert Chinese wall clock to UTC", async () => {
  const ctx = fake((call) => {
    assert.equal(call.form.XNXQDM, undefined); // observed API uses query parameters
    assert.equal(call.query.XNXQDM, TERM);
    return call.url.pathname.endsWith("/wdksap.do")
      ? payload("wdksap", [
          {
            KCM: "合成考试",
            KCH: "exam-a",
            KSSJMS: "2026-01-02 8::30-10:30",
            JASMC: "测试考场",
            ZWH: "12",
            KSMC: "期末考试",
          },
          { KCM: "取消考试", KSSJMS: "已取消" },
        ])
      : payload("cxyxkwapkwdkc", [{ KCM: "待安排考试", KCH: "exam-pending" }]);
  });
  const result = valid("exam.list", await examList(ctx, { term: TERM }));
  assert.equal(result.items[0].examAt, "2026-01-02T00:30:00.000Z");
  assert.equal(result.items[0].seat, "12");
  assert.equal(result.items[1].status, "cancelled");
  assert.equal(result.items[2].status, "unknown");
  assert.equal(result.items[2].examAt, undefined);
  assert.match(result.items[2].changeReason, /尚未安排/);
});

test("PG exams send student/term/publication filters and parse weekday parentheses", async () => {
  const ctx = fake(
    (call) => {
      const filters = JSON.parse(call.query.querySetting);
      assert.equal(filters.find((item) => item.name === "XH").value, "explicit-demo");
      assert.equal(filters.find((item) => item.name === "SFFBKSAP").value, "1");
      return payload("wdksxxcx", [
        {
          KCMC: "研究考试",
          KSSJMS: "2026-01-02 周五(08:30-10:30)",
          KSLXDM_DISPLAY: "期末",
          JASMC: "研究教室",
        },
      ]);
    },
    { studentId: null },
  );
  const result = valid(
    "exam.list",
    await examList(ctx, { role: "postgraduate", studentId: "explicit-demo", term: TERM }),
  );
  assert.equal(result.items[0].examAt, "2026-01-02T00:30:00.000Z");
  assert.equal(result.items[0].seat, undefined);
  // Explicit account input is now saved for the next query in this school.
  await examList(ctx, { role: "postgraduate", term: TERM });
  await assert.rejects(
    examList(
      fake(() => assert.fail("missing id must fail before exam I/O"), { studentId: null }),
      { role: "postgraduate", term: TERM },
    ),
    /student_id_required/,
  );
});

const buildingRows = [{ JXLDM: "demo-building", JXLJC: "测试楼", XXXQDM: "S", XXXQDM_DISPLAY: "南校区" }];
function room(index, extra = {}) {
  return {
    JASMC: `测试教室${index}`,
    JASDM: `room-${index}`,
    LC: "1",
    ...Object.fromEntries(Array.from({ length: 11 }, (_, i) => [`JC${i + 1}`, "0_"])),
    ...extra,
  };
}
function classroomsRoute(call) {
  if (call.url.pathname.endsWith("/jxlcx.do")) return payload("jxlcx", buildingRows);
  if (call.url.pathname.endsWith("/rqzhzcjc.do")) return { datas: { rqzhzcjc: { ZC: "3", XQJ: "2" } } };
  if (call.url.pathname.endsWith("/cxjsqk.do")) {
    const filters = JSON.parse(call.form.querySetting);
    assert.equal(filters.filter((filter) => filter.name === "ZC").length, 1);
    assert.equal(filters.find((filter) => filter.name === "XQ").value, 2);
    const missing = room(3);
    delete missing.JC1;
    return payload("cxjsqk", [room(1, { JC2: "1_course" }), room(2), missing]);
  }
}

test("classroom building/campus and date conversion with correct XQ filter", async () => {
  const ctx = fake(classroomsRoute);
  const list = valid("classroom.buildings", await classroomBuildings(ctx, { campus: "S" }));
  assert.ok(list.items.some((item) => item.buildingId === "A" && item.building === "A教学楼"));
  assert.ok(list.items.every((item) => item.campus === "S"));
  assert.equal(ctx.calls.length, 0, "the built-in directory needs no school request");
  const result = valid(
    "classroom.available",
    await classroomAvailable(ctx, {
      term: TERM,
      date: "2025-09-16",
      buildingId: "demo-building",
      sectionStart: 1,
      sectionEnd: 2,
    }),
  );
  assert.equal(result.week, 3);
  assert.equal(result.weekday, 2);
  assert.deepEqual(
    result.items.map((item) => item.status),
    ["partial", "available", "unknown"],
  );
  assert.equal(result.items[0].sections.length, 11);
  assert.equal(result.items[2].occupied, undefined);
});

test("classroom supports week/day and wall-clock window with onlyAvailable", async () => {
  const ctx = fake(classroomsRoute);
  const result = valid(
    "classroom.available",
    await classroomAvailable(ctx, {
      term: TERM,
      week: 3,
      weekday: 2,
      building: "A教学楼",
      start: "08:30",
      end: "10:05",
      onlyAvailable: true,
    }),
  );
  assert.deepEqual(
    result.items.map((item) => item.roomId),
    ["room-2"],
  );
  assert.equal(result.timeZone, "Asia/Shanghai");
  assert.equal(result.date, undefined);
  assert.equal(result.sectionEnd, 2);
  assert.equal(
    ctx.calls.some((call) => call.url.pathname.endsWith("/rqzhzcjc.do")),
    false,
  );
});

test("classroom does not silently choose an ambiguous building or conflicting date", async () => {
  const ambiguous = fake((call) =>
    call.url.pathname.endsWith("/jxlcx.do")
      ? payload("jxlcx", [buildingRows[0], { ...buildingRows[0], JXLDM: "other" }])
      : classroomsRoute(call),
  );
  await assert.rejects(
    classroomAvailable(ambiguous, { term: TERM, date: "2025-09-16", building: "E教学楼" }),
    /classroom_building_not_unique/,
  );
  await assert.rejects(
    classroomAvailable(fake(classroomsRoute), {
      term: TERM,
      date: "2025-09-16",
      week: 9,
      buildingId: "demo-building",
    }),
    /classroom_date_week_conflict/,
  );
});

test("term/current calendar capabilities expose only proven fields for both roles", async () => {
  const ug = fake(ugCalendar);
  const ugTerm = valid("term.list", await termList(ug));
  assert.equal(ugTerm.currentTerm, TERM);
  assert.equal(ugTerm.items.length, 1);
  assert.equal(
    ug.calls.some((call) => call.url.pathname.endsWith("/xscjcx.do")),
    false,
  );
  const ugCal = valid("calendar.academic", await calendarAcademic(ug, { term: TERM }));
  assert.deepEqual(ugCal, { term: TERM, startDate: "2025-09-01", currentWeek: 3 });
  const pg = fake((call) =>
    call.url.pathname.endsWith("/getUserInfo.do")
      ? { code: "0", data: { xnxqdm: TERM } }
      : { msg: { QSRQ: "2025-09-01 00:00:00" } },
  );
  assert.equal(valid("term.list", await termList(pg, { role: "postgraduate" })).currentTerm, TERM);
  assert.equal(
    pg.calls.some((call) => call.url.pathname.endsWith("/xscjcx.do")),
    false,
  );
  assert.deepEqual(valid("calendar.academic", await calendarAcademic(pg, { role: "postgraduate" })), ugCal);
});

for (const pg of [false, true]) {
  test(`${pg ? "PG" : "UG"} historical terms come only from complete grade pages`, async () => {
    const historical = "2024-2025-2";
    const older = "2023-2024-1";
    const row = (term) =>
      pg
        ? { XNXQDM_DISPLAY: term.replace(/-([12])$/, "学年第$1学期") }
        : { XNXQDM: term, XNXQDM_DISPLAY: term.replace(/-([12])$/, "学年第$1学期") };
    const rows = [
      ...Array.from({ length: 199 }, () => row(historical)),
      row("2026-2027-1"), // A future row is not a past-term option.
      row(older),
    ];
    const ctx = fake((call) => {
      if (call.url.pathname.endsWith("/getUserInfo.do")) return { code: "0", data: { xnxqdm: TERM } };
      if (call.url.pathname.endsWith("/dqxnxq.do")) return payload("dqxnxq", [{ DM: TERM }]);
      assert.ok(call.url.pathname.endsWith("/xscjcx.do"));
      assert.deepEqual(
        JSON.parse(call.form.querySetting),
        pg
          ? []
          : {
              name: "SFYX",
              value: "1",
              linkOpt: "and",
              builder: "m_value_equal",
            },
      );
      const page = Number(call.form.pageNumber);
      return payload("xscjcx", rows.slice((page - 1) * 200, page * 200), rows.length);
    });
    const result = valid(
      "term.list",
      await termList(ctx, {
        role: pg ? "postgraduate" : "undergraduate",
        includePast: true,
      }),
    );
    assert.equal(result.currentTerm, TERM);
    assert.deepEqual(
      result.items.map((item) => item.id),
      [TERM, historical, older],
    );
    assert.equal(result.items[1].name, "2024-2025学年第2学期");
    assert.equal(result.items[2].academicYear, "2023-2024");
    assert.equal(ctx.calls.filter((call) => call.url.pathname.endsWith("/xscjcx.do")).length, 2);
    const controls = valid(
      "query.controls",
      await createQueryControls(pg ? "postgraduate" : "undergraduate")(ctx, { target: "grades.list" }),
    );
    assert.equal(controls.controls[0].id, "term");
    assert.equal(controls.controls[0].initialValue, TERM);
    assert.deepEqual(
      controls.controls[0].options,
      result.items.map(({ id, name }) => ({ value: id, label: name })),
    );
  });
}

test("historical term discovery rejects invalid identities and incomplete pages", async () => {
  const ctx = fake((call) =>
    call.url.pathname.endsWith("/dqxnxq.do")
      ? payload("dqxnxq", [{ DM: TERM }])
      : payload("xscjcx", [{ XNXQDM: "2024-2026-1" }]),
  );
  await assert.rejects(termList(ctx, { includePast: true }), /academic_term_invalid/);
  const incomplete = fake((call) =>
    call.url.pathname.endsWith("/dqxnxq.do")
      ? payload("dqxnxq", [{ DM: TERM }])
      : payload("xscjcx", Number(call.form.pageNumber) === 1 ? [{ XNXQDM: TERM }] : [], 2),
  );
  await assert.rejects(termList(incomplete, { includePast: true }), /academic_pagination_incomplete/);
  const invalid = fake(() => undefined);
  await assert.rejects(termList(invalid, { includePast: "true" }), /academic_include_past_invalid/);
  assert.equal(invalid.calls.length, 0);
});

test("opening an academic app with ordinary 403 does not report expired authentication", async () => {
  const ctx = fake(() => undefined);
  let calls = 0;
  ctx.fetch = async (url) => {
    calls++;
    return { status: 403, url, headers: { get: () => null, getSetCookie: () => [] } };
  };
  await assert.rejects(gradesList(ctx, { term: TERM }), /academic_app_open_failed/);
  assert.equal(calls, 1);
});

test("current week follows China midnight and school term start rather than device timezone", async () => {
  for (const [now, week] of [
    ["2025-08-31T15:59:59Z", undefined],
    ["2025-08-31T16:00:00Z", 1],
    ["2025-09-07T15:59:59Z", 1],
    ["2025-09-07T16:00:00Z", 2],
  ]) {
    const ctx = fake(ugCalendar);
    ctx.now = () => Date.parse(now);
    const out = valid("calendar.academic", await calendarAcademic(ctx, { term: TERM }));
    assert.equal(out.currentWeek, week);
  }
});

test("the school script requests a missing student id and persists only its submitted value", async () => {
  const ctx = fake(
    (call) => ugCalendar(call) ?? payload(call.url.pathname.endsWith("/xsdkkc.do") ? "xsdkkc" : "xskcb", []),
    { studentId: null },
  );
  let prompts = 0;
  ctx.ui = {
    requestInput: async (request) => {
      prompts++;
      assert.equal(request.fields[0].id, "studentId");
      return { studentId: "EXAMPLE_SYNTHETIC_STUDENT" };
    },
  };
  await scheduleWeek(ctx, { term: TERM, week: 3 });
  assert.equal(prompts, 1);
  assert.equal(
    JSON.parse((await ctx.credentials.get("ehall", { namespace: "xidian.auth" })).value).data.studentId,
    "EXAMPLE_SYNTHETIC_STUDENT",
  );
  await scheduleWeek(ctx, { term: TERM, week: 3 });
  assert.equal(prompts, 1);
});

test("cancelling the school script's student form cannot continue its schedule API request", async () => {
  const ctx = fake(ugCalendar, { studentId: null });
  ctx.ui = { requestInput: async () => null };
  await assert.rejects(
    scheduleWeek(ctx, { term: TERM, week: 3 }),
    (error) => error.code === "input_cancelled",
  );
  assert.ok(!ctx.calls.some((call) => call.url.pathname.endsWith("/xskcb.do")));
});

test("exam API uses top-level success and array rows, independently of timetable extParams codes", async () => {
  const ctx = fake((call) => {
    const name = call.url.pathname.endsWith("/wdksap.do") ? "wdksap" : "cxyxkwapkwdkc";
    return payload(name, [], 0, { extParams: { code: 0 } });
  });
  assert.deepEqual((await examList(ctx, { term: TERM })).items, []);
  for (const invalid of [
    { code: "1", datas: { wdksap: { rows: [], extParams: { code: 1 } } } },
    { datas: { wdksap: { rows: [] } } },
    { code: "0", datas: { wdksap: { rows: null } } },
  ]) {
    await assert.rejects(
      examList(
        fake(() => invalid),
        { term: TERM },
      ),
      /academic_response_invalid/,
    );
  }
});

test("invalid role/week and missing required student id fail explicitly", async () => {
  await assert.rejects(scheduleWeek({}, { role: "other", week: 1 }), /academic_role_invalid/);
  await assert.rejects(scheduleWeek({}, { week: 0 }), /academic_week_invalid/);
  await assert.rejects(
    scheduleWeek(fake(ugCalendar, { studentId: null }), { term: TERM, week: 1 }),
    /student_id_required/,
  );
});

test("classroom id query does not refetch the building directory", async () => {
  const ctx = fake(classroomsRoute);
  await classroomAvailable(ctx, {
    term: TERM,
    date: "2025-09-16",
    buildingId: "demo-building",
    building: "测试楼",
  });
  assert.equal(
    ctx.calls.some((call) => call.url.pathname.endsWith("/jxlcx.do")),
    false,
  );
});

test("explicit null sections are free; absent sections remain unknown", async () => {
  const ctx = fake((call) => {
    if (call.url.pathname.endsWith("/cxjsqk.do")) {
      const empty = room(1, Object.fromEntries(Array.from({ length: 11 }, (_, i) => [`JC${i + 1}`, null])));
      const missing = { ...empty, JASMC: "Synthetic missing room" };
      delete missing.JC4;
      return payload("cxjsqk", [empty, missing, { ...empty, JC2: "1_synthetic" }]);
    }
    return classroomsRoute(call);
  });
  const result = valid(
    "classroom.available",
    await classroomAvailable(ctx, { term: TERM, week: 3, weekday: 2, buildingId: "demo-building" }),
  );
  assert.deepEqual(
    result.items.map((item) => item.status),
    ["available", "unknown", "partial"],
  );
  assert.equal(result.items[0].sections.length, 11);
  assert.ok(result.items[0].sections.every((section) => section.occupied === false));
  assert.equal(result.items[1].occupied, undefined);
});

test("classroom absolute intervals retain uncovered breaks and missing section evidence", async () => {
  const result = valid(
    "classroom.available",
    await classroomAvailable(fake(classroomsRoute), {
      term: TERM,
      date: "2025-09-16",
      buildingId: "demo-building",
    }),
  );
  assert.equal(result.timeZone, "Asia/Shanghai");
  const first = result.items[0].intervals;
  assert.equal(first[0].startAt, "2025-09-16T00:30:00.000Z");
  assert.equal(first[0].endAt, "2025-09-16T01:15:00.000Z");
  assert.equal(first[0].status, "available");
  assert.match(first[0].reason, /不代表教室开放/);
  assert.equal(first[1].status, "occupied");
  assert.ok(Date.parse(first[0].endAt) < Date.parse(first[1].startAt), "break remains uncovered");
  assert.equal(result.items[2].intervals.length, 10, "missing JC1 remains unknown");
  const undated = await classroomAvailable(fake(classroomsRoute), {
    term: TERM,
    week: 3,
    weekday: 2,
    buildingId: "demo-building",
  });
  assert.equal(undated.items[0].intervals, undefined, "do not invent dates for week-only queries");
});

test("query controls declare school-local classroom inputs and reject command targets without I/O", async () => {
  const ctx = { now: () => Date.parse("2026-11-03T16:05:00Z"), i18n: { t: (key) => `translated:${key}` } };
  const query = createQueryControls("undergraduate");
  const out = valid("query.controls", await query(ctx, { target: "classroom.available" }));
  assert.equal(out.controls[0].initialValue, "2026-11-04");
  assert.equal(out.submitLabel, "translated:query.submit");
  assert.deepEqual(
    out.controls.map((item) => item.id),
    ["date", "building", "room", "timeRange", "minimumTeachingSeats", "minimumExamSeats", "roomTypes", "onlyAvailable"],
  );
  await assert.rejects(query(ctx, { target: "climate.command" }), /input_invalid_request/);
  await assert.rejects(query(ctx, { target: "grades.list", operation: "login" }), /input_invalid_request/);
  const denied = {
    ...ctx,
    credentials: { get: async () => null },
    browser: { open: () => assert.fail("metadata must not open login") },
  };
  await assert.rejects(query(denied, { target: "grades.list" }), /xidian_login_required_ehall/);
});

test("school-owned grade filters select a term without changing the legacy term input", async () => {
  const previous = "2024-2025-2";
  const rows = [grade(1), grade(2, { XNXQDM: previous })];
  const result = valid("grades.list", await gradesList(fake(() => payload("xscjcx", rows)), {
    term: TERM, filters: { term: previous },
  }));
  assert.equal(result.term, previous);
  assert.equal(result.items.length, 1);
  assert.equal((await gradesList(fake(() => payload("xscjcx", rows)), { term: TERM })).items.length, 1);
});

function richClassroomsRoute(call) {
  if (call.url.pathname.endsWith("/getUserInfo.do")) return { code: "0", data: { xnxqdm: TERM } };
  if (call.url.pathname.endsWith("/dqxnxq.do")) return payload("dqxnxq", [{ DM: TERM }]);
  if (call.url.pathname.endsWith("/cxjsqk.do")) return payload("cxjsqk", [
    room(1, { JASLXDM: "demo-media", JASLXDM_DISPLAY: "合成多媒体教室", SKZWS: "120", KSZWS: 60,
      JC1: "1_01,1_04,0_03", JC2: "1_02,1_03,1_05" }),
    room(2, { JASLXDM: "demo-lab", JASLXDM_DISPLAY: "合成实验室", SKZWS: 80, KSZWS: null }),
    room(3, { JASLXDM: null, JASLXDM_DISPLAY: "", SKZWS: null, KSZWS: "" }),
    room(4, { JASLXDM: "demo-media", JASLXDM_DISPLAY: "合成多媒体教室", SKZWS: 0, KSZWS: 0 }),
  ]);
  return classroomsRoute(call);
}

const richSelection = { date: "2025-09-16", building: "demo-building" };

test("classroom type, separate capacities and multiple occupancy reasons preserve source meanings", async () => {
  const ctx = fake(richClassroomsRoute);
  const result = valid("classroom.available", await classroomAvailable(ctx, {
    term: TERM, filters: richSelection,
  }));
  const [first, second, third, fourth] = result.items;
  assert.deepEqual(first.roomType, { code: "demo-media", label: "合成多媒体教室" });
  assert.equal(first.teachingCapacity, 120);
  assert.equal(first.examCapacity, 60);
  assert.equal(first.capacity, undefined, "do not silently redefine the old capacity field");
  assert.equal(second.examCapacity, undefined);
  assert.equal(third.roomType, undefined);
  assert.equal(third.teachingCapacity, undefined);
  assert.equal(fourth.teachingCapacity, 0);
  assert.equal(fourth.examCapacity, 0);
  assert.equal(first.intervals[0].reason, "上课占用 / 教室借用");
  assert.equal(first.intervals[1].reason, "考试占用 / 调课占用 / 教室屏蔽");
  assert.deepEqual(result.appliedFilters, richSelection);
  assert.equal(result.coverage.complete, true);
  assert.match(result.coverage.description, /测试楼/);
  assert.equal(ctx.calls.filter((call) => call.url.pathname.endsWith("/rqzhzcjc.do")).length, 1);
  assert.equal(ctx.calls.filter((call) => call.url.pathname.endsWith("/cxkxjsxq.do")).length, 0);
});

test("numeric and type filters run on complete classroom pages and exclude unknown capacity", async () => {
  const query = (filters) => classroomAvailable(fake(richClassroomsRoute), { term: TERM, filters: { ...richSelection, ...filters } });
  assert.deepEqual((await query({ minimumTeachingSeats: 100 })).items.map((item) => item.roomId), ["room-1"]);
  assert.deepEqual((await query({ minimumExamSeats: 0 })).items.map((item) => item.roomId), ["room-1", "room-4"]);
  assert.deepEqual((await query({ roomTypes: ["demo-lab"] })).items.map((item) => item.roomId), ["room-2"]);
  assert.equal((await query({ roomTypes: [] })).items.length, 4, "empty selection retains unknown types");
  assert.deepEqual((await query({ minimumTeachingSeats: 80, onlyAvailable: true })).items.map((item) => item.roomId), ["room-2"]);
  const matching = await query({ room: "  测试教室2  " });
  assert.deepEqual(matching.items.map((item) => item.roomId), ["room-2"]);
  assert.equal(matching.appliedFilters.room, "测试教室2");
});

test("new timeRange retains section-window meaning and does not fill unknown breaks", async () => {
  const result = await classroomAvailable(fake(richClassroomsRoute), {
    term: TERM, filters: { ...richSelection, timeRange: { start: "08:30", end: "10:05" }, onlyAvailable: true },
  });
  assert.equal(result.sectionStart, 1);
  assert.equal(result.sectionEnd, 2);
  assert.equal(result.timeZone, "Asia/Shanghai");
  assert.equal(result.items.length, 3);
  assert.ok(result.items.every((item) => Date.parse(item.intervals[0].endAt) < Date.parse(item.intervals[1].startAt)));
});

test("new query filters reject unknown fields and malformed values before credentials or requests", async () => {
  for (const filters of [
    null, [], { role: "postgraduate" }, { configure: true }, { minimumTeachingSeats: "80" },
    { minimumExamSeats: -1 }, { minimumExamSeats: 1.5 }, { minimumExamSeats: Infinity },
    { onlyAvailable: "true" }, { roomTypes: ["x", "x"] }, { roomTypes: [1] },
    { date: "2025-02-30" }, { date: "2025-2-3" }, { room: "x\n" },
    { timeRange: { start: "23:00", end: "01:00" } },
    { timeRange: { start: "08:00", end: "09:00", code: "run" } },
  ]) {
    const ctx = { credentials: { get: () => assert.fail("invalid filters must not access credentials") } };
    await assert.rejects(classroomAvailable(ctx, { filters }), /input_invalid_request/);
  }
  await assert.rejects(gradesList({}, { filters: { term: "2025-2027-1" } }), /input_invalid_request/);
  await assert.rejects(gradesList({}, { filters: { room: "101" } }), /input_invalid_request/);
});

test("school text limits count Unicode characters consistently with the declared form", async () => {
  const form = await createQueryControls("undergraduate")(
    { now: () => Date.parse("2025-09-16T00:00:00Z") },
    { target: "classroom.available" },
  );
  const limit = form.controls.find((field) => field.id === "room").maxLength;
  assert.equal(limit, 512);
  const room = "😀".repeat(limit);
  assert.equal(validateQueryFilters("classroom.available", { room }).room, room);
  assert.throws(
    () => validateQueryFilters("classroom.available", { room: `${room}😀` }),
    /input_invalid_request/,
  );
});

test("new filters reject campus and final queries still validate the live building", async () => {
  const ctx = fake(richClassroomsRoute);
  await assert.rejects(classroomAvailable(ctx, {
    term: TERM, filters: { ...richSelection, campus: "N" },
  }), /input_invalid_request/);
  assert.equal(ctx.calls.length, 0, "obsolete conditions rejected before I/O");
  await assert.rejects(classroomAvailable(ctx, {
    term: TERM, filters: { ...richSelection, building: "not-in-live-directory" },
  }), /classroom_campus_building_conflict/);
  assert.ok(!ctx.calls.some((call) => call.url.pathname.endsWith("/cxjsqk.do")));
  const good = fake(richClassroomsRoute);
  await classroomAvailable(good, { term: TERM, filters: richSelection });
  const request = good.calls.find((call) => call.url.pathname.endsWith("/cxjsqk.do"));
  assert.ok(!request.form.querySetting.includes("XXXQDM"), "modern requests must not apply a hidden campus");
});

const deferredSelection = { date: "2025-09-16", building: "A" };

test("classroom base form and ordinary dependency refresh use the reviewed directory without I/O", async () => {
  const ctx = {
    now: () => Date.parse("2025-09-16T00:00:00Z"),
    credentials: { get: () => assert.fail("base form must not read credentials") },
    fetch: () => assert.fail("base form must not send school requests"),
  };
  const query = createQueryControls("undergraduate");
  const initial = valid("query.controls", await query(ctx, { target: "classroom.available" }));
  const building = initial.controls.find((control) => control.id === "building");
  assert.equal(building.options.length, 36);
  assert.ok(building.options.some((item) => item.value === "A"));
  assert.match(building.description, /2026-11-01.*包内目录/);
  assert.equal(building.initialValue, undefined, "the user chooses a building");
  const types = initial.controls.find((control) => control.id === "roomTypes");
  assert.equal(types.disabled, true);
  assert.equal(types.deferred, true);
  assert.equal(types.initialValue, undefined);
  const selected = valid("query.controls", await query(ctx, {
    target: "classroom.available", current: { ...deferredSelection, roomTypes: ["demo-media"] }, changed: "building",
  }));
  const pendingTypes = selected.controls.find((control) => control.id === "roomTypes");
  assert.equal(pendingTypes.deferred, true);
  assert.equal(pendingTypes.disabled, undefined);
  assert.deepEqual(pendingTypes.options, []);
  assert.equal(pendingTypes.initialValue, undefined, "pending choices are drafts, never unverified option defaults");
});

test("only an explicit deferred load discovers classroom types for its date and building", async () => {
  for (const [role, building] of [["undergraduate", "A"], ["undergraduate", "L"], ["postgraduate", "A"]]) {
    const ctx = fake(richClassroomsRoute);
    const selected = valid("query.controls", await createQueryControls(role)(ctx, {
      target: "classroom.available", current: { ...deferredSelection, building }, load: ["roomTypes"],
    }));
    const types = selected.controls.find((control) => control.id === "roomTypes");
    assert.deepEqual(types.options, [{ value: "demo-media", label: "合成多媒体教室" }, { value: "demo-lab", label: "合成实验室" }]);
    assert.deepEqual(types.dependsOn, ["date", "building"]);
    assert.equal(types.deferred, undefined);
    assert.equal(types.disabled, undefined);
    assert.equal(ctx.calls.filter((call) => call.url.pathname.endsWith("/cxjsqk.do")).length, 1);
    assert.equal(ctx.calls.filter((call) => call.url.pathname.endsWith("/cxkxjsxq.do")).length, 0);
    assert.equal(ctx.calls.filter((call) => call.url.pathname.endsWith("/jxlcx.do")).length, 0,
      "optional types do not re-fetch the directory; final business query still verifies it");
  }
});

test("north and south options are available together and obsolete campus is rejected", async () => {
  const ctx = { now: () => Date.parse("2025-09-16T00:00:00Z") };
  const query = createQueryControls("undergraduate");
  const result = await query(ctx, { target: "classroom.available", current: { ...deferredSelection, building: "L" } });
  const building = result.controls.find((control) => control.id === "building");
  assert.equal(building.options.length, 36);
  assert.equal(building.initialValue, "L");
  assert.equal(building.dependsOn, undefined);
  assert.ok(building.options.some((option) => option.label.startsWith("南校区")));
  assert.ok(building.options.some((option) => option.label.startsWith("北校区")));
  await assert.rejects(query(ctx, {
    target: "classroom.available", current: { campus: "N" },
  }), /input_invalid_request/);
});

test("deferred errors cannot prevent the offline form from being built", async () => {
  const query = createQueryControls("undergraduate");
  const ctx = { now: () => Date.parse("2025-09-16T00:00:00Z"), credentials: { get: async () => null } };
  const offline = await query(ctx, { target: "classroom.available", current: deferredSelection });
  assert.equal(offline.controls.find((control) => control.id === "roomTypes").deferred, true);
  await assert.rejects(query(ctx, {
    target: "classroom.available", current: deferredSelection, load: ["roomTypes"],
  }), /xidian_login_required_ehall/);
  const failed = fake(() => { throw new Error("synthetic_network_failure"); });
  await query(failed, { target: "classroom.available", current: deferredSelection });
  assert.equal(failed.calls.length, 0);
  await assert.rejects(query(failed, {
    target: "classroom.available", current: deferredSelection, load: ["roomTypes"],
  }), /synthetic_network_failure/);
});

test("deferred loader rejects unknown targets, loads and extra draft values before I/O", async () => {
  const query = createQueryControls("undergraduate");
  for (const params of [
    { target: "grades.list", load: ["roomTypes"] },
    { target: "classroom.available", load: [] },
    { target: "classroom.available", load: ["roomTypes", "roomTypes"] },
    { target: "classroom.available", load: ["building"] },
    { target: "classroom.available", load: ["roomTypes"], current: { ...deferredSelection, campus: "S" } },
    { target: "classroom.available", load: ["roomTypes"], current: { date: deferredSelection.date } },
    { target: "classroom.available", load: ["roomTypes"], current: { ...deferredSelection, building: "unknown" } },
    { target: "classroom.available", changed: "configure" },
  ]) {
    await assert.rejects(query({ now: () => 0, credentials: { get: () => assert.fail("invalid load must not access credentials") } }, params), /input_invalid_request/);
  }
});

test("default school date never silently applies a time window", async () => {
  const query = createQueryControls("undergraduate");
  for (const now of ["2026-11-03T16:05:45Z", "2026-11-04T06:35:00Z", "2026-11-04T15:59:00Z"]) {
    const result = valid("query.controls", await query({ now: () => Date.parse(now) }, { target: "classroom.available" }));
    const time = result.controls.find((control) => control.id === "timeRange");
    assert.equal(time.initialValue, undefined);
    assert.equal(time.timeZone, "Asia/Shanghai");
    assert.equal(result.controls.find((control) => control.id === "date").initialValue, "2026-11-04");
    assert.ok(result.controls.filter((control) => !control.required).every((control) => control.initialValue === undefined));
  }
  const chosen = { start: "08:30", end: "10:00" };
  const result = await query({ now: () => 0 }, {
    target: "classroom.available", current: { timeRange: chosen }, changed: "timeRange",
  });
  assert.deepEqual(result.controls.find((control) => control.id === "timeRange").initialValue, chosen);
});

test("new time filters outside known periods are unknown while legacy input still rejects", async () => {
  const timeRange = { start: "22:00", end: "23:00" };
  const query = (onlyAvailable) => classroomAvailable(fake(richClassroomsRoute), {
    term: TERM, filters: { ...richSelection, timeRange, onlyAvailable },
  });
  const result = valid("classroom.available", await query(false));
  assert.equal(result.sectionStart, undefined);
  assert.equal(result.sectionEnd, undefined);
  assert.equal(result.start, timeRange.start);
  assert.equal(result.end, timeRange.end);
  assert.ok(result.items.length > 0);
  assert.ok(result.items.every((item) => item.status === "unknown" && item.occupied === undefined));
  assert.match(result.coverage.description, /超出已知课程节次/);
  assert.deepEqual((await query(true)).items, []);
  await assert.rejects(classroomAvailable(fake(richClassroomsRoute), {
    term: TERM, date: deferredSelection.date, buildingId: "demo-building", start: "22:00", end: "23:00",
  }), /classroom_time_window_no_sections/);
});

test("classroom filtering rejects incomplete pagination instead of claiming complete coverage", async () => {
  const ctx = fake((call) => call.url.pathname.endsWith("/cxjsqk.do")
    ? payload("cxjsqk", Number(call.form.pageNumber) === 1 ? [room(1, { SKZWS: 120 })] : [], 2)
    : richClassroomsRoute(call));
  await assert.rejects(classroomAvailable(ctx, { term: TERM, filters: { ...richSelection, minimumTeachingSeats: 80 } }), /academic_pagination_incomplete/);
});


test("an in-flight optional type load does not delay a new offline form", { timeout: 3000 }, async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let notifyEntered;
  const entered = new Promise((resolve) => { notifyEntered = resolve; });
  const ctx = fake(async (call) => {
    if (call.url.pathname.endsWith("/cxjsqk.do")) {
      notifyEntered();
      await gate;
    }
    return richClassroomsRoute(call);
  });
  const query = createQueryControls("undergraduate");
  let settled = false;
  const pending = query(ctx, {
    target: "classroom.available", current: deferredSelection, load: ["roomTypes"],
  }).then((result) => { settled = true; return result; });
  await entered;
  try {
    const current = await query(ctx, {
      target: "classroom.available", current: { ...deferredSelection }, changed: "building",
    });
    assert.equal(current.controls.find((control) => control.id === "roomTypes").deferred, true);
    assert.equal(settled, false);
  } finally {
    release();
  }
  const result = await pending;
  assert.equal(result.controls.find((control) => control.id === "roomTypes").deferred, undefined);
});

test("school date is read once across midnight without adding a time default", async () => {
  let reads = 0;
  const instants = [Date.parse("2026-11-04T15:59:59.999Z"), Date.parse("2026-11-04T16:00:00.000Z")];
  const result = valid("query.controls", await createQueryControls("undergraduate")({
    now: () => instants[Math.min(reads++, 1)],
  }, { target: "classroom.available" }));
  assert.equal(result.controls.find((control) => control.id === "date").initialValue, "2026-11-04");
  assert.equal(result.controls.find((control) => control.id === "timeRange").initialValue, undefined,
    "23:59 has no valid same-day end; do not pair the old date with tomorrow's 00:00");
  assert.equal(reads, 1);
});
