/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

import { remoteId, requireParams, serviceError } from "../../xidian/src/service_session.js";
import { encodeForm, parseUrl } from "../../xidian/src/session.js";
import { chaoxingClient, MOBILE } from "./account.js";
import { clientIdentity } from "./client_identity.js";

export function parseCheckinQr(text) {
  if (typeof text !== "string" || text.length > 4096) throw serviceError("input_invalid_request");
  let url;
  try {
    url = parseUrl(text);
  } catch {
    throw serviceError("input_invalid_request");
  }
  if (
    !["https://mobilelearn.chaoxing.com", "http://mobilelearn.chaoxing.com"].includes(url.origin) ||
    url.path !== "/widget/sign/e" ||
    url.hash
  )
    throw serviceError("input_invalid_request");
  const values = {};
  try {
    for (const pair of url.query.slice(1).split("&")) {
      const index = pair.indexOf("=");
      if (index < 0) throw new Error();
      const key = decodeURIComponent(pair.slice(0, index));
      const value = decodeURIComponent(pair.slice(index + 1));
      if (!["id", "enc", "c", "qrCode", "DB_STRATEGY"].includes(key) || Object.keys(values).includes(key))
        throw new Error();
      values[key] = value;
    }
  } catch {
    throw serviceError("input_invalid_request");
  }
  if (!/^[1-9][0-9]{0,39}$/.test(values.id ?? "") || !/^[0-9a-fA-F]{32}$/.test(values.enc ?? ""))
    throw serviceError("input_invalid_request");
  return { id: values.id, enc: values.enc };
}
function unchallenged(content) {
  if (!content || typeof content !== "object" || Array.isArray(content)) return false;
  // Explicit negative flags only; an unrecognized/partial response must not
  // silently downgrade a location, face, photo or validation requirement.
  return (
    ["ifopenAddress", "openCheckFaceFlag", "ifNeedVcode"].every(
      (k) => content[k] === 0 || content[k] === "0",
    ) &&
    !["ifphoto", "photo", "ifNeedPhoto", "isPhoto"].some(
      (k) => content[k] != null && ![0, "0", false].includes(content[k]),
    )
  );
}
const urlFor = (path, params) => `${MOBILE}${path}?${encodeForm(params)}`;
async function attended(client, id) {
  const v = await client.json(urlFor("/v2/apis/sign/getAttendInfo", { activeId: id }));
  if (!v?.data || ![0, 1, "0", "1"].includes(v.data.status)) throw serviceError();
  return String(v.data.status) === "1";
}
export async function attendanceCheckin(ctx, params = {}) {
  requireParams(params);
  // Authentication is explicit in the messages page; no surprise account
  // switching or login retry after scanning a short-lived ticket.
  const { client, account } = await chaoxingClient(ctx);
  if (!ctx.ui?.scanQRCode) throw serviceError("input_unavailable");
  const scan = await ctx.ui.scanQRCode();
  if (!scan) return { status: "cancelled" };
  const activity = parseCheckinQr(scan.text);
  const result = (status) => ({ status, activityId: activity.id });
  const scanTime = ctx.now();
  if (await attended(client, activity.id)) return result("already");
  const info = (await client.json(urlFor("/v2/apis/active/getPPTActiveInfo", { activeId: activity.id })))
    ?.data;
  if (!info || ![0, 1, "0", "1"].includes(info.status) || ![0, 1, "0", "1"].includes(info.isdelete))
    throw serviceError();
  if (String(info.status) !== "1" || String(info.isdelete) !== "0") return result("ended");
  let content;
  try {
    content = typeof info.content === "string" ? JSON.parse(info.content) : info.content;
  } catch {
    throw serviceError();
  }
  if (Number(info.otherId) !== 2 || !unchallenged(content)) return result("unsupported");
  const classId = remoteId(info.clazzid);
  const detail = (await client.json(urlFor("/v2/apis/class/getClassDetail", { classId, courseId: "" })))
    ?.data;
  const courseId = remoteId(detail?.courseid);
  const analysis = await client.text(
    urlFor("/pptSign/analysis", { vs: 1, DB_STRATEGY: "RANDOM", aid: activity.id }),
  );
  const code = /\b([0-9a-f]{32})\b/i.exec(analysis)?.[1];
  if (
    !code ||
    (await client.text(urlFor("/pptSign/analysis2", { code, DB_STRATEGY: "RANDOM" }))).trim() !== "success"
  )
    throw serviceError();
  const preSign = urlFor("/newsign/preSign", {
    general: 1,
    sys: 1,
    ls: 1,
    appType: 15,
    ut: "s",
    classId,
    courseId,
    uid: account.id,
    tid: account.tid,
    activePrimaryId: activity.id,
  });
  await client.text(preSign);
  if (await attended(client, activity.id)) return result("already");
  const latest = await client.json(urlFor("/ppt/renwuAPI/getActive", { aid: activity.id }));
  if (remoteId(latest.classId) !== classId || Number(latest.courseId) !== 2 || !unchallenged(latest.content))
    return result("unsupported");
  if (ctx.now() - scanTime > 30000) return result("rejected");
  // From this point a failed transport can have delivered a side effect. Never
  // repeat this POST, including CAPTCHA, redirects, cancellation or timeouts.
  let response = "";
  try {
    response = (
      await client.post(`${MOBILE}/pptSign/stuSignajax`, {
        name: account.label,
        uid: account.id,
        fid: account.fid,
        appType: 15,
        ifCFP: 0,
        currentFaceId: "",
        clientip: "",
        latitude: "-1",
        longitude: "-1",
        address: "",
        ifTiJiao: 0,
        vpProbability: "",
        vpStrategy: "",
        activeId: activity.id,
        enc: activity.enc,
        deviceCode: clientIdentity(account.id).deviceCode,
      })
    ).trim();
  } catch {
    /* Only the independent read below may resolve delivery uncertainty. */
  }
  try {
    if (await attended(client, activity.id)) return result("confirmed");
  } catch {
    return result("unknown");
  }
  if (/validate|验证码|人脸|定位/.test(response)) return result("unsupported");
  if (["签到已结束", "活动已结束", "签到失败"].includes(response)) return result("rejected");
  return result("unknown");
}
