// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Entirely synthetic accounts, devices and HTTP; never contacts school/IoT.
import assert from "node:assert/strict";
import { createCipheriv, createDecipheriv } from "node:crypto";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { aes128Cbc, encryptEnergy } from "../src/energy_crypto.js";

const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/undergraduate.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const { capabilities } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString("base64")}`
);
const NOW = Date.parse("2026-03-31T08:00:00Z");
const ID = "0".repeat(15);
function response(url, data, status = 200, headers = {}) {
  return {
    url,
    status,
    ok: status >= 200 && status < 300,
    headers: { getSetCookie: () => [], get: (name) => headers[name] ?? null },
    json: async () => data,
    text: async () => (typeof data === "string" ? data : JSON.stringify(data)),
  };
}
function decrypt(value) {
  const key = Buffer.from("1234567812345678"),
    c = createDecipheriv("aes-128-cbc", key, key);
  return JSON.parse(Buffer.concat([c.update(Buffer.from(value, "base64")), c.final()]).toString());
}
function harness({
  meters,
  history,
  rawState,
  commandStatus = 200,
  commandData = { success: true },
  cachedEnergy = false,
} = {}) {
  const records = new Map();
  const calls = [];
  let signatures = 0;
  records.set(
    "xidian.auth:ids",
    JSON.stringify({ version: 1, service: "ids", cookies: [], data: { studentId: "SYNTHETIC-STUDENT" } }),
  );
  if (cachedEnergy)
    records.set(
      "xidian.auth:energy",
      JSON.stringify({ version: 1, service: "energy", cookies: [], data: { nodeId: "SYNTHETIC-NODE" } }),
    );
  const ctx = {
    now: () => NOW,
    log() {},
    credentials: {
      async get(key, options) {
        const value = records.get(`${options.namespace}:${key}`);
        return value ? { value } : null;
      },
      async set(key, value, options) {
        records.set(`${options.namespace}:${key}`, value);
      },
    },
    ui: {
      async requestInput(request) {
        return request.fields[0].id === "deviceId"
          ? { deviceId: ID, label: "Synthetic room" }
          : { meterId: "SYNTHETIC-WATER" };
      },
    },
    async fetch(raw, init) {
      const url = new URL(raw);
      const call = { url, init };
      calls.push(call);
      if (url.hostname === "gxkt.juhaolian.cn") {
        if (url.pathname.endsWith("/state")) {
          assert.equal(url.searchParams.get("imei"), ID);
          return response(raw, {
            success: true,
            result: rawState ?? {
              imei: ID,
              switchStatus: 1,
              runMode: 2,
              windSpeed: 0,
              tempSet: 26,
              indoorTemp: 25.5,
              verticalSwing: 0,
              strongMode: 0,
              electricHeating: 0,
              indoorClean: 0,
              outdoorClean: 0,
              timestamp: NOW / 1000,
              errCode: "0",
            },
          });
        }
        assert.equal(url.pathname, "/api/device/direct/command");
        assert.equal(init.redirect, "error");
        call.data = JSON.parse(init.body);
        return response(raw, commandData, commandStatus);
      }
      if (url.hostname === "xxcapp.xidian.edu.cn")
        return response(raw, "", 302, {
          location: "https://ignypt.xidian.edu.cn/revenueH5/login?code=SYNTHETIC-CODE",
        });
      assert.equal(url.origin, "https://ignypt.xidian.edu.cn");
      if (url.pathname === "/revenueH5/login") return response(raw, "landing");
      if (url.pathname.endsWith("GetSignature")) {
        assert.equal(init.method, "POST");
        assert.match(init.headers["Content-Type"], /^application\/x-www-form-urlencoded/);
        assert.equal(new URLSearchParams(init.body).get("OpCode"), "MPAY");
        return response(raw, {
          data: { timestamp: String(++signatures), signature: `SYNTHETIC-SIGN-${signatures}` },
        });
      }
      assert.equal(init.headers.signature, `SYNTHETIC-SIGN-${signatures}`);
      call.data = decrypt(
        init.method === "POST"
          ? JSON.parse(init.body).content
          : decodeURIComponent(url.searchParams.get("content")),
      );
      if (url.pathname.endsWith("OauthGetUserInfo")) {
        assert.deepEqual(call.data, { CODE: "SYNTHETIC-CODE" });
        return response(raw, { ResData: {} });
      }
      if (url.pathname.endsWith("H5UserIDLogIn")) {
        assert.deepEqual(call.data, { UserID: "SYNTHETIC-STUDENT", Pwd: "", IsCehckPwd: 1, NodeID: "" });
        return response(raw, { ResData: [{ NodeID: "SYNTHETIC-NODE" }] });
      }
      if (url.pathname.endsWith("H5QueryMeterList"))
        return response(raw, {
          ResData: {
            rows: meters ?? [
              { MetID: "SYNTHETIC-ELECTRIC", MediumCode: "2", LastNum: "75.25", LastReadDate: "2026-03-31" },
              { MetID: "SYNTHETIC-WATER", MediumCode: "1" },
            ],
          },
        });
      if (url.pathname.endsWith("GetMetRead"))
        return response(raw, {
          ResData: history ?? {
            rows: [{ ReadTime: "2026-03-30 08:00:00", ReadNum: "2.5", StartNum: "10", EndNum: "12.5" }],
          },
        });
      throw Error("unexpected synthetic endpoint");
    },
  };
  return { ctx, records, calls, signatures: () => signatures };
}
test("AES-CBC/PKCS7 agrees with independent OpenSSL for blocks, UTF8 and empty input", () => {
  for (const value of [{}, { CODE: "合成😀" }, { NodeID: "x".repeat(256) }]) {
    const key = Buffer.from("1234567812345678");
    const c = createCipheriv("aes-128-cbc", key, key);
    assert.equal(
      encryptEnergy(value),
      Buffer.concat([c.update(JSON.stringify(value)), c.final()]).toString("base64"),
    );
  }
  const key = Buffer.from("2b7e151628aed2a6abf7158809cf4f3c", "hex"),
    iv = Buffer.from("000102030405060708090a0b0c0d0e0f", "hex");
  const plain = Buffer.from("6bc1bee22e409f96e93d7e117393172a", "hex");
  assert.equal(
    Buffer.from(aes128Cbc(plain, key, iv))
      .subarray(0, 16)
      .toString("hex"),
    "7649abac8119b246cee98e9b12e9197d",
  );
});
test("OAuth, fresh per-request signatures and independent water/electric meters", async () => {
  const h = harness();
  const result = await capabilities["energy.meters"](h.ctx);
  assert.deepEqual(result.items, [
    {
      meterId: "SYNTHETIC-ELECTRIC",
      type: "electricity",
      unit: "kWh",
      remaining: 75.25,
      lastReadDate: "2026-03-31",
    },
    { meterId: "SYNTHETIC-WATER", type: "water", unit: "m³" },
  ]);
  assert.equal(h.signatures(), 3);
  assert.equal(JSON.parse(h.records.get("xidian.auth:energy")).data.nodeId, "SYNTHETIC-NODE");
});
test("history retains usage and cumulative/previous reading meanings", async () => {
  const h = harness({ cachedEnergy: true });
  const result = await capabilities["energy.usage"](h.ctx, { meterId: "SYNTHETIC-ELECTRIC" });
  assert.deepEqual(result.items, [
    {
      meterId: "SYNTHETIC-ELECTRIC",
      type: "electricity",
      unit: "kWh",
      readAt: "2026-03-30T00:00:00.000Z",
      usage: 2.5,
      reading: 12.5,
      previousReading: 10,
    },
  ]);
  const call = h.calls.find((c) => c.url.pathname.endsWith("GetMetRead"));
  assert.deepEqual(call.data, {
    MetID: "SYNTHETIC-ELECTRIC",
    ReadTimeS: "2026-02-28",
    ReadTimeE: "2026-03-31",
    ReadNum: "",
  });
  assert.equal(h.signatures(), 2);
});
test("explicit dates and selection are respected; no arbitrary or first-meter fallback", async () => {
  const h = harness({ cachedEnergy: true });
  await capabilities["energy.usage"](h.ctx, {
    from: "2026-03-01T00:00:00+08:00",
    to: "2026-03-31T23:59:59+08:00",
  });
  assert.deepEqual(h.calls.find((c) => c.url.pathname.endsWith("GetMetRead")).data, {
    MetID: "SYNTHETIC-WATER",
    ReadTimeS: "2026-03-01",
    ReadTimeE: "2026-03-31",
    ReadNum: "",
  });
  const bad = harness({ cachedEnergy: true });
  await assert.rejects(capabilities["energy.usage"](bad.ctx, { meterId: "NOT-BOUND" }));
  assert.ok(!bad.calls.some((c) => c.url.pathname.endsWith("GetMetRead")));
  const invalid = harness();
  await assert.rejects(
    capabilities["energy.usage"](invalid.ctx, { from: "2026-04-01T00:00:00Z", to: "2026-03-01T00:00:00Z" }),
  );
  assert.equal(invalid.calls.length, 0);
});
test("empty account is valid; malformed, duplicate and truncated school results fail", async () => {
  assert.deepEqual(await capabilities["energy.meters"](harness({ meters: [] }).ctx), { items: [] });
  await assert.rejects(
    capabilities["energy.meters"](
      harness({ meters: [{ MetID: "X", MediumCode: "2", LastNum: "not-a-number" }] }).ctx,
    ),
  );
  await assert.rejects(
    capabilities["energy.meters"](
      harness({
        meters: [
          { MetID: "X", MediumCode: "1" },
          { MetID: "X", MediumCode: "2" },
        ],
      }).ctx,
    ),
  );
  await assert.rejects(
    capabilities["energy.usage"](harness({ cachedEnergy: true, history: { rows: [], total: 2 } }).ctx, {
      meterId: "SYNTHETIC-WATER",
    }),
  );
});
test("device binding is verified before save; state has no inferred remaining energy", async () => {
  const h = harness();
  const devices = (await capabilities["climate.devices"](h.ctx)).items;
  assert.equal(devices[0].deviceId, ID);
  assert.equal(devices[0].minTemperature, 18);
  assert.equal(devices[0].maxTemperature, 32);
  assert.equal(JSON.parse(h.records.get("xidian.climate:device")).deviceId, ID);
  const status = await capabilities["climate.status"](h.ctx, { deviceId: ID });
  assert.equal(status.power, true);
  assert.equal(status.mode, "cool");
  assert.equal(status.indoorTemperature, 25.5);
  assert.equal(status.indoorClean, false);
  assert.equal(status.outdoorClean, false);
  assert.equal(status.remainingEnergy, undefined);
  const bad = harness({ rawState: { imei: "9".repeat(15), switchStatus: 1 } });
  await assert.rejects(capabilities["climate.devices"](bad.ctx));
  assert.equal(bad.records.has("xidian.climate:device"), false);
});
test("invalid/unbound devices and wrong school roles fail before device traffic", async () => {
  const h = harness();
  await assert.rejects(capabilities["climate.status"](h.ctx, { deviceId: ID }));
  assert.equal(h.calls.length, 0);
  for (const capability of ["climate.devices", "climate.command", "energy.meters"])
    await assert.rejects(capabilities[capability](h.ctx, { role: "postgraduate" }));
  assert.equal(h.calls.length, 0);
});
test("command wire matches all selected mode effects, sends once and never claims applied", async () => {
  const h = harness();
  const device = (await capabilities["climate.devices"](h.ctx)).items[0];
  h.calls.length = 0;
  const settings = device.modeDefaults.find((m) => m.mode === "heat");
  assert.deepEqual(
    await capabilities["climate.command"](h.ctx, { deviceId: ID, command: "mode", settings }),
    { status: "accepted" },
  );
  assert.equal(h.calls.length, 1);
  assert.deepEqual(h.calls[0].data, {
    imei: ID,
    runMode: "1",
    tempSet: 23,
    tempView: 23,
    windSpeed: 0,
    strongMode: 0,
    electricHeating: 0,
    indoorClean: 0,
    outdoorClean: 0,
  });
});
test("invalid command and temperature never send; 5xx and timeouts never retry", async () => {
  const h = harness();
  await capabilities["climate.devices"](h.ctx);
  h.calls.length = 0;
  for (const settings of [{ targetTemperature: 33 }, { targetTemperature: 26, raw: "unsafe" }])
    await assert.rejects(
      capabilities["climate.command"](h.ctx, { deviceId: ID, command: "temperature", settings }),
    );
  assert.equal(h.calls.length, 0);
  const uncertain = harness({ commandStatus: 500 });
  await capabilities["climate.devices"](uncertain.ctx);
  uncertain.calls.length = 0;
  assert.deepEqual(
    await capabilities["climate.command"](uncertain.ctx, {
      deviceId: ID,
      command: "power",
      settings: { power: true },
    }),
    { status: "unknown" },
  );
  assert.equal(uncertain.calls.length, 1);
  let calls = 0;
  h.ctx.fetch = async () => {
    calls++;
    throw Error("synthetic timeout");
  };
  await assert.rejects(
    capabilities["climate.command"](h.ctx, { deviceId: ID, command: "power", settings: { power: true } }),
  );
  assert.equal(calls, 1);
});
