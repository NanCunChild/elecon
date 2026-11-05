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
import { createAccountSession } from "./accounts.js";
import { cardBalance, cardQr, cardTransactions, libraryLoans, librarySearch } from "./campus.js";
import { facultySearch } from "./faculty.js";
import { createLogin, recoverAcademicSession } from "./login.js";
import { noticeDetail, noticeList } from "./notices.js";
import { phoneDirectory } from "./phone_directory.js";
import { createProfile } from "./profile.js";
import { createQueryControls } from "./query_controls.js";
import { forumSession } from "./ruisi.js";

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
        if (["ehall", "yjspt"].includes(system)) await recoverAcademicSession(ctx, role, system);
        else await createLogin(role)(ctx, { ...params, system });
      }
    }
  };
}

// SDK19: only a storage key and an exported handler name survive this call.
// The role argument is reconstructed from the approved entry module each run.
async function scheduledCardQr(ctx, params, role) {
  const execution = ctx.execution;
  if (execution?.stateKey != null) {
    const state = await execution.state.get(execution.stateKey);
    if (!state || state.role !== role) throw new Error("xidian_school_role_mismatch");
    params = {};
  }
  const data = await authenticated(cardQr, role)(ctx, params);
  if (execution) {
    if (execution.stateKey == null) {
      await execution.state.set("cardQr", { role });
      await execution.register({ id: "cardQr", handler: "renewCardQr", stateKey: "cardQr" });
    }
    const now = ctx.now();
    const remaining = Math.min(Date.parse(data.expiresAt) - now, 60000);
    if (remaining > 2000) await execution.schedule("cardQr", now + Math.floor(remaining * 0.8));
  }
  return data;
}

export function createHandlers(role) {
  return { renewCardQr: async (ctx) => scheduledCardQr(ctx, {}, role) };
}

export function createCapabilities(role) {
  if (role !== "undergraduate" && role !== "postgraduate") throw new Error("academic_role_invalid");
  return {
    "account.session": createAccountSession(role),
    "profile.me": createProfile(role),
    "library.search": librarySearch,
    "query.controls": createQueryControls(role),
    "forum.session": forumSession,
    "faculty.search": facultySearch,
    "directory.phones": phoneDirectory,
    "notice.list": noticeList,
    "notice.detail": noticeDetail,
    "generic.section": createLogin(role),
    "schedule.week": authenticated(scheduleWeek, role),
    "grades.list": authenticated(gradesList, role),
    "exam.list": authenticated(examList, role),
    "classroom.buildings": authenticated(classroomBuildings, role),
    "classroom.available": authenticated(classroomAvailable, role),
    "card.qr": (ctx, params = {}) => scheduledCardQr(ctx, params, role),
    "card.balance": authenticated(cardBalance, role),
    "card.transactions": authenticated(cardTransactions, role),
    "library.loans": authenticated(libraryLoans, role),
    "term.list": authenticated(termList, role),
    "calendar.academic": authenticated(calendarAcademic, role),
  };
}

export const capabilities = createCapabilities("undergraduate");
