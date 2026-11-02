/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { decode, one, str } from "./protobuf.js";

const bounded = (value, limit) => (typeof value === "string" ? value.slice(0, limit) : "");
function extensions(body) {
  const result = new Map();
  for (const raw of body.get(5) ?? []) {
    const kv = decode(raw);
    result.set(str(kv, 1), str(kv, 6));
  }
  return result;
}
export function messageContent(body) {
  const content = (body.get(4) ?? []).map(decode);
  // A command is identified, never executed or exposed as an opaque action.
  if (content.some((c) => one(c, 1, 0n) === 6n)) return { kind: "command", text: "[指令消息]" };
  const kinds = ["text", "image", "video", "location", "voice", "file"];
  let kind = kinds[Number(one(content[0] ?? new Map(), 1, 0n))] || "unknown";
  const chunks = content.map((c) => str(c, 2) || str(c, 23) || str(c, 6)).filter(Boolean);
  const ext = extensions(body);
  try {
    const attachment = JSON.parse(ext.get("attachment") || "null");
    if (attachment && typeof attachment === "object") {
      for (const [key, category] of [
        ["att_chat_course", "activity"],
        ["att_course", "course"],
        ["att_homework", "homework"],
        ["att_task", "task"],
        ["att_cloudDisk", "file"],
      ]) {
        const value = attachment[key];
        if (!value || typeof value !== "object") continue;
        kind = category;
        const title = bounded(value.title || value.name || value.courseName, 1000);
        if (title && !chunks.includes(title)) chunks.push(title);
      }
    }
  } catch {
    /* No raw attachment JSON/URLs/keys in output. */
  }
  const fallback = {
    text: "[非文本消息]",
    image: "[图片]",
    video: "[视频]",
    voice: "[语音]",
    location: "[位置]",
    file: "[文件]",
    activity: "[活动]",
    course: "[课程]",
    homework: "[作业]",
    task: "[任务]",
    unknown: "[非文本消息]",
  };
  return { text: chunks.join("\n").slice(0, 8000) || fallback[kind], kind };
}
