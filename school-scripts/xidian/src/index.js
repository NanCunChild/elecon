/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

import {
  calendarAcademic,
  classroomAvailable,
  classroomBuildings,
  examList,
  gradesList,
  scheduleWeek,
  termList,
} from "./academic.js";
import { cardBalance, cardTransactions, libraryLoans } from "./campus.js";
import { createLogin } from "./login.js";
import { noticeList } from "./notices.js";

// ADR-034 §3 / ADR-035 §2: the installed school owns the academic route.
// A saved role or invocation parameter must never switch school identities.
function authenticated(handler, role) {
  return async (ctx, params = {}) => {
    if (params.role != null && params.role !== role) throw new Error("xidian_school_role_mismatch");
    const loggedIn = new Set();
    for (;;) {
      try {
        return await handler(ctx, { ...params, role });
      } catch (error) {
        const system = /^xidian_login_required_(ehall|yjspt|card|library)$/.exec(error?.message ?? "")?.[1];
        // Retry read-only business work once per required system. Cancellation,
        // invalid inputs and unexpected school responses must remain failures.
        if (!system || loggedIn.has(system)) throw error;
        loggedIn.add(system);
        await createLogin(role)(ctx, { ...params, system });
      }
    }
  };
}

export function createCapabilities(role) {
  if (role !== "undergraduate" && role !== "postgraduate") throw new Error("academic_role_invalid");
  return {
    "notice.list": noticeList,
    "generic.section": createLogin(role),
    "schedule.week": authenticated(scheduleWeek, role),
    "grades.list": authenticated(gradesList, role),
    "exam.list": authenticated(examList, role),
    "classroom.buildings": authenticated(classroomBuildings, role),
    "classroom.available": authenticated(classroomAvailable, role),
    "card.balance": authenticated(cardBalance, role),
    "card.transactions": authenticated(cardTransactions, role),
    "library.loans": authenticated(libraryLoans, role),
    "term.list": authenticated(termList, role),
    "calendar.academic": authenticated(calendarAcademic, role),
  };
}

export const capabilities = createCapabilities("undergraduate");
