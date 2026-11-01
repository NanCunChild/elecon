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
  assert.deepEqual(
    week3.days[4].slots.map((s) => [s.start, s.end, s.room, s.changeType]),
    [["7", "8", "合成教室三", "rescheduled"]],
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
  const ctx = fake(() =>
    payload("xscjcx", [
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
    ]),
  );
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

const buildingRows = [{ JXLDM: "demo-building", JXLJC: "测试楼", XXXQMC: "南校区" }];
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
    return payload("cxjsqk", [room(1, { JC2: "1_course" }), room(2), room(3, { JC1: null })]);
  }
}

test("classroom building/campus and date conversion with correct XQ filter", async () => {
  const ctx = fake(classroomsRoute);
  const list = valid("classroom.buildings", await classroomBuildings(ctx, { campus: "南校区" }));
  assert.equal(list.items[0].buildingId, "demo-building");
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
      building: "测试楼",
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
    classroomAvailable(ambiguous, { term: TERM, date: "2025-09-16", building: "测试楼" }),
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
  const ugCal = valid("calendar.academic", await calendarAcademic(ug, { term: TERM }));
  assert.deepEqual(ugCal, { term: TERM, startDate: "2025-09-01", currentWeek: 3 });
  const pg = fake((call) =>
    call.url.pathname.endsWith("/getUserInfo.do")
      ? { code: "0", data: { xnxqdm: TERM } }
      : { msg: { QSRQ: "2025-09-01 00:00:00" } },
  );
  assert.equal(valid("term.list", await termList(pg, { role: "postgraduate" })).currentTerm, TERM);
  assert.deepEqual(valid("calendar.academic", await calendarAcademic(pg, { role: "postgraduate" })), ugCal);
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
  await classroomAvailable(ctx, { term: TERM, date: "2025-09-16", buildingId: "demo-building", building: "测试楼" });
  assert.equal(ctx.calls.some((call) => call.url.pathname.endsWith("/jxlcx.do")), false);
});
