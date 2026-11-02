/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { accountSession, messagesSession } from "./account.js";
import { messagesConversations, messagesHistory, messagesSend } from "./chat.js";
import { attendanceCheckin } from "./checkin.js";
import { messagesList } from "./messages.js";
import { noticeList } from "./notices.js";
export const capabilities = {
  "notice.list": noticeList,
  "account.session": accountSession,
  "messages.session": messagesSession,
  "messages.list": messagesList,
  "messages.conversations": messagesConversations,
  "messages.history": messagesHistory,
  "messages.send": messagesSend,
  "attendance.checkin": attendanceCheckin,
};
