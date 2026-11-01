/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { messagesSession } from "./account.js";
import { attendanceCheckin } from "./checkin.js";
import { messagesList } from "./messages.js";
export const capabilities = {
  "messages.session": messagesSession,
  "messages.list": messagesList,
  "attendance.checkin": attendanceCheckin,
};
