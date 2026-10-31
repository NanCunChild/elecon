/*! Copyright 2023-2025 BenderBlog Rodriguez and contributors; 2025 Traintime PDA authors; 2026 elecon contributors.
 * SPDX-License-Identifier: MPL-2.0
 * Protocol adapted from PDA ids_session/energy_session.dart.
 * ADR-040 §2: school-network queries, independent session and exact meanings.
 */
import { encryptEnergy } from "./energy_crypto.js";
import { failure } from "./errors.js";
import { dateOnly, integer, number, schoolDateTime, text } from "./normalize.js";
import { PDA_UA } from "./pda_constants.js";
import { createClient, parseUrl, readSession, saveSession } from "./session.js";
import { loginIds } from "./webview_login.js";

const ORIGIN = "https://ignypt.xidian.edu.cn";
const OAUTH = `https://xxcapp.xidian.edu.cn/uc/api/oauth/index?redirect=${ORIGIN}/revenueH5/login?opcode=MPAY&appid=200260318155520600&state=12312312312312&qrcode=0`;
const PATH = "/estManage/api/WeChat/V2/";
const auth = () => new Error("energy_authentication_required");
function rows(data) {
  const raw = data?.ResData?.rows;
  if (!Array.isArray(raw) || data.success === false || raw.length > 2000)
    throw new Error("energy_response_invalid");
  for (const key of ["total", "totalSize", "totalCount"]) {
    if (data.ResData[key] != null && integer(data.ResData[key]) > raw.length)
      throw new Error("energy_response_incomplete");
  }
  return raw;
}
function schoolDay(time) {
  return new Date(time + 8 * 3600000).toISOString().slice(0, 10);
}
function previousPeriod(day, years, months) {
  const source = new Date(`${day}T00:00:00Z`);
  const date = new Date(Date.UTC(source.getUTCFullYear() - years, source.getUTCMonth() - months, 1));
  const last = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0)).getUTCDate();
  date.setUTCDate(Math.min(source.getUTCDate(), last));
  return date.toISOString().slice(0, 10);
}
async function encrypted(client, path, value, post = false) {
  // PDA idsDio defaults to form-urlencoded for GetSignature.
  const sign = await client.postForm(`${ORIGIN}/baseNew/api/User/GetSignature`, {
    data: "",
    access_token: "",
    OpCode: "MPAY",
    RequestID: "",
  });
  const timestamp = text(sign?.data?.timestamp),
    signature = text(sign?.data?.signature);
  if (!/^\d{1,20}$/.test(timestamp) || !signature || /[\r\n]/.test(signature) || signature.length > 4096)
    throw new Error("energy_signature_invalid");
  const headers = { timestamp, signature, OpCode: "MPAY", OrgId: "", RequestID: "" };
  const content = encryptEnergy(value);
  // PDA Uri.encodeComponent followed by Dio query encoding is intentionally double encoded.
  return post
    ? client.postJSON(`${ORIGIN}${path}`, { content }, { headers })
    : client.getJSON(`${ORIGIN}${path}?content=${encodeURIComponent(encodeURIComponent(content))}`, {
        headers,
      });
}
async function open(ctx, params, force) {
  const ids = await readSession(ctx, "ids");
  if (!ids) throw auth();
  const previous = force ? null : await readSession(ctx, "energy");
  const session = previous ?? { version: 1, service: "energy", cookies: [], data: {} };
  const client = await createClient(ctx, "energy", {
    initialSession: session,
    persistSession: false,
    maxRedirects: 20,
    userAgent: PDA_UA,
  });
  if (!text(session.data.nodeId)) {
    const landing = await client.request(OAUTH);
    const target = parseUrl(landing.url);
    if (target.origin !== ORIGIN || target.path !== "/revenueH5/login") throw auth();
    const codeMatch = /(?:^\?|&)code=([^&]+)/.exec(target.query);
    if (!codeMatch) throw auth();
    const code = decodeURIComponent(codeMatch[1]);
    if (!code || code.length > 4096) throw new Error("energy_oauth_invalid");
    const user = await encrypted(client, `${PATH}OauthGetUserInfo`, { CODE: code });
    if (!user || typeof user !== "object" || user.ResData == null || user.success === false)
      throw new Error("energy_oauth_invalid");
    let studentId = text(params.studentId ?? ids.data.studentId);
    if (!studentId && ctx.ui) {
      const input = await ctx.ui.requestInput({
        title: "水电查询需要学号",
        fields: [{ id: "studentId", label: "学号", maxLength: 128 }],
      });
      if (input === null) throw failure("input_cancelled");
      studentId = text(input.studentId);
    }
    if (!studentId) throw failure("student_id_required");
    const login = await encrypted(
      client,
      `${PATH}H5UserIDLogIn`,
      { UserID: studentId, Pwd: "", IsCehckPwd: 1, NodeID: "" },
      true,
    );
    if (
      !Array.isArray(login?.ResData) ||
      !login.ResData.length ||
      login.ResData.length > 1 ||
      !text(login.ResData[0].NodeID)
    )
      throw new Error("energy_login_invalid");
    session.data = { nodeId: text(login.ResData[0].NodeID), studentId };
  }
  const raw = await encrypted(client, "/estManage/api/wechat/v2/H5QueryMeterList", {
    NodeID: session.data.nodeId,
  });
  const idsSeen = new Set();
  const meters = rows(raw).map((row) => {
    if (!row || typeof row !== "object") throw new Error("energy_meter_invalid");
    const meterId = text(row.MetID),
      medium = text(row.MediumCode);
    if (!meterId || meterId.length > 128 || idsSeen.has(meterId) || !["1", "2"].includes(medium))
      throw new Error("energy_meter_invalid");
    idsSeen.add(meterId);
    const meter = {
      meterId,
      type: medium === "1" ? "water" : "electricity",
      unit: medium === "1" ? "m³" : "kWh",
    };
    if (medium === "2" && row.LastNum != null) meter.remaining = number(row.LastNum, "energy_remaining");
    if (text(row.LastReadDate)) meter.lastReadDate = dateOnly(row.LastReadDate);
    if (text(row.MetName)) meter.label = text(row.MetName);
    return meter;
  });
  if (meters.length > 100) throw new Error("energy_meter_limit");
  // Commit only after a valid account/meter result; preserve old session on failure.
  await saveSession(ctx, "energy", session);
  return { client, meters };
}
async function withEnergy(ctx, params, handler) {
  try {
    return await handler(await open(ctx, params, false));
  } catch (error) {
    if (!["energy_authentication_required", "xidian_login_required_energy"].includes(error?.message))
      throw error;
    if (!ctx.browser) throw failure("xidian_login_required_ehall");
    await loginIds(ctx, params, "undergraduate");
    return handler(await open(ctx, params, true)); // one read-only reauthentication attempt
  }
}
export async function energyMeters(ctx, params = {}) {
  return withEnergy(ctx, params, async ({ meters }) => ({ items: meters }));
}
export async function energyUsage(ctx, params = {}) {
  // Reject invalid windows before account/network I/O.
  for (const key of ["from", "to"])
    if (
      params[key] != null &&
      (typeof params[key] !== "string" ||
        !/(?:Z|[+-]\d\d:\d\d)$/.test(params[key]) ||
        !Number.isFinite(Date.parse(params[key])))
    )
      throw new Error("energy_window_invalid");
  if (params.from && params.to && Date.parse(params.from) > Date.parse(params.to))
    throw new Error("energy_window_invalid");
  return withEnergy(ctx, params, async ({ client, meters }) => {
    if (!meters.length) return { items: [] };
    let meterId = params.meterId;
    if (!meterId && ctx.ui) {
      if (meters.length > 20) throw new Error("energy_meter_selection_required");
      const input = await ctx.ui.requestInput({
        title: "选择水电表",
        fields: [
          {
            id: "meterId",
            label: "计量表",
            type: "select",
            options: meters.map((m) => ({
              value: m.meterId,
              label: `${m.label || (m.type === "water" ? "水表" : "电表")} · ${m.meterId}`,
            })),
          },
        ],
      });
      if (input === null) throw failure("input_cancelled");
      meterId = input.meterId;
    }
    const meter = meters.find((m) => m.meterId === meterId);
    if (!meter) throw new Error("energy_meter_selection_required");
    const end = params.to
      ? schoolDay(Date.parse(params.to))
      : meter.type === "electricity"
        ? meter.lastReadDate || schoolDay(ctx.now())
        : schoolDay(ctx.now());
    const start = params.from
      ? schoolDay(Date.parse(params.from))
      : previousPeriod(end, meter.type === "water" ? 1 : 0, meter.type === "electricity" ? 1 : 0);
    if (Date.parse(end) - Date.parse(start) > 366 * 86400000) throw new Error("energy_window_limit");
    const raw = await encrypted(client, `${PATH}GetMetRead`, {
      MetID: meterId,
      ReadTimeS: start,
      ReadTimeE: end,
      ReadNum: "",
    });
    const items = rows(raw)
      .map((row) => {
        if (!row || typeof row !== "object") throw new Error("energy_reading_invalid");
        // Source date-only readings represent local midnight, never query time.
        const readAt = schoolDateTime(
          /^\d{4}-\d{2}-\d{2}$/.test(text(row.ReadTime)) ? `${row.ReadTime} 00:00:00` : row.ReadTime,
        );
        return {
          meterId,
          type: meter.type,
          unit: meter.unit,
          readAt,
          usage: number(row.ReadNum, "energy_usage"),
          reading: number(row.EndNum, "energy_reading"),
          previousReading: number(row.StartNum, "energy_previous_reading"),
        };
      })
      .filter(
        (row) =>
          (!params.from || Date.parse(row.readAt) >= Date.parse(params.from)) &&
          (!params.to || Date.parse(row.readAt) <= Date.parse(params.to)),
      );
    items.sort((a, b) => a.readAt.localeCompare(b.readAt));
    return { items };
  });
}
