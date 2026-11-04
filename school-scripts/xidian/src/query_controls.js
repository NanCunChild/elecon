/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-071: describes existing read-only parameters; never invokes login.
import { termList } from "./academic.js";
import { serviceError } from "./service_session.js";

const label = (ctx, key, fallback) => ctx.i18n?.t(key) ?? fallback;
export function createQueryControls(role) {
  return async (ctx, params = {}) => {
    if (
      !params ||
      typeof params !== "object" ||
      Array.isArray(params) ||
      Object.keys(params).some((key) => key !== "target") ||
      !["grades.list", "classroom.available"].includes(params.target)
    ) {
      throw serviceError("input_invalid_request");
    }
    const target = params.target;
    const output = {
      target,
      title: label(ctx, "query.title", "筛选条件"),
      submitLabel: label(ctx, "query.submit", "查询"),
      controls: [],
    };
    if (target === "grades.list") {
      const terms = await termList(ctx, { role, includePast: true });
      if (!terms.items.length || terms.items.length > 200) throw serviceError("source_response_invalid");
      output.controls.push({
        id: "academic-term",
        kind: "select",
        parameter: "term",
        label: label(ctx, "query.term", "学期"),
        initialValue: terms.currentTerm,
        options: terms.items.map((term) => ({ value: term.id, label: term.name })),
      });
    } else {
      const date = new Date(ctx.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
      output.controls.push(
        {
          id: "query-date",
          kind: "date",
          parameter: "date",
          label: label(ctx, "query.date", "日期"),
          initialValue: date,
        },
        { id: "room-name", kind: "text", parameter: "room", label: label(ctx, "query.room", "教室名称") },
        {
          id: "school-time",
          kind: "timeRange",
          parameter: "start",
          label: label(ctx, "query.timeRange", "学校当地时间段"),
        },
      );
    }
    return output;
  };
}
