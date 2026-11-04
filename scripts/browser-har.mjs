#!/usr/bin/env node
// Copyright 2026 elecon contributors. SPDX-License-Identifier: MIT
// Local development capture only. Raw HAR/profile data must never be committed.
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

/** Counts only: no URLs, header values or response data are printed. */
export function summarizeHar(harPath) {
  const har = JSON.parse(readFileSync(harPath, "utf8"));
  if (!Array.isArray(har.log?.entries)) throw new Error("invalid_har");
  const entries = har.log.entries;
  return {
    entries: entries.length,
    pages: har.log.pages?.length ?? 0,
    requestBodies: entries.filter((entry) => entry.request?.postData != null).length,
    responseBodies: entries.filter((entry) => typeof entry.response?.content?.text === "string").length,
    missingResponseBodies: entries.filter((entry) => typeof entry.response?.content?.text !== "string")
      .length,
    failed: entries.filter((entry) => entry.response?.status === 0 || entry.response?._failureText).length,
    redirects: entries.filter((entry) => [301, 302, 303, 307, 308].includes(entry.response?.status)).length,
  };
}

export function findCaptureChrome() {
  const candidates = process.env.CHROME_BIN
    ? [process.env.CHROME_BIN]
    : ["/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/opt/google/chrome/chrome"];
  const executable = candidates.find((path) => existsSync(path));
  if (!executable) throw new Error("chrome_not_found");
  return executable;
}

export async function startBrowserHar({ headless = false, executablePath = findCaptureChrome() } = {}) {
  const repository = realpathSync(fileURLToPath(new URL("..", import.meta.url)));
  const temporaryRoot = realpathSync(tmpdir());
  const within = relative(repository, temporaryRoot);
  const outside = within === ".." || within.startsWith(`..${sep}`) || isAbsolute(within);
  if (!outside) {
    throw new Error("capture_temp_directory_inside_repository");
  }
  const directory = mkdtempSync(join(temporaryRoot, "elecon-browser-har-"));
  chmodSync(directory, 0o700);
  const profile = join(directory, "profile");
  mkdirSync(profile, { mode: 0o700 });
  const harPath = join(directory, "session.har");
  const metadataPath = join(directory, "capture.json");
  // Protect the final destination before Playwright writes the artifact.
  writeFileSync(harPath, "", { mode: 0o600, flag: "wx" });
  const metadata = {
    format: 1,
    startedAt: new Date().toISOString(),
    state: "starting",
    harMode: "full",
    content: "embed",
    requests: 0,
    finishedRequests: 0,
    failedRequests: 0,
    pages: 0,
  };
  const saveMetadata = () =>
    writeFileSync(metadataPath, JSON.stringify(metadata, null, 2) + "\n", { mode: 0o600 });
  saveMetadata();
  let context;
  try {
    context = await chromium.launchPersistentContext(profile, {
      executablePath,
      headless,
      chromiumSandbox: true,
      viewport: null,
      handleSIGINT: false,
      handleSIGTERM: false,
      handleSIGHUP: false,
      timeout: 30000,
      serviceWorkers: "allow",
      recordHar: { path: harPath, mode: "full", content: "embed" },
    });
  } catch {
    metadata.state = "launch_failed";
    saveMetadata();
    throw new Error(`browser_har_launch_failed: ${directory}`);
  }
  metadata.state = "recording";
  metadata.pages = context.pages().length;
  metadata.browser = context.browser()?.version();
  saveMetadata();
  context.on("page", () => metadata.pages++);
  context.on("request", () => metadata.requests++);
  context.on("requestfinished", () => metadata.finishedRequests++);
  context.on("requestfailed", () => metadata.failedRequests++);
  let stopping = false;
  let finished = false;
  let stopPromise;
  let resolveDone;
  const done = new Promise((r) => {
    resolveDone = r;
  });
  const finish = (state) => {
    if (finished) return metadata;
    finished = true;
    metadata.state = state;
    metadata.stoppedAt = new Date().toISOString();
    metadata.pendingRequests = Math.max(
      0,
      metadata.requests - metadata.finishedRequests - metadata.failedRequests,
    );
    try {
      metadata.harBytes = existsSync(harPath) ? statSync(harPath).size : 0;
      if (metadata.harBytes) chmodSync(harPath, 0o600);
      if (state === "saved" && !metadata.harBytes) metadata.state = "save_failed";
      if (metadata.state === "saved") {
        metadata.summary = summarizeHar(harPath);
      }
      saveMetadata();
    } catch {
      metadata.state = "save_failed";
    }
    resolveDone(metadata);
    return metadata;
  };
  context.on("close", () => {
    // User closing Chrome or a crash bypasses the explicit HAR flush path.
    if (!stopping) finish("interrupted");
  });
  const stop = () => {
    if (stopPromise) return stopPromise;
    if (finished) return Promise.resolve(metadata);
    stopping = true;
    stopPromise = (async () => {
      try {
        await context.close();
        return finish("saved");
      } catch {
        return finish("save_failed");
      }
    })();
    return stopPromise;
  };
  return { directory, profile, harPath, metadataPath, context, done, stop };
}

async function main() {
  if (process.argv[2] === "--summary" && process.argv.length === 4) {
    console.log(JSON.stringify(summarizeHar(process.argv[3]), null, 2));
    return;
  }
  if (process.argv.length > 2) {
    console.log(
      "Usage: npm run capture:browser [-- --summary /path/to/session.har] (capture: Node 20+, Chrome, graphical desktop; CHROME_BIN optional)",
    );
    process.exitCode = process.argv[2] === "--help" ? 0 : 1;
    return;
  }
  const capture = await startBrowserHar();
  console.log(
    `browser_har_ready\nHAR: ${capture.harPath}\nmetadata: ${capture.metadataPath}\nprofile: ${capture.profile}`,
  );
  console.log(
    "在新 Chrome 中手动浏览。录制所有域名的会话 HTTP 请求和正文；HAR/profile 含原始凭据与个人数据，仅保存在本机。完成后回到此终端按回车或 Ctrl+C，等待 browser_har_saved 再退出；不要直接关闭浏览器。",
  );
  const input = createInterface({ input: process.stdin });
  const stop = () => {
    void capture.stop();
  };
  input.once("line", stop);
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, stop);
  const result = await capture.done;
  input.close();
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.removeListener(signal, stop);
  if (result.state === "saved") {
    console.log(
      `browser_har_saved: ${capture.harPath}\nrequests: ${result.requests}; failed: ${result.failedRequests}; pending at stop: ${result.pendingRequests}`,
    );
    console.log(JSON.stringify(result.summary, null, 2));
  } else {
    console.error(`browser_har_${result.state}: ${capture.directory}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    // Never print browser error details, which may contain page data or URLs.
    console.error(
      error.message.startsWith("browser_har_launch_failed:")
        ? error.message
        : "browser_har_failed: check Chrome, graphical desktop and writable temporary directory",
    );
    process.exitCode = 1;
  });
}
