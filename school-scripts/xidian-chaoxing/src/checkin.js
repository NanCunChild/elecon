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
      // Current service QR links also carry STRATEGY_PARA=id alongside
      // DB_STRATEGY=PRIMARY_KEY. These are page-routing hints only: the request
      // flow below uses the validated id/enc and fixed endpoints, never a
      // caller-selected strategy or query forwarded from the QR.
      if (
        !["id", "enc", "c", "qrCode", "DB_STRATEGY", "STRATEGY_PARA"].includes(key) ||
        Object.keys(values).includes(key)
      )
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
// The probe accepts only script-owned stage/event names and normalized values.
// It never emits response text, URLs, IDs, credentials, QR data or coordinates.
function checkinProbe(ctx) {
  const stages = [
    "input",
    "authentication",
    "scan",
    "qr_validation",
    "attendance_before",
    "activity",
    "class_detail",
    "analysis",
    "analysis_confirm",
    "presign",
    "attendance_after_presign",
    "activity_recheck",
    "submission",
    "verification",
  ];
  let stage = "input";
  const bits = ["?", "?", "?", "?", "0", "0", "?", "?"];
  const started = ctx.now();
  const record = (event, fields = {}) => {
    try {
      const elapsedMs = Math.min(120000, Math.max(0, Math.trunc(ctx.now() - started)));
      if (event === "requirements") {
        for (const [i, key] of ["location", "face", "verification", "photo"].entries())
          bits[i] = fields[key] == null ? "?" : fields[key] ? "1" : "0";
      }
      if (event === "selection") bits[4] = fields.location ? "1" : "0";
      if (event === "start" && stage === "submission") bits[5] = "1";
      if (event === "attendance") bits[6] = fields.confirmed ? "1" : "0";
      if (event === "result" && ["confirmed", "already"].includes(fields.status)) bits[6] = "1";
      if (event === "response") bits[7] = fields.kind === "unrecognized" ? "0" : "1";
      const outcome =
        event === "start"
          ? "begin"
          : event === "failure"
            ? "failed"
            : event === "http"
              ? fields.status >= 200 && fields.status < 300
                ? "ok"
                : "failed"
              : event === "result"
                ? ["confirmed", "already"].includes(fields.status)
                  ? "ok"
                  : fields.status === "cancelled"
                    ? "skipped"
                    : fields.status === "unknown"
                      ? "unknown"
                      : "failed"
                : (event === "response" && fields.kind === "unrecognized") ||
                    (event === "attendance" && !fields.confirmed)
                  ? "unknown"
                  : "ok";
      // Production logs accept this bounded, host-validated numeric grammar.
      // The descriptive line stays in the existing debug-only script channel.
      ctx.log?.(
        "info",
        `probe/1 stage=${stages.indexOf(stage) + 1} event=${outcome} http=${event === "http" ? (fields.status ?? 0) : 0} ms=${elapsedMs} flags=${bits.join("")}`,
      );
      // Keep normal start/HTTP events to one line so the final verification
      // survives the host's 100-line budget even with allowed redirects.
      if (["failure", "requirements", "response", "result"].includes(event))
        ctx.log?.("info", "checkin_probe " + JSON.stringify({ v: 1, stage, event, elapsedMs, ...fields }));
    } catch {
      // Logging must never affect whether a submitted command is delivered,
      // retried, or independently confirmed, including a full host log budget.
    }
  };
  const failure = (error) => {
    const allowed = [
      "authentication_required",
      "input_invalid_request",
      "input_unavailable",
      "source_response_invalid",
      "network_denied",
      "invocation_cancelled",
      "request_timeout",
    ];
    record("failure", { code: allowed.includes(error?.code) ? error.code : "request_failed" });
  };
  return {
    record,
    failure,
    enter(name) {
      stage = name;
      record("start");
    },
    requirements(content) {
      record("requirements", {
        location: flag(content?.ifopenAddress),
        face: flag(content?.openCheckFaceFlag),
        verification: flag(content?.ifNeedVcode),
        photo: ["ifphoto", "photo", "ifNeedPhoto", "isPhoto"].some(
          (k) => content?.[k] != null && flag(content[k]) !== 0,
        ),
      });
    },
    context: {
      ...ctx,
      fetch: async (...args) => {
        try {
          const response = await ctx.fetch(...args);
          record("http", {
            status:
              Number.isInteger(response.status) && response.status >= 100 && response.status <= 599
                ? response.status
                : null,
          });
          return response;
        } catch (error) {
          failure(error);
          throw error;
        }
      },
    },
  };
}
export async function attendanceCheckin(ctx, params = {}) {
  const probe = checkinProbe(ctx);
  // Authentication is explicit; no surprise account switching or login retry
  // after scanning a short-lived ticket. Probe the pre-scan failure path too.
  let location, client, account, activity;
  try {
    probe.enter("input");
    location = selectedLocation(params);
    probe.record("selection", { location: !!location });
    probe.enter("authentication");
    ({ client, account } = await chaoxingClient(probe.context));
    probe.enter("scan");
    if (!ctx.ui?.scanQRCode) throw serviceError("input_unavailable");
    const scan = await ctx.ui.scanQRCode();
    if (!scan) {
      probe.record("result", { status: "cancelled" });
      return { status: "cancelled" };
    }
    probe.enter("qr_validation");
    activity = parseCheckinQr(scan.text);
  } catch (error) {
    probe.failure(error);
    throw error;
  }
  const result = (status, reason) => {
    probe.record("result", { status, ...(reason ? { reason } : {}) });
    return { status, activityId: activity.id, ...(reason ? { reason } : {}) };
  };
  try {
    return await submitScanned(ctx, client, account, activity, location, result, probe);
  } catch (error) {
    probe.failure(error);
    if (error?.code === "authentication_required") throw error;
    return result("rejected", "request_failed");
  }
}
async function submitScanned(ctx, client, account, activity, location, result, probe) {
  const scanTime = ctx.now();
  probe.enter("attendance_before");
  if (await attended(client, activity.id)) return result("already");
  probe.enter("activity");
  const info = (await client.json(urlFor("/v2/apis/active/getPPTActiveInfo", { activeId: activity.id })))
    ?.data;
  if (!info || ![0, 1, "0", "1"].includes(info.status) || ![0, 1, "0", "1"].includes(info.isdelete))
    throw serviceError();
  if (String(info.status) !== "1" || String(info.isdelete) !== "0") return result("ended");
  if (Number(info.otherId) !== 2) return result("unsupported", "activity_unsupported");
  const content = contentObject(info.content);
  probe.requirements(content);
  const reason = requirement(content, location);
  if (reason) return result("unsupported", reason);
  probe.enter("class_detail");
  const classId = remoteId(info.clazzid);
  const detail = (await client.json(urlFor("/v2/apis/class/getClassDetail", { classId, courseId: "" })))
    ?.data;
  const courseId = remoteId(detail?.courseid);
  probe.enter("analysis");
  const analysis = await client.text(
    urlFor("/pptSign/analysis", { vs: 1, DB_STRATEGY: "RANDOM", aid: activity.id }),
  );
  const code = /\b([0-9a-f]{32})\b/i.exec(analysis)?.[1];
  probe.record("response", { kind: code ? "analysis_code" : "unrecognized" });
  if (!code) throw serviceError();
  probe.enter("analysis_confirm");
  const analysisResult = (
    await client.text(urlFor("/pptSign/analysis2", { code, DB_STRATEGY: "RANDOM" }))
  ).trim();
  probe.record("response", { kind: analysisResult === "success" ? "success" : "unrecognized" });
  if (analysisResult !== "success") throw serviceError();
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
  probe.enter("presign");
  const preSignPage = await client.text(preSign);
  probe.record("response", { kind: /zsign_success/.test(preSignPage) ? "already_hint" : "unrecognized" });
  probe.enter("attendance_after_presign");
  if (await attended(client, activity.id)) return result("already");
  probe.enter("activity_recheck");
  const latest = await client.json(urlFor("/ppt/renwuAPI/getActive", { aid: activity.id }));
  if (remoteId(latest.classId) !== classId || Number(latest.courseId) !== 2)
    return result("unsupported", "activity_unsupported");
  const latestContent = contentObject(latest.content);
  probe.requirements(latestContent);
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
  let responseKind = "empty";
  probe.enter("submission");
  try {
    const response = (
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
    responseKind = submissionResponse(response);
    probe.record("response", { kind: responseKind });
  } catch (error) {
    probe.failure(error);
    /* Only the independent read below may resolve delivery uncertainty. */
  }
  probe.enter("verification");
  try {
    if (await attended(client, activity.id)) return result("confirmed");
    probe.record("attendance", { confirmed: false });
  } catch (error) {
    probe.failure(error);
    return result("unknown");
  }
  if (["verification_required", "face_required"].includes(responseKind))
    return result("unsupported", responseKind);
  if (["location_rejected", "qr_expired", "submission_rejected"].includes(responseKind))
    return result("rejected", responseKind);
  if (responseKind === "ended") return result("ended");
  return result("unknown");
}

// Bounded classifications are useful even when the remote body contains tokens,
// account names or location strings; none of that text enters the diagnostic.
function submissionResponse(response) {
  if (response === "success") return "success";
  if (!response) return "empty";
  if (/validate|验证码/.test(response)) return "verification_required";
  if (/人脸/.test(response)) return "face_required";
  if (/定位|位置|范围/.test(response)) return "location_rejected";
  if (/二维码.*(过期|失效)|enc.*(invalid|expired)/i.test(response)) return "qr_expired";
  if (["签到已结束", "活动已结束"].includes(response)) return "ended";
  if (response === "签到失败") return "submission_rejected";
  return "unrecognized";
}
