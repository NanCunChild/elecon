// Copyright 2026 elecon contributors. SPDX-License-Identifier: MIT
// Synthetic loopback data only. No school or account is contacted.
import assert from "node:assert/strict";
import { readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import test from "node:test";
import { findCaptureChrome, startBrowserHar, summarizeHar } from "./browser-har.mjs";

let chromeAvailable = true;
try {
  findCaptureChrome();
} catch {
  chromeAvailable = false;
}

test("full HAR keeps redirects, bodies, binary, popups, cross-origin frames and failed requests", {
  skip: !chromeAvailable,
  timeout: 30000,
}, async (t) => {
  const binary = Buffer.from([0, 1, 127, 128, 255]);
  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname === "/redirect") {
      response.writeHead(302, {
        Location: "/main",
        "Set-Cookie": "SYNTHETIC_COOKIE=value; HttpOnly; Path=/",
      });
    } else if (url.pathname === "/main") {
      response.setHeader("Content-Type", "text/html");
      response.end(
        `<iframe src="http://localhost:${server.address().port}/frame"></iframe><button onclick="window.open('/popup')">Popup</button>`,
      );
      return;
    } else if (url.pathname === "/json") {
      let body = "";
      request.on("data", (chunk) => {
        body += chunk;
      });
      request.on("end", () => {
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify({ received: JSON.parse(body), synthetic: true }));
      });
      return;
    } else if (url.pathname === "/binary") {
      response.setHeader("Content-Type", "application/octet-stream");
      response.end(binary);
      return;
    } else if (url.pathname === "/failure") {
      request.socket.destroy();
      return;
    } else {
      response.setHeader("Content-Type", "text/html");
      response.end("<p>synthetic content</p>");
      return;
    }
    response.end();
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  t.after(() => new Promise((r) => server.close(r)));
  const capture = await startBrowserHar({ headless: true });
  t.after(async () => {
    await capture.stop();
    rmSync(capture.directory, { recursive: true, force: true });
  });
  const page = capture.context.pages()[0];
  await page.goto(`http://127.0.0.1:${server.address().port}/redirect`);
  await page.frameLocator("iframe").locator("p").waitFor();
  await page.evaluate(async () => {
    await (
      await fetch("/json?query=synthetic", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer SYNTHETIC_TOKEN" },
        body: JSON.stringify({ classroom: "SYNTHETIC_ROOM" }),
      })
    ).json();
    await (await fetch("/binary")).arrayBuffer();
    await fetch("/failure").catch(() => {});
  });
  const popupPromise = capture.context.waitForEvent("page");
  await page.getByRole("button", { name: "Popup" }).click();
  const popup = await popupPromise;
  await popup.waitForLoadState();
  const firstStop = capture.stop();
  assert.equal(capture.stop(), firstStop);
  const result = await firstStop;
  assert.equal(result.state, "saved");
  assert.equal((await capture.done).state, "saved");
  assert.ok(result.failedRequests > 0);
  assert.equal(result.pages, 2);
  const har = JSON.parse(readFileSync(capture.harPath, "utf8"));
  const entries = har.log.entries;
  const at = (path) => entries.find((e) => new URL(e.request.url).pathname === path);
  assert.equal(at("/redirect").response.status, 302);
  assert.ok(at("/redirect").response.cookies.some((cookie) => cookie.name === "SYNTHETIC_COOKIE"));
  assert.equal(at("/json").request.method, "POST");
  assert.deepEqual(JSON.parse(at("/json").request.postData.text), { classroom: "SYNTHETIC_ROOM" });
  assert.ok(at("/json").request.headers.some((header) => header.value === "Bearer SYNTHETIC_TOKEN"));
  assert.equal(JSON.parse(at("/json").response.content.text).synthetic, true);
  assert.equal(at("/binary").response.content.encoding, "base64");
  assert.deepEqual(Buffer.from(at("/binary").response.content.text, "base64"), binary);
  assert.equal(new URL(at("/frame").request.url).hostname, "localhost");
  assert.ok(at("/popup").response.content.text.includes("synthetic content"));
  assert.ok(at("/failure").response._failureText);
  assert.ok(har.log.pages.length >= 2);
  for (const [path, mode] of [
    [capture.directory, 0o700],
    [capture.profile, 0o700],
    [capture.harPath, 0o600],
    [capture.metadataPath, 0o600],
  ]) {
    assert.equal(statSync(path).mode & 0o777, mode);
  }
  assert.equal(JSON.parse(readFileSync(capture.metadataPath, "utf8")).state, "saved");
  assert.deepEqual(summarizeHar(capture.harPath), result.summary);
  assert.equal(result.summary.entries, entries.length);
  assert.ok(result.summary.failed >= 1);
  assert.ok(result.summary.responseBodies >= 4);
});

test("external browser shutdown is marked interrupted rather than reported as a saved HAR", {
  skip: !chromeAvailable,
  timeout: 15000,
}, async (t) => {
  const capture = await startBrowserHar({ headless: true });
  t.after(() => rmSync(capture.directory, { recursive: true, force: true }));
  await capture.context.browser().close();
  assert.equal((await capture.done).state, "interrupted");
  assert.equal((await capture.stop()).state, "interrupted");
});
