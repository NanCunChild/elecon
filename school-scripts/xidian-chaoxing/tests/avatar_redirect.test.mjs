import assert from "node:assert/strict";
import test from "node:test";
import { conversationImages } from "../src/avatars.js";

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const image = () => ({
  ok: true,
  status: 200,
  headers: { get: (name) => (name === "content-type" ? "image/png" : null) },
  arrayBuffer: async () => png,
});
const redirect = (url) => ({
  ok: false,
  status: 302,
  headers: { get: (name) => (name === "location" ? url : null) },
});

test("permitted image MIME is normalized to the actual PNG or JPEG bytes", async () => {
  const row = await load(async () => ({
    ...image(),
    headers: { get: (name) => (name === "content-type" ? "image/jpeg" : null) },
  }));
  assert.equal(row.avatarImages[0], `data:image/png;base64,${png.toString("base64")}`);
});

async function load(fetch) {
  const rows = new Map([["group:1", { conversationId: "1", conversationKind: "group", title: "Synthetic" }]]);
  await conversationImages(
    { fetch },
    rows,
    new Map([["1", ["2"]]]),
    new Map([["2", { pic120: "https://photo.chaoxing.com/a" }]]),
  );
  return rows.get("group:1");
}

test("one declared CDN redirect yields inline bytes without forwarding credentials", async () => {
  const calls = [];
  const row = await load(async (url, init) => {
    calls.push(url);
    assert.deepEqual(init, { redirect: "manual", headers: {} });
    return calls.length === 1 ? redirect("https://p.cldisk.com/a.png") : image();
  });
  assert.deepEqual(calls, ["https://photo.chaoxing.com/a", "https://p.cldisk.com/a.png"]);
  assert.equal(row.avatarImages[0], `data:image/png;base64,${png.toString("base64")}`);
});

test("foreign origins and redirect chains stop while CDN denial preserves metadata", async () => {
  for (const destination of ["https://foreign.invalid/a.png", "https://p.cldisk.com/a.png"]) {
    let calls = 0;
    const row = await load(async () => {
      calls++;
      return redirect(destination);
    });
    assert.equal(calls, destination.includes("foreign") ? 1 : 2);
    assert.equal(row.avatarImages, undefined);
    assert.equal(row.title, "Synthetic");
  }
  let calls = 0;
  const row = await load(async () =>
    ++calls === 1 ? redirect("https://p.cldisk.com/a.png") : { ok: false, status: 403 },
  );
  assert.equal(calls, 2);
  assert.equal(row.avatarImages, undefined);
});

test("a two-hop optional budget completes one image before another first hop starts", async () => {
  const rows = new Map(
    [1, 2].map((n) => [`group:${n}`, { conversationId: `${n}`, conversationKind: "group" }]),
  );
  const members = new Map([
    ["1", ["3"]],
    ["2", ["4"]],
  ]);
  const people = new Map([
    ["3", { pic: "https://photo.chaoxing.com/a" }],
    ["4", { pic: "https://photo.chaoxing.com/b" }],
  ]);
  let count = 0;
  await conversationImages(
    {
      fetch: async (url) => {
        if (++count > 2)
          throw Object.assign(new Error("optional_budget_exhausted"), { code: "optional_budget_exhausted" });
        return url.startsWith("https://photo.") ? redirect("https://p.cldisk.com/a.png") : image();
      },
    },
    rows,
    members,
    people,
  );
  assert.equal(rows.get("group:1").avatarImages.length, 1);
  assert.equal(rows.get("group:2").avatarImages, undefined);
});
