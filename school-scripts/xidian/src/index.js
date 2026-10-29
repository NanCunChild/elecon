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
import { noticeList } from "./notices.js";
import { readSession } from "./session.js";

// Remember an explicitly chosen UG/PG identity, without guessing from an id.
function academic(handler) {
  return async (ctx, params = {}) => {
    const ids = await readSession(ctx, "ids");
    return handler(ctx, {
      ...params,
      role: params.role ?? ids?.data?.role ?? "undergraduate",
    });
  };
}

export const capabilities = {
  "notice.list": noticeList,
  "schedule.week": academic(scheduleWeek),
  "grades.list": academic(gradesList),
  "exam.list": academic(examList),
  "classroom.buildings": academic(classroomBuildings),
  "classroom.available": academic(classroomAvailable),
  "card.balance": cardBalance,
  "card.transactions": cardTransactions,
  "library.loans": libraryLoans,
  "term.list": academic(termList),
  "calendar.academic": academic(calendarAcademic),
};
