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
// Location comes only from the explicit foreground selection. The coordinate
// system is the service's native one, not inferred GPS or converted map data.
function selectedLocation(params) {
  requireParams(params, ["location"]);
  if (params.location === undefined) return undefined;
  const v = params.location;
  requireParams(v, ["latitude", "longitude", "address", "coordinateSystem"]);
  if (
    !Number.isFinite(v.latitude) ||
    Math.abs(v.latitude) > 90 ||
    !Number.isFinite(v.longitude) ||
    Math.abs(v.longitude) > 180 ||
    typeof v.address !== "string" ||
    !v.address.trim() ||
    v.address.length > 200 ||
    v.coordinateSystem !== "service"
  )
    throw serviceError("input_invalid_request");
  return { latitude: v.latitude, longitude: v.longitude, address: v.address.trim() };
}
function contentObject(value) {
  try {
    const parsed = typeof value === "string" ? JSON.parse(value) : value;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}
const flag = (value) => ([0, "0", false].includes(value) ? 0 : [1, "1", true].includes(value) ? 1 : null);
function requirement(content, location) {
  if (!content) return "requirements_unknown";
  if (flag(content.openCheckFaceFlag) === 1) return "face_required";
  if (flag(content.ifNeedVcode) === 1) return "verification_required";
  if (
    ["ifphoto", "photo", "ifNeedPhoto", "isPhoto"].some((k) => content[k] != null && flag(content[k]) !== 0)
  )
    return "photo_required";
  if (["ifopenAddress", "openCheckFaceFlag", "ifNeedVcode"].some((k) => flag(content[k]) === null))
    return "requirements_unknown";
  if (flag(content.ifopenAddress) === 1 && !location) return "location_required";
  return null;
}
const urlFor = (path, params) => `${MOBILE}${path}?${encodeForm(params)}`;
async function attended(client, id) {
  const v = await client.json(urlFor("/v2/apis/sign/getAttendInfo", { activeId: id }));
  if (!v?.data || ![0, 1, "0", "1"].includes(v.data.status)) throw serviceError();
  return String(v.data.status) === "1";
}
export async function attendanceCheckin(ctx, params = {}) {
  const location = selectedLocation(params);
  // Authentication is explicit in the messages page; no surprise account
  // switching or login retry after scanning a short-lived ticket.
  const { client, account } = await chaoxingClient(ctx);
  if (!ctx.ui?.scanQRCode) throw serviceError("input_unavailable");
  const scan = await ctx.ui.scanQRCode();
  if (!scan) return { status: "cancelled" };
  const activity = parseCheckinQr(scan.text);
  const result = (status, reason) => {
    try {
      ctx.log?.("info", `checkin_${status}${reason ? `_${reason}` : ""}`);
    } catch {
      // Diagnostics must never turn a verified/delivered submission into a
      // preflight failure when the log channel has reached its budget.
    }
    return { status, activityId: activity.id, ...(reason ? { reason } : {}) };
  };
  try {
    return await submitScanned(ctx, client, account, activity, location, result);
  } catch (error) {
    if (error.code === "authentication_required") throw error;
    return result("rejected", "request_failed");
  }
}
async function submitScanned(ctx, client, account, activity, location, result) {
  const scanTime = ctx.now();
  if (await attended(client, activity.id)) return result("already");
  const info = (await client.json(urlFor("/v2/apis/active/getPPTActiveInfo", { activeId: activity.id })))
    ?.data;
  if (!info || ![0, 1, "0", "1"].includes(info.status) || ![0, 1, "0", "1"].includes(info.isdelete))
    throw serviceError();
  if (String(info.status) !== "1" || String(info.isdelete) !== "0") return result("ended");
  if (Number(info.otherId) !== 2) return result("unsupported", "activity_unsupported");
  const reason = requirement(contentObject(info.content), location);
  if (reason) return result("unsupported", reason);
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
  if (remoteId(latest.classId) !== classId || Number(latest.courseId) !== 2)
    return result("unsupported", "activity_unsupported");
  const latestContent = contentObject(latest.content);
  const latestReason = requirement(latestContent, location);
  if (latestReason) return result("unsupported", latestReason);
  if (ctx.now() - scanTime > 30000) return result("rejected", "qr_expired");
  const fields = {
    name: account.label,
    uid: account.id,
    fid: account.fid,
    appType: 15,
    ifCFP: 0,
    currentFaceId: "",
    clientip: "",
    latitude: location ? String(location.latitude) : "-1",
    longitude: location ? String(location.longitude) : "-1",
    address: location?.address ?? "",
    ifTiJiao: 0,
    vpProbability: "",
    vpStrategy: "",
    activeId: activity.id,
    enc: activity.enc,
    deviceCode: clientIdentity(account.id).deviceCode,
  };
  if (flag(latestContent.ifopenAddress) === 1) {
    const position = JSON.stringify({
      address: location.address,
      latitude: String(location.latitude),
      longitude: String(location.longitude),
      result: "1",
    });
    fields.location = position;
    fields.locationResult = position;
    fields.ifTiJiao = 1;
  }
  // From this point a failed transport can have delivered a side effect. Never
  // repeat this POST, including CAPTCHA, redirects, cancellation or timeouts.
  let response = "";
  try {
    response = (
      await client.text(`${MOBILE}/pptSign/stuSignajax`, {
        method: "POST",
        redirect: "error",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-Requested-With": "XMLHttpRequest",
          Referer: preSign,
        },
        body: encodeForm(fields),
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
  if (/validate|验证码/.test(response)) return result("unsupported", "verification_required");
  if (/人脸/.test(response)) return result("unsupported", "face_required");
  if (/定位|位置|范围/.test(response)) return result("rejected", "location_rejected");
  if (/二维码.*(过期|失效)|enc.*(invalid|expired)/i.test(response)) return result("rejected", "qr_expired");
  if (["签到已结束", "活动已结束"].includes(response)) return result("ended");
  if (response === "签到失败") return result("rejected", "submission_rejected");
  return result("unknown");
}
