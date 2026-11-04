// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Synthetic authentication and business I/O; no live account or school traffic.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const compiled = await build({
  entryPoints: [fileURLToPath(new URL("../src/index.js", import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "neutral",
  alias: {
    "elecon:html": fileURLToPath(new URL("../../../adapters/_stdlib/html.bundle.js", import.meta.url)),
  },
});
const directory = mkdtempSync(join(tmpdir(), "elecon-unified-fixture-"));
let createCapabilities;
try {
  const modulePath = join(directory, "school.mjs");
  writeFileSync(modulePath, compiled.outputFiles[0].text);
  ({ createCapabilities } = await import(modulePath));
} finally {
  rmSync(directory, { recursive: true, force: true });
}

// Exercise the production router with official-page SSO harvesting and native
// business requests. Password protocol fixtures remain separate in pda.test.
import { harness } from "./webview.fixture.mjs";

for (const role of ["undergraduate", "postgraduate"]) {
  test(`${role}: a private capability harvests WebView SSO, resumes and reuses the session`, async () => {
    const system = role === "postgraduate" ? "yjspt" : "ehall";
    const h = harness({ system });
    const caps = createCapabilities(role);
    const first = await caps["term.list"](h.ctx);
    assert.equal(first.currentTerm, "2026-2027-1");
    const logins = () => h.events.filter((e) => e[0] === "open").length;
    assert.equal(logins(), 1);
    await caps["term.list"](h.ctx);
    assert.equal(logins(), 1);
  });
}
test("expired business session triggers one auth attempt; persistent rejection never loops", async () => {
  const h = harness();
  h.records.set("ehall", JSON.stringify({ version: 1, service: "ehall", cookies: [], data: {} }));
  const nativeFetch = h.ctx.fetch;
  let expired = true;
  h.ctx.fetch = async (url, init) => {
    if (expired && url.includes("ehall.xidian.edu.cn")) {
      expired = false;
      return { url, status: 401, ok: false, headers: { get: () => null, getSetCookie: () => [] } };
    }
    return nativeFetch(url, init);
  };
  await createCapabilities("undergraduate")["term.list"](h.ctx);
  assert.equal(h.events.filter((e) => e[0] === "open").length, 1);
  const denied = harness();
  const delegate = denied.ctx.fetch;
  denied.ctx.fetch = async (url, init) =>
    denied.records.has("ehall") && url.includes("/dqxnxq.do")
      ? { url, status: 401, ok: false, headers: { get: () => null, getSetCookie: () => [] } }
      : delegate(url, init);
  await assert.rejects(
    createCapabilities("undergraduate")["term.list"](denied.ctx),
    /xidian_login_required_ehall/,
  );
  assert.equal(denied.events.filter((e) => e[0] === "open").length, 1);
});
test("cancelled official WebView cannot save or run business", async () => {
  const h = harness({ cancel: true });
  await assert.rejects(createCapabilities("undergraduate")["term.list"](h.ctx), /script_cancelled/);
  assert.equal(h.records.size, 0);
  assert.ok(!h.events.some((e) => e[0] === "request" && e[1].includes("ehall.xidian")));
});

test("a read-only query exchanges a rejected child ticket once using existing primary SSO", async () => {
  const h = harness();
  h.records.set(
    "ids",
    JSON.stringify({
      version: 1,
      service: "ids",
      data: { role: "undergraduate" },
      cookies: [
        {
          name: "CASTGC",
          value: "EXAMPLE_SYNTHETIC_GLOBAL",
          domain: "ids.xidian.edu.cn",
          hostOnly: true,
          path: "/authserver",
          isSecure: true,
        },
      ],
    }),
  );
  delete h.ctx.browser;
  const fetch = h.ctx.fetch;
  let expired = true;
  h.ctx.fetch = async (url, init) => {
    if (expired && url.includes("ehall.xidian.edu.cn")) {
      expired = false;
      return { url, status: 401, ok: false, headers: { get: () => null, getSetCookie: () => [] } };
    }
    return fetch(url, init);
  };
  const result = await createCapabilities("undergraduate")["term.list"](h.ctx);
  assert.equal(result.currentTerm, "2026-2027-1");
  assert.equal(
    h.events.filter(([type, url]) => type === "request" && url.startsWith("https://ids.")).length,
    1,
  );
  assert.ok(!h.events.some(([type]) => type === "open"));
});
