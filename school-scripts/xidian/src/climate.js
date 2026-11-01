/*! Copyright 2026 elecon contributors; 2026 Traintime PDA authors, originally aqqkad.
 * SPDX-License-Identifier: MPL-2.0
 * Protocol: PDA miscellaneous_session/aircon_session.dart and aircon_remote_page.dart.
 * ADR-040 §3 / ADR-046: bound device, one ordinary control POST, never retry.
 */

import { failure } from "./errors.js";
import { integer, number, text } from "./normalize.js";

const ORIGIN = "https://gxkt.juhaolian.cn";
const ADDRESS = { namespace: "xidian.climate" };
const MODES = ["fan", "heat", "cool", "dry", "auto"];
const FANS = ["auto", "silent", "low", "medium", "high"];
const HEADERS = {
  "Content-Type": "application/json",
  "User-Agent":
    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.73(0x18004939) NetType/WIFI Language/zh_CN",
};

function deviceId(value) {
  if (typeof value !== "string" || !/^\d{15}$/.test(value)) throw new Error("climate_device_invalid");
  return value;
}
async function binding(ctx) {
  const record = await ctx.credentials.get("device", ADDRESS);
  if (!record) return null;
  const value = JSON.parse(record.value);
  deviceId(value.deviceId);
  return value;
}
async function bound(ctx, id) {
  const device = await binding(ctx);
  if (!device || device.deviceId !== deviceId(id)) throw new Error("climate_device_not_bound");
  return device;
}
async function responseJSON(response) {
  if (!response.ok) throw new Error("climate_request_failed");
  const data = await response.json();
  if (!data || typeof data !== "object" || Array.isArray(data) || data.success !== true)
    throw new Error("climate_response_invalid");
  return data;
}
async function status(ctx, id) {
  const data = await responseJSON(
    await ctx.fetch(`${ORIGIN}/api/device/direct/state?imei=${encodeURIComponent(id)}`, {
      method: "GET",
      headers: HEADERS,
      redirect: "error",
    }),
  );
  const raw = data.result;
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || (raw.imei != null && raw.imei !== id))
    throw new Error("climate_state_invalid");
  const output = { deviceId: id };
  const flags = {
    switchStatus: "power",
    verticalSwing: "verticalSwing",
    strongMode: "turbo",
    electricHeating: "auxiliaryHeat",
    indoorClean: "indoorClean",
    outdoorClean: "outdoorClean",
  };
  for (const [key, target] of Object.entries(flags)) {
    if (raw[key] != null) {
      const value = integer(raw[key], "climate_flag");
      if (value !== 0 && value !== 1) throw new Error("climate_state_invalid");
      output[target] = value === 1;
    }
  }
  for (const [key, target, values] of [
    ["runMode", "mode", MODES],
    ["windSpeed", "fanSpeed", FANS],
  ]) {
    if (raw[key] != null) {
      const index = integer(raw[key], "climate_enum");
      if (!values[index]) throw new Error("climate_state_invalid");
      output[target] = values[index];
    }
  }
  if (raw.tempSet != null) {
    const value = integer(raw.tempSet, "climate_temperature");
    if (value < 18 || value > 32) throw new Error("climate_state_invalid");
    output.targetTemperature = value;
  }
  if (raw.indoorTemp != null) output.indoorTemperature = number(raw.indoorTemp, "climate_indoor_temperature");
  if (raw.timestamp != null) {
    const seconds = integer(raw.timestamp, "climate_timestamp");
    if (seconds <= 0 || seconds * 1000 > ctx.now() + 300000) throw new Error("climate_state_invalid");
    output.observedAt = new Date(seconds * 1000).toISOString();
  }
  if (typeof raw.online === "boolean") output.online = raw.online;
  if (text(raw.errCode) && text(raw.errCode) !== "0") output.errorCode = "device_error";
  // electricAmount's remaining/cumulative semantics are not evidenced: omit it.
  if (Object.keys(output).length === 1) throw new Error("climate_state_invalid");
  return output;
}

export async function climateDevices(ctx, params = {}) {
  let device = await binding(ctx);
  if (!device || params.configure === true) {
    if (!ctx.ui) throw new Error("input_unavailable");
    const input = await ctx.ui.requestInput({
      title: "绑定宿舍空调",
      message: "填写你有权控制的空调设备 IMEI（15 位数字）。请从设备标签获取，不要填写其他房间的设备。",
      fields: [
        { id: "deviceId", label: "设备 IMEI", maxLength: 15 },
        { id: "label", label: "设备名称", required: false, maxLength: 120 },
      ],
    });
    if (input === null) throw failure("input_cancelled");
    device = { deviceId: deviceId(text(input.deviceId)), label: text(input.label) || "宿舍空调" };
    await status(ctx, device.deviceId);
    await ctx.credentials.set("device", JSON.stringify(device), {
      ...ADDRESS,
      type: "query",
      expiresAt: null,
    });
  } else await status(ctx, device.deviceId);
  return {
    items: [
      {
        ...device,
        minTemperature: 18,
        maxTemperature: 32,
        modes: MODES,
        fanSpeeds: FANS,
        commands: ["power", "temperature", "mode", "fanSpeed", "verticalSwing", "turbo", "auxiliaryHeat"],
        modeDefaults: MODES.map((mode) => ({
          mode,
          targetTemperature: mode === "heat" ? 23 : mode === "cool" ? 26 : 25,
          fanSpeed: mode === "fan" ? "medium" : "auto",
          turbo: false,
          auxiliaryHeat: false,
          indoorClean: false,
          outdoorClean: false,
        })),
        powerOffClearsAuxiliaryHeat: true,
        powerOffClearsCleaning: true,
        fanSpeedClearsTurbo: true,
        turboUsesAutoFan: true,
      },
    ],
  };
}
export async function climateStatus(ctx, params = {}) {
  const device = await bound(ctx, params.deviceId);
  return status(ctx, device.deviceId);
}

export async function climateCommand(ctx, params = {}) {
  const device = await bound(ctx, params.deviceId);
  const settings = params.settings;
  if (!settings || typeof settings !== "object" || Array.isArray(settings))
    throw new Error("climate_command_invalid");
  const mapping = {
    power: "switchStatus",
    mode: "runMode",
    fanSpeed: "windSpeed",
    targetTemperature: "tempSet",
    verticalSwing: "verticalSwing",
    turbo: "strongMode",
    auxiliaryHeat: "electricHeating",
    indoorClean: "indoorClean",
    outdoorClean: "outdoorClean",
  };
  const allowed = {
    power: ["power", "auxiliaryHeat", "indoorClean", "outdoorClean"],
    temperature: ["targetTemperature"],
    mode: ["mode", "targetTemperature", "fanSpeed", "turbo", "auxiliaryHeat", "indoorClean", "outdoorClean"],
    fanSpeed: ["fanSpeed", "turbo"],
    verticalSwing: ["verticalSwing"],
    turbo: ["turbo", "fanSpeed"],
    auxiliaryHeat: ["auxiliaryHeat"],
  }[params.command];
  if (
    !allowed ||
    !Object.keys(settings).length ||
    Object.keys(settings).some((key) => !allowed.includes(key))
  )
    throw new Error("climate_command_invalid");
  let expected;
  if (params.command === "mode") {
    const mode = settings.mode;
    expected = {
      mode,
      targetTemperature: mode === "heat" ? 23 : mode === "cool" ? 26 : 25,
      fanSpeed: mode === "fan" ? "medium" : "auto",
      turbo: false,
      auxiliaryHeat: false,
      indoorClean: false,
      outdoorClean: false,
    };
  } else if (params.command === "power") {
    expected = {
      power: settings.power,
      ...(settings.power === false ? { auxiliaryHeat: false, indoorClean: false, outdoorClean: false } : {}),
    };
  } else if (params.command === "fanSpeed") expected = { fanSpeed: settings.fanSpeed, turbo: false };
  else if (params.command === "turbo")
    expected = { turbo: settings.turbo, ...(settings.turbo === true ? { fanSpeed: "auto" } : {}) };
  else
    expected = {
      [params.command === "temperature" ? "targetTemperature" : params.command]:
        settings[params.command === "temperature" ? "targetTemperature" : params.command],
    };
  if (
    Object.keys(expected).length !== Object.keys(settings).length ||
    Object.entries(expected).some(([key, value]) => value === undefined || value !== settings[key])
  )
    throw new Error("climate_command_invalid");
  const payload = { imei: device.deviceId };
  for (const [key, value] of Object.entries(settings)) {
    if (key === "mode" || key === "fanSpeed") {
      const index = (key === "mode" ? MODES : FANS).indexOf(value);
      if (index < 0) throw new Error("climate_command_invalid");
      payload[mapping[key]] = key === "mode" || params.command === "fanSpeed" ? String(index) : index;
    } else if (key === "targetTemperature") {
      if (!Number.isInteger(value) || value < 18 || value > 32) throw new Error("climate_command_invalid");
      payload.tempSet = value;
      if (params.command === "mode") payload.tempView = value;
    } else {
      if (typeof value !== "boolean") throw new Error("climate_command_invalid");
      payload[mapping[key]] = value ? 1 : 0;
    }
  }
  const response = await ctx.fetch(`${ORIGIN}/api/device/direct/command`, {
    method: "POST",
    headers: HEADERS,
    body: JSON.stringify(payload),
    redirect: "error",
  });
  if (!response.ok)
    return {
      status:
        response.status >= 400 && response.status < 500 && response.status !== 408 ? "rejected" : "unknown",
    };
  const data = await response.json();
  return { status: data?.success === true ? "accepted" : data?.success === false ? "rejected" : "unknown" };
}
