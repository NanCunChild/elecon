import assert from "node:assert/strict";
import test from "node:test";
import { chaoxingWeek, compareSchedule, syntheticContext } from "../research/schedule-compare.mjs";

test("schedule comparison executes current module and keeps term/cache coverage distinct", async () => {
  const report = await compareSchedule(syntheticContext(), { samples: 1 });
  assert.equal(report.current.rows[0].requests, 4);
  assert.equal(report.candidate.rows[0].requests, 1);
  assert.equal(report.sameTermStart, true);
  assert.equal(report.current.completeTerm, true);
  assert.equal(report.candidate.completeTerm, false);
  assert.equal(report.cachedWeekSwitch.currentNetworkRequests, 0);
  assert.equal(report.equivalence.startsWith("unverified"), true);
});

test("candidate must return successful JSON for the requested year/semester", async () => {
  const ctx = syntheticContext();
  await assert.rejects(
    chaoxingWeek(ctx, { year: "2025", semester: "1", week: 1 }),
    /candidate_response_invalid/,
  );
  await assert.rejects(
    chaoxingWeek(
      { ...ctx, fetch: async () => new Response("<html>login</html>") },
      { year: "2026", semester: "1", week: 1 },
    ),
  );
  await assert.rejects(compareSchedule(ctx, { samples: 6 }), /probe_input_invalid/);
});
