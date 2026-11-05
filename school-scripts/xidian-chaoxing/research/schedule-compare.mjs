/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// Research only: not registered in a production manifest. Never prints records.
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";
import { scheduleWeek } from "../../xidian/src/academic.js";
import { serviceClient } from "../../xidian/src/service_session.js";

export async function chaoxingWeek(ctx, { year, semester, week }) {
  const client = await serviceClient(ctx, {
    id: "chaoxing",
    name: "Chaoxing",
    origins: ["https://kb.chaoxing.com"],
  });
  const url = `https://kb.chaoxing.com/curriculum/getMyLessons?role=4&schoolYear=${encodeURIComponent(year)}&semester=${encodeURIComponent(semester)}&week=${week}`;
  const value = await client.json(url);
  const data = value?.data;
  const curriculum = data?.curriculum;
  if (
    value?.result !== 1 ||
    !curriculum ||
    !Array.isArray(data.lessonArray) ||
    data.lessonArray.length > 2000 ||
    String(curriculum.schoolYear) !== String(year) ||
    String(curriculum.semester) !== String(semester) ||
    !Number.isSafeInteger(curriculum.firstWeekDate)
  )
    throw new Error("candidate_response_invalid");
  return data;
}

const payload = (name, rows) => ({
  code: "0",
  datas: { [name]: { rows, totalSize: rows.length, extParams: { code: 1 } } },
});
export function syntheticContext(latency = 0) {
  const records = new Map([
    [
      "ehall",
      JSON.stringify({ version: 1, service: "ehall", cookies: [], data: { studentId: "synthetic" } }),
    ],
  ]);
  return {
    now: () => Date.parse("2026-09-10T00:00:00Z"),
    credentials: {
      get: async (key) => (records.has(key) ? { value: records.get(key) } : null),
      set: async (key, value) => records.set(key, value),
    },
    async fetch(url, init = {}) {
      if (latency) await new Promise((resolve) => setTimeout(resolve, latency));
      const path = new URL(url).pathname;
      let body;
      if (path.endsWith("/getMyLessons"))
        body = {
          result: 1,
          data: {
            curriculum: {
              schoolYear: "2026",
              semester: 1,
              firstWeekDate: Date.parse("2026-09-07T00:00:00+08:00"),
              currentWeek: 1,
            },
            lessonArray: [
              {
                name: "Synthetic course",
                dayOfWeek: 1,
                beginNumber: 1,
                length: 2,
                weeks: "1",
                wholeDay: "2026-09-07",
              },
            ],
          },
        };
      else if ((init.method || "GET") === "GET") body = {};
      else if (path.endsWith("/cxjcs.do")) body = payload("cxjcs", [{ XQKSRQ: "2026-09-07" }]);
      else if (path.endsWith("/xskcb.do"))
        body = payload("xskcb", [
          {
            KCM: "Synthetic course",
            KCH: "course",
            KXH: "01",
            SKJS: "Teacher",
            JASMC: "Room",
            KSJC: "1",
            JSJC: "2",
            SKXQ: "1",
            SKZC: "1",
          },
        ]);
      else if (path.endsWith("/xsdkkc.do")) body = payload("xsdkkc", []);
      else throw new Error("synthetic_route_missing");
      const response = new Response(JSON.stringify(body), {
        headers: { "Content-Type": "application/json" },
      });
      Object.defineProperty(response, "url", { value: url });
      return response;
    },
  };
}

function liveContext() {
  // Supplied locally by the operator, never on the command line or in output.
  // Existing session records only; this probe never performs a password login.
  const records = new Map(Object.entries(JSON.parse(process.env.ELECON_BENCH_SESSIONS || "{}")));
  if (!records.has("xidian.auth:ehall") || !records.has("xidian.services:chaoxing"))
    throw new Error("existing_sessions_required");
  let requests = 0;
  return {
    now: Date.now,
    credentials: {
      get: async (key, options) => {
        const record = records.get(`${options.namespace}:${key}`);
        return record ? { value: JSON.stringify(record) } : null;
      },
      set: async (key, value, options) => records.set(`${options.namespace}:${key}`, JSON.parse(value)),
    },
    async fetch(url, init) {
      if (
        ++requests > 100 ||
        ![
          "https://ehall.xidian.edu.cn",
          "http://ehall.xidian.edu.cn",
          "https://ids.xidian.edu.cn",
          "https://kb.chaoxing.com",
        ].includes(new URL(url).origin)
      )
        throw new Error("probe_request_limit");
      return fetch(url, { ...init, redirect: "manual", signal: AbortSignal.timeout(10000) });
    },
  };
}

export async function compareSchedule(
  ctx,
  { samples = 3, term = "2026-2027-1", week = 1, year = "2026", semester = "1" } = {},
) {
  if (
    !Number.isInteger(samples) ||
    samples < 1 ||
    samples > 5 ||
    !Number.isInteger(week) ||
    week < 1 ||
    week > 60 ||
    !/^\d{4}-\d{4}-[1-3]$/.test(term) ||
    !/^\d{4}$/.test(year) ||
    !/^[1-3]$/.test(String(semester))
  )
    throw new Error("probe_input_invalid");
  const results = { current: [], candidate: [] };
  let current, candidate;
  for (let i = 0; i < samples; i++) {
    for (const kind of i % 2 ? ["candidate", "current"] : ["current", "candidate"]) {
      let requests = 0,
        bytes = 0;
      const measured = {
        ...ctx,
        fetch: async (...args) => {
          requests++;
          const response = await ctx.fetch(...args);
          const body = await response.arrayBuffer();
          bytes += body.byteLength;
          const buffered = new Response(body, { status: response.status, headers: response.headers });
          Object.defineProperty(buffered, "url", { value: response.url || args[0] });
          return buffered;
        },
      };
      const start = performance.now();
      if (kind === "current") current = await scheduleWeek(measured, { term, week });
      else candidate = await chaoxingWeek(measured, { year, semester, week });
      results[kind].push({ ms: +(performance.now() - start).toFixed(2), requests, bytes });
    }
  }
  const localDate = new Date(candidate.curriculum.firstWeekDate + 8 * 3600000).toISOString().slice(0, 10);
  const median = (rows) => [...rows].sort((a, b) => a.ms - b.ms)[Math.floor(rows.length / 2)].ms;
  return {
    samples,
    sessionMode: "existing-session; no host business cache; alternating order",
    current: {
      rows: results.current,
      medianMs: median(results.current),
      completeTerm: true,
      includesAcademicChanges: true,
    },
    candidate: {
      rows: results.candidate,
      medianMs: median(results.candidate),
      completeTerm: false,
      includesAcademicChanges: "unverified",
    },
    sameTermStart: current.termStartDate === localDate,
    courseCounts: {
      current: current.days.flatMap((day) => day.slots).length,
      candidate: candidate.lessonArray.length,
    },
    equivalence:
      "unverified: compare courses, dates, periods, cancellations and makeups before replacing the source",
    cachedWeekSwitch: { currentNetworkRequests: 0, candidateNetworkRequests: 1 },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = process.argv.slice(2);
    const live = args.includes("--live");
    const flag = (key, fallback) => (args.includes(key) ? args[args.indexOf(key) + 1] : fallback);
    if (live && !["--term", "--week", "--cx-year", "--cx-semester"].every((key) => args.includes(key)))
      throw new Error("explicit_term_and_week_required");
    const latency = Number(flag("--latency-ms", "50"));
    if (!Number.isFinite(latency) || latency < 0 || latency > 500) throw new Error("latency_invalid");
    const report = await compareSchedule(live ? liveContext() : syntheticContext(latency), {
      samples: Number(flag("--samples", "3")),
      term: flag("--term", "2026-2027-1"),
      week: Number(flag("--week", "1")),
      year: flag("--cx-year", "2026"),
      semester: flag("--cx-semester", "1"),
    });
    console.log(
      JSON.stringify(
        {
          evidence: live ? "live-school-requests" : "synthetic-network-model",
          ...(live ? {} : { perRequestDelayMs: latency }),
          ...report,
        },
        null,
        2,
      ),
    );
  } catch {
    console.error(
      "schedule_probe_failed: check local sessions, explicit term/week, response semantics and connectivity; no secrets logged",
    );
    process.exitCode = 1;
  }
}
