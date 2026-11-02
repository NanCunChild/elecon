import assert from "node:assert/strict";
import { createCipheriv, createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { ACCOUNT_URL, messagesSession } from "../src/account.js";
import { attendanceCheckin, parseCheckinQr } from "../src/checkin.js";
import { clientIdentity } from "../src/client_identity.js";
import { incoming, loginPacket, messagesList } from "../src/messages.js";
import { decode, encode, one, str, sub } from "../src/protobuf.js";

const QR =
  "https://mobilelearn.chaoxing.com/widget/sign/e?id=12345678901234567890&enc=0123456789ABCDEF0123456789ABCDEF";
const flags = { ifopenAddress: 0, openCheckFaceFlag: 0, ifNeedVcode: 0 };
const ajv = new Ajv2020({ strict: true, addUsedSchema: false });
addFormats(ajv);
const validate = (cap, data) =>
  assert.equal(
    ajv.compile(
      JSON.parse(readFileSync(new URL(`../../../contract/schema/${cap}.schema.json`, import.meta.url))),
    )(data),
    true,
  );
function harness({
  challenge = {},
  latestChallenge = challenge,
  postFailure = false,
  finalStatus = 1,
  finalReadFailure = false,
  cancel = false,
  scan = QR,
  responseText = "success",
  elapsedBeforeSubmit = 0,
  preflightFailure = false,
} = {}) {
  let now = 1800000000000;
  let submitted = false;
  const calls = [];
  const logs = [];
  const saved = {
    version: 1,
    serviceId: "chaoxing",
    accountId: "123456",
    accountLabel: "Synthetic",
    cookies: [{ name: "SESSION", value: "SYNTHETIC", domain: "chaoxing.com", path: "/", isSecure: true }],
  };
  const records = new Map([
    ["chaoxing", JSON.stringify(saved)],
    ["other", "OTHER"],
  ]);
  const ctx = {
    log: (level, message) => logs.push([level, message]),
    now: () => now++,
    credentials: {
      get: async (k) => (records.has(k) ? { value: records.get(k) } : null),
      set: async (k, v) => records.set(k, v),
      delete: async (k) => records.delete(k),
    },
    ui: { scanQRCode: async () => (cancel ? null : { text: scan, format: "qrCode" }) },
    fetch: async (url, init) => {
      calls.push([url, init]);
      const path = new URL(url).pathname;
      let data;
      if (url === ACCOUNT_URL)
        data = {
          msg: { puid: 123456, uid: 456789, fid: 789012, name: "Synthetic", hxToken: "SYNTHETIC_TOKEN" },
        };
      else if (path.endsWith("getAttendInfo")) {
        if (submitted && finalReadFailure) throw new Error("SYNTHETIC_STATUS_FAILURE");
        data = { data: { status: submitted ? finalStatus : 0 } };
      } else if (path.endsWith("getPPTActiveInfo"))
        data = {
          data: {
            status: 1,
            isdelete: 0,
            otherId: 2,
            clazzid: 567890,
            content: JSON.stringify({ ...flags, ...challenge }),
          },
        };
      else if (path.endsWith("getClassDetail")) {
        if (preflightFailure) throw new Error("SYNTHETIC_PREPARATION_FAILURE");
        data = { data: { courseid: 987654 } };
      } else if (path.endsWith("/analysis")) data = "0123456789abcdef0123456789abcdef";
      else if (path.endsWith("/analysis2")) data = "success";
      else if (path.endsWith("/preSign")) data = "<html>sign form</html>";
      else if (path.endsWith("/getActive")) {
        now += elapsedBeforeSubmit;
        data = { classId: 567890, courseId: 2, content: { ...flags, ...latestChallenge } };
      } else if (path.endsWith("/stuSignajax")) {
        submitted = true;
        if (postFailure) throw new Error("SYNTHETIC_TIMEOUT");
        data = responseText;
      } else throw new Error("unexpected endpoint");
      return {
        ok: true,
        status: 200,
        url,
        headers: { get: () => null, getSetCookie: () => [] },
        text: async () => (typeof data === "string" ? data : JSON.stringify(data)),
      };
    },
  };
  return { ctx, calls, records, logs };
}
const provision = (code = 0) =>
  encode([
    [8, 3],
    [9, encode([[8, encode([[1, code]])]])],
  ]);
const queue = encode([
  [2, "synthetic-group"],
  [3, "easemob.com"],
]);
function batch({ privateMessage = false } = {}) {
  const fields = [9007199254740993n, 9007199254740995n].map((id) => {
    const body = encode([
      [1, privateMessage ? 1 : 2],
      [2, encode([[2, "synthetic-sender"]])],
      [
        4,
        encode([
          [1, 1],
          [2, "Synthetic message " + id],
        ]),
      ],
    ]);
    return [
      4,
      encode([
        [1, id],
        [3, queue],
        [4, 1800000000000n],
        [6, body],
      ]),
    ];
  });
  return encode([
    [8, 0],
    [9, encode(fields)],
  ]);
}
test("QR validation preserves large IDs and rejects origin/path/duplicate/encoding tricks", () => {
  assert.equal(parseCheckinQr(QR).id, "12345678901234567890");
  for (const qr of [
    QR.replace("mobilelearn.chaoxing.com", "evil.invalid"),
    QR.replace("/widget/sign/e", "/other"),
    QR + "&id=12",
    QR + "&%69d=12",
    QR.replace("enc=", "enc=%"),
    QR + "#fragment",
    QR.replace("https://", "https://user@"),
    QR + "&STRATEGY_PARA=id&STRATEGY_PARA=id",
    QR + "&STRATEGY_PARA=id&%53TRATEGY_PARA=id",
    QR + "&redirect=https%3A%2F%2Fevil.invalid",
  ])
    assert.throws(() => parseCheckinQr(qr));
});
test("current primary-key QR routing hints are accepted without forwarding them", async () => {
  const scan = QR + "&c=123456&DB_STRATEGY=PRIMARY_KEY&STRATEGY_PARA=id";
  assert.deepEqual(parseCheckinQr(scan), parseCheckinQr(QR));
  const h = harness({ scan });
  assert.equal((await attendanceCheckin(h.ctx)).status, "confirmed");
  assert.equal(h.calls.filter(([, init]) => init.method === "POST").length, 1);
  for (const [url, init] of h.calls) {
    assert.equal(new URL(url).searchParams.has("STRATEGY_PARA"), false);
    assert.ok(!String(init.body).includes("STRATEGY_PARA"));
  }
});
test("supported QR sends exactly once and confirms through independent status", async () => {
  const h = harness();
  const result = await attendanceCheckin(h.ctx);
  validate("attendance.checkin", result);
  assert.equal(result.status, "confirmed");
  const posts = h.calls.filter(([, i]) => i.method === "POST");
  assert.equal(posts.length, 1);
  assert.ok(!posts[0][1].body.includes("locationResult"));
  assert.equal(posts[0][1].headers["X-Requested-With"], "XMLHttpRequest");
  assert.equal(posts[0][1].headers.Referer, h.calls.find(([u]) => u.includes("/preSign"))[0]);
});
test("lost POST response may be confirmed, never resubmitted", async () => {
  const h = harness({ postFailure: true });
  assert.equal((await attendanceCheckin(h.ctx)).status, "confirmed");
  assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 1);
});
test("uncertain delivery remains unknown", async () => {
  const h = harness({ postFailure: true, finalStatus: 0 });
  assert.equal((await attendanceCheckin(h.ctx)).status, "unknown");
  assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 1);
});
const probeRecords = (h) =>
  h.logs.map(([, message]) => message).filter((message) => message.startsWith("probe/1 "));
test("probe identifies preparation failure and only emits bounded anonymous fields", async () => {
  const h = harness({ preflightFailure: true });
  assert.equal((await attendanceCheckin(h.ctx)).reason, "request_failed");
  assert.ok(probeRecords(h).some((line) => line.includes("stage=7 event=failed")));
  assert.ok(!probeRecords(h).some((line) => line.includes("stage=13 ")));
  for (const line of probeRecords(h))
    assert.match(
      line,
      /^probe\/1 stage=([1-9]|[12][0-9]|3[0-2]) event=(begin|ok|failed|unknown|skipped) http=(0|[1-5][0-9]{2}) ms=([0-9]{1,5}|1[01][0-9]{4}|120000) flags=[01?]{8}$/,
    );
  const logs = JSON.stringify(h.logs);
  for (const secret of [
    QR,
    "12345678901234567890",
    "0123456789ABCDEF",
    "SYNTHETIC",
    "SYNTHETIC_PREPARATION_FAILURE",
    "123456",
    "456789",
    "789012",
    "567890",
    "987654",
  ])
    assert.ok(!logs.includes(secret), secret);
});
test("probe captures authentication HTTP failure before scanning without raw error details", async () => {
  const h = harness();
  h.ctx.fetch = async () => ({
    ok: false,
    status: 401,
    headers: { getSetCookie: () => [] },
    text: async () => "SYNTHETIC_SECRET_TOKEN",
  });
  h.ctx.ui.scanQRCode = async () => assert.fail("must not scan without a verified account");
  await assert.rejects(attendanceCheckin(h.ctx), { code: "source_response_invalid" });
  assert.ok(probeRecords(h).some((line) => line.includes("stage=2 event=failed http=401")));
  assert.ok(!JSON.stringify(h.logs).includes("SYNTHETIC_SECRET_TOKEN"));
});
test("probe reports QR validation and scan cancellation without recording QR", async () => {
  const invalid = harness({ scan: QR + "&secret=SYNTHETIC_SECRET_TOKEN" });
  await assert.rejects(attendanceCheckin(invalid.ctx), { code: "input_invalid_request" });
  assert.ok(probeRecords(invalid).some((line) => line.includes("stage=4 event=failed")));
  assert.ok(!JSON.stringify(invalid.logs).includes("SYNTHETIC_SECRET_TOKEN"));
  const cancelled = harness({ cancel: true });
  await attendanceCheckin(cancelled.ctx);
  assert.ok(probeRecords(cancelled).some((line) => line.includes("stage=3 event=skipped")));
});
test("probe preserves uncertain delivery and classifies bodies without exposing secrets", async () => {
  const h = harness({ finalStatus: 0, responseText: "SYNTHETIC_SECRET_TOKEN" });
  assert.equal((await attendanceCheckin(h.ctx)).status, "unknown");
  assert.ok(probeRecords(h).some((line) => line.includes("stage=13 event=unknown")));
  assert.ok(probeRecords(h).at(-1).includes("stage=14 event=unknown"));
  assert.ok(!JSON.stringify(h.logs).includes("SYNTHETIC_SECRET_TOKEN"));
  assert.equal(h.calls.filter(([, init]) => init.method === "POST").length, 1);
  assert.ok(h.logs.length < 100);
});
test("timeout probes preserve submission uncertainty and final verification stage", async () => {
  for (const options of [
    { postFailure: true, finalStatus: 0 },
    { finalReadFailure: true },
    { postFailure: true, finalReadFailure: true },
  ]) {
    const h = harness(options);
    assert.equal((await attendanceCheckin(h.ctx)).status, "unknown");
    const records = probeRecords(h);
    assert.ok(records.some((line) => line.includes("stage=13 event=begin")));
    assert.ok(records.some((line) => line.includes("stage=14 event=begin")));
    assert.match(records.at(-1), /stage=14 event=unknown .* flags=[01?]{5}1[0?][01?]$/);
    assert.equal(h.calls.filter(([, init]) => init.method === "POST").length, 1);
  }
});
test("redirect-heavy preflight leaves room for verification within host log budget", async () => {
  const h = harness();
  const fetch = h.ctx.fetch;
  const counts = new Map();
  const redirectPaths = ["getUserImToken", "getPPTActiveInfo", "getClassDetail", "/analysis"];
  let requests = 0;
  h.ctx.fetch = async (url, init) => {
    requests++;
    const path = new URL(url).pathname;
    const count = counts.get(path) ?? 0;
    counts.set(path, count + 1);
    if (redirectPaths.some((p) => path.endsWith(p)) && count < 7)
      return { status: 302, headers: { get: () => url, getSetCookie: () => [] } };
    return fetch(url, init);
  };
  assert.equal((await attendanceCheckin(h.ctx)).status, "confirmed");
  assert.ok(requests <= 40);
  assert.ok(h.logs.length < 100);
  assert.match(probeRecords(h).at(-1), /stage=14 event=ok/);
});
test("broken diagnostic sink cannot affect delivery or independent confirmation", async () => {
  const h = harness({ postFailure: true });
  h.ctx.log = () => {
    throw new Error("log budget exhausted");
  };
  assert.equal((await attendanceCheckin(h.ctx)).status, "confirmed");
  assert.equal(h.calls.filter(([, init]) => init.method === "POST").length, 1);
});
const location = {
  latitude: 12.3456,
  longitude: 45.6789,
  address: "Synthetic classroom",
  coordinateSystem: "service",
};
test("explicit location supports ranged QR with one submit and independent confirmation", async () => {
  const h = harness({ challenge: { ifopenAddress: 1 } });
  const result = await attendanceCheckin(h.ctx, { location });
  validate("attendance.checkin", result);
  assert.equal(result.status, "confirmed");
  const posts = h.calls.filter(([, i]) => i.method === "POST");
  assert.equal(posts.length, 1);
  const body = new URLSearchParams(posts[0][1].body);
  assert.equal(body.get("latitude"), "12.3456");
  assert.equal(body.get("longitude"), "45.6789");
  assert.equal(body.get("address"), location.address);
  assert.equal(body.get("ifTiJiao"), "1");
  assert.deepEqual(JSON.parse(body.get("location")), {
    latitude: "12.3456",
    longitude: "45.6789",
    address: location.address,
    result: "1",
  });
  assert.equal(body.get("locationResult"), body.get("location"));
  const logs = JSON.stringify(h.logs);
  for (const secret of [location.address, String(location.latitude), String(location.longitude)])
    assert.ok(!logs.includes(secret));
  assert.match(probeRecords(h).at(-1), /flags=10001111$/);
  assert.ok(!body.toString().includes("mockData"));
});
test("unranged QR uses only the user selected position and does not invent one", async () => {
  const h = harness();
  await attendanceCheckin(h.ctx, { location });
  const body = new URLSearchParams(h.calls.find(([, i]) => i.method === "POST")[1].body);
  assert.equal(body.get("latitude"), String(location.latitude));
  assert.equal(body.has("location"), false);
  assert.equal(body.get("ifTiJiao"), "0");
});
test("a newly required location prevents submission until a place is selected", async () => {
  const h = harness({ latestChallenge: { ifopenAddress: 1 } });
  assert.equal((await attendanceCheckin(h.ctx)).reason, "location_required");
  assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 0);
});
test("selected coordinates cannot override facial, photo, validation or unknown requirements", async () => {
  for (const [challenge, reason] of [
    [{ openCheckFaceFlag: 1 }, "face_required"],
    [{ ifNeedVcode: 1 }, "verification_required"],
    [{ ifphoto: 1 }, "photo_required"],
    [{ ifNeedVcode: undefined }, "requirements_unknown"],
  ]) {
    const h = harness({ latestChallenge: challenge });
    assert.equal((await attendanceCheckin(h.ctx, { location })).reason, reason);
    assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 0);
  }
});
test("bad coordinates and unrecognized input fail before authentication or scanning", async () => {
  for (const invalid of [
    null,
    {},
    { ...location, latitude: NaN },
    { ...location, longitude: Infinity },
    { ...location, latitude: 91 },
    { ...location, longitude: -181 },
    { ...location, address: "  " },
    { ...location, coordinateSystem: "guessed" },
    { ...location, mockData: 0 },
  ]) {
    const h = harness();
    await assert.rejects(attendanceCheckin(h.ctx, { location: invalid }), { code: "input_invalid_request" });
    assert.equal(h.calls.length, 0);
  }
});
test("expired QR and preparation failure cannot send a check-in", async () => {
  for (const [options, reason] of [
    [{ elapsedBeforeSubmit: 31000 }, "qr_expired"],
    [{ preflightFailure: true }, "request_failed"],
  ]) {
    const h = harness(options);
    assert.equal((await attendanceCheckin(h.ctx)).reason, reason);
    assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 0);
  }
});
test("known remote rejection is explained but no final submission is retried", async () => {
  for (const [responseText, reason] of [
    ["validate_TOKEN", "verification_required"],
    ["不在定位范围", "location_rejected"],
    ["二维码已过期", "qr_expired"],
    ["签到失败", "submission_rejected"],
  ]) {
    const h = harness({ finalStatus: 0, responseText });
    assert.equal((await attendanceCheckin(h.ctx)).reason, reason);
    assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 1);
  }
  const h = harness({ finalReadFailure: true });
  assert.equal((await attendanceCheckin(h.ctx)).status, "unknown");
  assert.equal(h.calls.filter(([, i]) => i.method === "POST").length, 1);
});
test("check-in input 1.0 remains empty and 1.1 validates explicit service coordinates", () => {
  const old = ajv.compile(
    JSON.parse(
      readFileSync(
        new URL(
          "../../../contract/schema-versions/params.attendance.checkin/1.0.schema.json",
          import.meta.url,
        ),
      ),
    ),
  );
  assert.equal(old({}), true);
  assert.equal(old({ location }), false);
  const current = ajv.compile(
    JSON.parse(
      readFileSync(
        new URL("../../../contract/schema/params.attendance.checkin.schema.json", import.meta.url),
      ),
    ),
  );
  assert.equal(current({}), true);
  assert.equal(current({ location }), true);
  for (const value of [
    { qr: QR },
    { location: { ...location, latitude: 91 } },
    { location: { ...location, address: " " } },
    { location: { ...location, coordinateSystem: "guessed" } },
  ]) {
    assert.equal(current(value), false);
  }
});
for (const key of ["ifopenAddress", "openCheckFaceFlag", "ifNeedVcode", "ifphoto"])
  test(`challenge ${key} prevents presign and submit`, async () => {
    const h = harness({ challenge: { [key]: 1 } });
    assert.equal((await attendanceCheckin(h.ctx)).status, "unsupported");
    assert.ok(!h.calls.some(([u, i]) => u.includes("preSign") || i.method === "POST"));
  });
test("scan cancel sends no attendance requests and parameters cannot inject QR", async () => {
  const h = harness({ cancel: true });
  assert.deepEqual(await attendanceCheckin(h.ctx), { status: "cancelled" });
  assert.equal(h.calls.length, 1);
  await assert.rejects(attendanceCheckin(h.ctx, { qr: QR }));
});
test("logout removes only the platform account", async () => {
  const h = harness();
  assert.equal((await messagesSession(h.ctx)).status, "authenticated");
  validate("messages.session", await messagesSession(h.ctx, { operation: "logout" }));
  assert.equal(h.records.get("other"), "OTHER");
  await assert.rejects(messagesList(h.ctx), { code: "authentication_required" });
});
test("login survives an asynchronous redirect and verifies the service account", async () => {
  const h = harness();
  let navigating = true;
  const finished = setTimeout(() => {
    navigating = false;
  }, 50);
  h.ctx.browser = {
    setCookies: async (_, cookies) => assert.deepEqual(cookies, []),
    open: async () => {},
    evaluate: async () => {
      if (navigating) throw new Error("browser_not_loaded");
      return true;
    },
    cookies: async () => [{ name: "SESSION", value: "SYNTHETIC", path: "/", isSecure: true }],
  };
  try {
    assert.equal((await messagesSession(h.ctx, { operation: "login" })).status, "authenticated");
    assert.ok(h.calls.some(([url]) => url === ACCOUNT_URL));
    assert.equal(h.records.get("other"), "OTHER");
  } finally {
    clearTimeout(finished);
  }
});
test("cancelled login preserves the previous platform and unrelated account", async () => {
  const h = harness();
  const before = [...h.records];
  h.ctx.browser = {
    setCookies: async () => {},
    open: async () => {},
    evaluate: async () => {
      throw new Error("browser_closed");
    },
  };
  await assert.rejects(messagesSession(h.ctx, { operation: "login" }), /browser_closed/);
  assert.deepEqual([...h.records], before);
  assert.equal(h.calls.length, 0);
});
test("protobuf codec keeps uint64 exact, processes all metadata, skips private ACK", () => {
  const result = incoming(batch());
  assert.deepEqual(
    result.items.map((i) => i.id),
    ["9007199254740993", "9007199254740995"],
  );
  assert.equal(result.replies.length, 2);
  assert.equal(one(sub(decode(result.replies[0]), 9), 2), 9007199254740993n);
  assert.equal(incoming(batch({ privateMessage: true })).replies.length, 0);
  assert.throws(() => incoming(provision(401)), { code: "authentication_required" });
  assert.throws(() => decode(Uint8Array.from([10, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255])));
});
test("messages use finite authenticated window, no private data cached, socket closes", async () => {
  const h = harness();
  const events = [provision(), batch(), null];
  const sent = [];
  let closed = 0;
  h.ctx.websocket = {
    open: async () => {},
    send: async (b) => sent.push(b),
    receive: async () => events.shift(),
    close: async () => closed++,
  };
  const result = await messagesList(h.ctx);
  validate("messages.list", result);
  assert.equal(result.items.length, 2);
  assert.equal(result.coverage, "window");
  assert.equal(closed, 1);
  assert.equal(sent.length, 3);
  assert.equal(str(decode(sent[0]), 3), "$t$SYNTHETIC_TOKEN");
  assert.ok(!h.records.get("chaoxing").includes("SYNTHETIC_TOKEN"));
  assert.ok(!h.records.get("chaoxing").includes("Synthetic message"));
});
test("failed login or messages before provision are errors, never a fake empty inbox", async () => {
  for (const bytes of [provision(403), batch()]) {
    const h = harness();
    let closed = false;
    h.ctx.websocket = {
      open: async () => {},
      send: async () => {},
      receive: async () => bytes,
      close: async () => {
        closed = true;
      },
    };
    await assert.rejects(messagesList(h.ctx));
    assert.equal(closed, true);
  }
});
test("login packet binds token and platform tid, not school credentials", () => {
  const packet = decode(loginPacket({ tid: "123456", token: "SYNTHETIC" }, 42));
  assert.equal(str(sub(packet, 2), 2), "123456");
  assert.equal(str(packet, 3), "$t$SYNTHETIC");
});

test("protocol client identifier matches independent AES-ECB/PKCS7 vector", () => {
  const id = "123456";
  const digest = createHash("md5").update(id).digest("hex");
  const cipher = createCipheriv("aes-128-ecb", Buffer.from("QrCbNY@MuK1X8HGw"), null);
  const expected = Buffer.concat([cipher.update(digest), cipher.final()]).toString("base64");
  assert.deepEqual(clientIdentity(id), { clientId: digest, deviceCode: expected });
});
