/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-083: immediate offline controls, with optional deferred discovery.
import { classroomAvailable, termList } from "./academic.js";
import { classroomDirectory } from "./classroom_directory.js";
import { classroomFilterIds, validateQueryFilters } from "./query_filters.js";
import { serviceError } from "./service_session.js";

const label = (ctx, key, fallback) => ctx.i18n?.t(key) ?? fallback;

function defaultSchoolTimeRange(now) {
  const schoolNow = new Date(now + 8 * 3600 * 1000);
  const minute = schoolNow.getUTCHours() * 60 + schoolNow.getUTCMinutes();
  // The same-day contract cannot express an end later than 23:59.
  if (minute === 1439) return undefined;
  const clock = (value) => `${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}`;
  return { start: clock(minute), end: clock(Math.min(minute + 60, 1439)) };
}
export function createQueryControls(role) {
  return async (ctx, params = {}) => {
    if (!params || typeof params !== "object" || Array.isArray(params) ||
        Object.keys(params).some((key) => !["target", "current", "changed", "load"].includes(key)) ||
        !["grades.list", "classroom.available"].includes(params.target))
      throw serviceError("input_invalid_request");
    const target = params.target;
    const current = validateQueryFilters(target, params.current);
    const loadTypes = params.load !== undefined;
    if (loadTypes && (target !== "classroom.available" || !Array.isArray(params.load) ||
        params.load.length !== 1 || params.load[0] !== "roomTypes" ||
        Object.keys(current).some((key) => !["date", "building", "roomTypes"].includes(key))))
      throw serviceError("input_invalid_request");
    const ids = target === "grades.list" ? ["term"] : classroomFilterIds;
    if (params.changed !== undefined && !ids.includes(params.changed))
      throw serviceError("input_invalid_request");
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
        id: "term", kind: "select", required: true,
        label: label(ctx, "query.term", "学期"),
        ...(current.term === undefined ? { initialValue: terms.currentTerm } :
          terms.items.some((term) => term.id === current.term) ? { initialValue: current.term } : {}),
        options: terms.items.map((term) => ({ value: term.id, label: term.name })),
      });
      return output;
    }

    // Public names/codes were reviewed on 2026-11-01. No credential or network
    // read belongs to the initial classroom form or its ordinary dependency refresh.
    // Date and time defaults must describe the same instant across midnight.
    const now = ctx.now();
    const directory = classroomDirectory();
    if (!directory.length || directory.length > 200) throw serviceError("source_response_invalid");
    const campuses = [...new Map(directory.filter((item) => item.campus).map((item) => [item.campus, {
      value: item.campus,
      label: item.campusLabel || (item.campus === "S" ? label(ctx, "query.campusSouth", "南校区") :
        item.campus === "N" ? label(ctx, "query.campusNorth", "北校区") : item.campus),
    }])).values()];
    const requestedBuilding = directory.find((item) => item.buildingId === current.building);
    const campus = current.campus === undefined ?
      requestedBuilding?.campus ?? campuses.find((item) => item.value === "S")?.value ?? campuses[0]?.value :
      campuses.some((item) => item.value === current.campus) ? current.campus : undefined;
    const buildings = directory.filter((item) => campus && item.campus === campus);
    const date = current.date ?? new Date(now + 8 * 3600 * 1000).toISOString().slice(0, 10);
    // Do not choose a replacement building after the user changes the campus.
    const building = buildings.find((item) => item.buildingId === current.building);
    const provenance = label(ctx, "query.savedDirectory", "选项来自2026-11-01核对的包内目录；查询时重新核对学校目录");
    const timeRange = current.timeRange ?? (params.changed === undefined ? defaultSchoolTimeRange(now) : undefined);
    let roomTypes = [];
    if (loadTypes) {
      if (!requestedBuilding || !current.date) throw serviceError("input_invalid_request");
      const rooms = await classroomAvailable(ctx, {
        role, date: current.date, buildingId: requestedBuilding.buildingId,
        building: requestedBuilding.building, campus: requestedBuilding.campus,
      });
      roomTypes = [...new Map(rooms.items.filter((item) => item.roomType?.code).map((item) => [item.roomType.code, {
        value: item.roomType.code, label: item.roomType.label,
      }])).values()];
      if (roomTypes.length > 200) throw serviceError("source_response_invalid");
    }
    output.controls.push(
      { id: "date", kind: "date", required: true, label: label(ctx, "query.date", "日期"), initialValue: date },
      { id: "campus", kind: "select", required: true, label: label(ctx, "query.campus", "校区"),
        options: campuses, ...(campus ? { initialValue: campus } : {}),
        ...(!campuses.length ? { disabled: true, disabledReason: label(ctx, "query.noCampuses", "学校未提供可选校区") } : {}) },
      { id: "building", kind: "select", required: true, label: label(ctx, "query.building", "教学楼"),
        description: provenance, dependsOn: ["campus"], options: buildings.map((item) => ({ value: item.buildingId, label: item.building })),
        ...(building ? { initialValue: building.buildingId } : {}),
        ...(!buildings.length ? { disabled: true, disabledReason: label(ctx, "query.noBuildings", "当前校区没有可选教学楼") } : {}) },
      { id: "room", kind: "text", label: label(ctx, "query.room", "教室名称"), maxLength: 512 },
      { id: "timeRange", kind: "timeRange", label: label(ctx, "query.timeRange", "学校当地时间段"), timeZone: "Asia/Shanghai",
        description: label(ctx, "query.sectionRange", "按与时间段相交的节次计算占用；不保证课间或实际开放"),
        ...(timeRange ? { initialValue: timeRange } : {}) },
      { id: "minimumTeachingSeats", kind: "number", label: label(ctx, "query.teachingSeats", "上课座位数至少"), integer: true, minimum: 0, maximum: 100000 },
      { id: "minimumExamSeats", kind: "number", label: label(ctx, "query.examSeats", "考试座位数至少"), integer: true, minimum: 0, maximum: 100000 },
      { id: "roomTypes", kind: "multiSelect", label: label(ctx, "query.roomTypes", "教室类型"),
        description: label(ctx, "query.typesCoverage", "选项来自当前日期与楼栋的完整查询；不选择时保留未知类型教室"),
        dependsOn: ["date", "building"], options: roomTypes,
        ...(!loadTypes ? { deferred: true } : {}),
        ...(!loadTypes && !building ? { disabled: true, disabledReason:
          label(ctx, "query.typesSelectBuilding", "先选择日期与教学楼") } : {}),
        ...(loadTypes && !roomTypes.length ? { disabled: true, disabledReason:
          label(ctx, "query.typesMissing", "当前结果未提供教室类型") } : {}) },
      { id: "onlyAvailable", kind: "boolean", label: label(ctx, "query.onlyAvailable", "仅保留查询节次全部空闲的教室"), initialValue: false },
    );
    return output;
  };
}
