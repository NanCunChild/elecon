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
const ajv = new Ajv2020({ strict: true });
addFormats(ajv);
const validate = (cap, data) =>
  assert.equal(
    ajv.compile(
      JSON.parse(readFileSync(new URL(`../../../contract/schema/${cap}.schema.json`, import.meta.url))),
    )(data),
    true,
  );
function harness({ challenge = {}, postFailure = false, finalStatus = 1, cancel = false, scan = QR } = {}) {
  let now = 1800000000000;
  let submitted = false;
  const calls = [];
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
      else if (path.endsWith("getAttendInfo")) data = { data: { status: submitted ? finalStatus : 0 } };
      else if (path.endsWith("getPPTActiveInfo"))
        data = {
          data: {
            status: 1,
            isdelete: 0,
            otherId: 2,
            clazzid: 567890,
            content: JSON.stringify({ ...flags, ...challenge }),
          },
        };
      else if (path.endsWith("getClassDetail")) data = { data: { courseid: 987654 } };
      else if (path.endsWith("/analysis")) data = "0123456789abcdef0123456789abcdef";
      else if (path.endsWith("/analysis2")) data = "success";
      else if (path.endsWith("/preSign")) data = "<html>sign form</html>";
      else if (path.endsWith("/getActive"))
        data = { classId: 567890, courseId: 2, content: { ...flags, ...challenge } };
      else if (path.endsWith("/stuSignajax")) {
        submitted = true;
        if (postFailure) throw new Error("SYNTHETIC_TIMEOUT");
        data = "success";
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
  return { ctx, calls, records };
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
  ])
    assert.throws(() => parseCheckinQr(qr));
});
test("supported QR sends exactly once and confirms through independent status", async () => {
  const h = harness();
  const result = await attendanceCheckin(h.ctx);
  validate("attendance.checkin", result);
  assert.equal(result.status, "confirmed");
  const posts = h.calls.filter(([, i]) => i.method === "POST");
  assert.equal(posts.length, 1);
  assert.ok(!posts[0][1].body.includes("locationResult"));
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
