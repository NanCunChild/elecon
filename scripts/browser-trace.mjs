#!/usr/bin/env node
// Copyright 2026 elecon contributors. SPDX-License-Identifier: MIT
// 🔒 Local diagnostic only (ADR-034 §3/§5, red lines #3/#8). Raw credentials
// stay in the isolated Chrome profile; logs contain metadata and keyed IDs.
import { spawn } from "node:child_process";
import { createHmac, randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

export function safePath(path) {
  return path
    .replace(/;[^/]*/g, ";[redacted]")
    .split("/")
    .map((part) =>
      /^(ST|TGT|PGT|PT)-|[0-9]{5,}|[a-zA-Z0-9_-]{24,}|%[0-9a-f]{2}|[^\x20-\x7e]/i.test(part)
        ? "[redacted]"
        : part,
    )
    .join("/");
}

/** No userinfo, query values, fragments or matrix session IDs enter the log. */
export function safeUrl(value, base, depth = 0) {
  try {
    const relative = !base && /^\/(?!\/)/.test(value);
    const url = new URL(value, relative ? "https://relative.invalid" : base);
    if (!["http:", "https:"].includes(url.protocol)) return { scheme: url.protocol };
    const result = {
      ...(relative ? { relative: true } : { origin: url.origin }),
      path: safePath(url.pathname),
      queryKeys: [...new Set(url.searchParams.keys())].map((key) => safePath(key).slice(0, 80)),
      hasFragment: !!url.hash,
    };
    if (depth < 3) {
      for (const key of ["service", "redirect_uri", "refer", "target"]) {
        const nested = url.searchParams.get(key);
        if (nested && /^https?:\/\//i.test(nested)) {
          result[key] = safeUrl(nested, undefined, depth + 1);
        }
      }
    }
    return result;
  } catch {
    return { invalid: true };
  }
}

export class TraceRedactor {
  #key = randomBytes(32);
  id(value) {
    return createHmac("sha256", this.#key)
      .update(String(value ?? ""))
      .digest("hex")
      .slice(0, 20);
  }
  url(value, base, depth = 0) {
    const result = safeUrl(value, base, depth);
    if (result.invalid || result.scheme) return result;
    const url = new URL(value, base ?? "https://relative.invalid");
    result.pathId = this.id(url.pathname);
    result.query = [...url.searchParams].map(([key, v]) => ({ key: safePath(key), valueId: this.id(v) }));
    if (depth < 3) {
      for (const key of ["service", "redirect_uri", "refer", "target"]) {
        if (result[key]) result[key] = this.url(url.searchParams.get(key), undefined, depth + 1);
      }
    }
    return result;
  }
  cookie(cookie) {
    return {
      name: safePath(String(cookie.name)).slice(0, 100),
      valueId: this.id(cookie.value),
      domain: cookie.domain,
      path: safePath(cookie.path ?? "/"),
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
      sameSite: cookie.sameSite,
      expires: cookie.expires,
      session: cookie.session,
      partitioned: cookie.partitionKey != null,
      sourceScheme: cookie.sourceScheme,
      sourcePort: cookie.sourcePort,
    };
  }
  cookieHeader(value) {
    return String(value ?? "")
      .split(";")
      .flatMap((part) => {
        const at = part.indexOf("=");
        return at < 1
          ? []
          : [{ name: safePath(part.slice(0, at).trim()), valueId: this.id(part.slice(at + 1).trim()) }];
      });
  }
  setCookie(line) {
    const [pair, ...attributes] = String(line).split(";");
    const at = pair.indexOf("=");
    if (at < 1) return { invalid: true };
    const result = { name: safePath(pair.slice(0, at).trim()), valueId: this.id(pair.slice(at + 1).trim()) };
    for (const attribute of attributes) {
      const [name, ...rest] = attribute.trim().split("=");
      const value = rest.join("=").trim();
      switch (name.toLowerCase()) {
        case "domain":
          result.domain = /^[.a-z0-9-]+$/i.test(value) ? value : "[redacted]";
          break;
        case "path":
          result.path = safePath(value);
          break;
        case "secure":
        case "httponly":
        case "partitioned":
          result[name.toLowerCase() === "httponly" ? "httpOnly" : name.toLowerCase()] = true;
          break;
        case "samesite":
          result.sameSite = /^(lax|strict|none)$/i.test(value) ? value : "[redacted]";
          break;
        case "max-age":
          result.deleted = /^-?\d+$/.test(value) && Number(value) <= 0;
          break;
        case "expires":
          if (Number.isFinite(Date.parse(value))) result.expires = new Date(value).toISOString();
          break;
      }
    }
    return result;
  }
  headers(headers = {}, base) {
    const result = {};
    for (const [rawName, value] of Object.entries(headers)) {
      const name = rawName.toLowerCase();
      if (name === "location" || name === "referer" || name === "origin")
        result[name] = this.url(value, base);
      if (name === "cookie") result.cookies = this.cookieHeader(value);
      if (name === "set-cookie")
        result.setCookies = String(value)
          .split("\n")
          .map((s) => this.setCookie(s));
      if (name === "content-type") result.contentType = String(value).split(";")[0].slice(0, 80);
      if (name === "x-requested-with") result.xhr = value === "XMLHttpRequest";
      if (name === "authorization") result.authorizationPresent = true;
    }
    return result;
  }
}

/** Only booleans and fixed labels leave the page; never input values or text. */
const PAGE_SUMMARY = `(() => {
  const visible = e => e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
  const text = (document.title || '') + '\\n' + (document.body?.innerText || '');
  return {
    ready: document.readyState,
    passwordForm: [...document.querySelectorAll('input[type=password]')].some(visible),
    logoutLink: [...document.querySelectorAll('a[href]')].some(e => visible(e) && /logout/i.test(e.getAttribute('href'))),
    settings: /账号设置|账户设置|个人资料|安全中心|账号安全|账户安全|安全设置/.test(text),
    parameterError: /参数错误|参数不正确|参数异常/.test(text),
    maintenance: /正在维护|系统维护|正在紧急修复|系统异常|调用接口异常/.test(text)
  };
})()`;

class Cdp extends EventEmitter {
  pending = new Map();
  serial = 0;
  constructor(socket) {
    super();
    this.socket = socket;
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error("cdp_command_failed"));
        else pending.resolve(message.result);
      } else this.emit("event", message);
    });
    socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("cdp_closed"));
      }
      this.pending.clear();
      this.emit("closed");
    });
    socket.addEventListener("error", () => {});
  }
  send(method, params = {}, sessionId) {
    return new Promise((resolveCommand, reject) => {
      const id = ++this.serial;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("cdp_timeout"));
      }, 8000);
      this.pending.set(id, { resolve: resolveCommand, reject, timer });
      try {
        this.socket.send(JSON.stringify({ id, method, params, sessionId }));
      } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error("cdp_closed"));
      }
    });
  }
}

function findChrome() {
  for (const path of [
    process.env.CHROME_BIN,
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/opt/google/chrome/chrome",
  ]) {
    if (path && existsSync(path)) return path;
  }
  throw new Error("chrome_not_found");
}

export async function startBrowserTrace({
  headless = false,
  hosts = ["ids.xidian.edu.cn", "ehall.xidian.edu.cn"],
} = {}) {
  if (typeof WebSocket === "undefined") throw new Error("node_22_or_newer_required");
  // ADR-034 §3, red line #8: a fresh private directory outside the repository.
  const directory = mkdtempSync(join(tmpdir(), "elecon-browser-trace-"));
  const profile = join(directory, "profile");
  mkdirSync(profile, { mode: 0o700 });
  const logPath = join(directory, "events.jsonl");
  writeFileSync(logPath, "", { mode: 0o600 });
  const redactor = new TraceRedactor();
  const pages = new Map();
  const tracked = new Set();
  const sequences = new Map();
  const earlyExtras = new Map();
  let cdp,
    timer,
    cookieState,
    sampling = false,
    stopped = false,
    sequence = 0,
    tabNumber = 0;
  const write = (event, fields = {}) => {
    if (!stopped)
      appendFileSync(
        logPath,
        JSON.stringify({ seq: ++sequence, time: new Date().toISOString(), event, ...fields }) + "\n",
      );
  };
  const allowed = (value) => {
    try {
      return hosts.includes(new URL(value).hostname);
    } catch {
      return false;
    }
  };
  const allowedCookie = (cookie) =>
    hosts.some((host) => {
      const domain = cookie.domain.replace(/^\./, "");
      return host === domain || host.endsWith("." + domain);
    });
  const chrome = spawn(
    findChrome(),
    [
      `--user-data-dir=${profile}`,
      "--remote-debugging-port=0",
      "--remote-debugging-address=127.0.0.1",
      "--no-first-run",
      "--no-default-browser-check",
      ...(headless ? ["--headless=new", "--disable-gpu"] : []),
      "about:blank",
    ],
    { stdio: "ignore" },
  );
  let exited = false;
  const closed = new Promise((resolveClosed) => {
    chrome.once("error", () => {
      exited = true;
      resolveClosed();
    });
    chrome.once("exit", () => {
      exited = true;
      resolveClosed();
    });
  });
  const stop = async () => {
    if (stopped) return;
    clearInterval(timer);
    write("trace_stopped");
    stopped = true;
    if (!exited) chrome.kill("SIGTERM");
    cdp?.socket.close();
    await Promise.race([closed, delay(3000)]);
    if (!exited) chrome.kill("SIGKILL");
  };
  try {
    let portFile;
    for (let attempt = 0; attempt < 150; attempt++) {
      if (exited) throw new Error("chrome_launch_failed");
      try {
        portFile = readFileSync(join(profile, "DevToolsActivePort"), "utf8").trim().split("\n");
      } catch {}
      if (portFile?.length === 2) break;
      await delay(100);
    }
    if (portFile?.length !== 2) throw new Error("chrome_debug_port_unavailable");
    const socket = new WebSocket(`ws://127.0.0.1:${Number(portFile[0])}${portFile[1]}`);
    await new Promise((resolveOpen, reject) => {
      socket.addEventListener("open", resolveOpen, { once: true });
      socket.addEventListener("error", () => reject(new Error("chrome_debug_connection_failed")), {
        once: true,
      });
    });
    cdp = new Cdp(socket);
    const version = await cdp.send("Browser.getVersion");
    write("trace_started", {
      browser: version.product,
      userAgent: version.userAgent,
      hosts,
      profile,
      format: 1,
    });

    const snapshot = async () => {
      if (sampling || stopped || exited) return;
      sampling = true;
      try {
        const { cookies } = await cdp.send("Storage.getCookies");
        const clean = cookies.filter(allowedCookie).map((c) => redactor.cookie(c));
        clean.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
        const next = JSON.stringify(clean);
        if (next !== cookieState) {
          cookieState = next;
          write("cookie_snapshot", { cookies: clean });
          writeFileSync(join(directory, "cookies.latest.json"), JSON.stringify(clean, null, 2) + "\n", {
            mode: 0o600,
          });
        }
        for (const [sessionId, page] of pages) {
          if (!allowed(page.url)) continue;
          try {
            const r = await cdp.send(
              "Runtime.evaluate",
              { expression: PAGE_SUMMARY, returnByValue: true },
              sessionId,
            );
            if (!r.result?.value) continue;
            const state = r.result.value;
            const signature = JSON.stringify([redactor.url(page.url), state]);
            if (signature === page.state) continue;
            page.state = signature;
            write("page_state", { tab: page.tab, url: redactor.url(page.url), state });
          } catch {
            /* Navigation may destroy the old execution context. */
          }
        }
      } catch {
        if (!exited && !stopped) write("snapshot_unavailable");
      } finally {
        sampling = false;
      }
    };

    cdp.on("event", async ({ method, params: p, sessionId }) => {
      try {
        if (method === "Target.attachedToTarget") {
          if (p.targetInfo.type !== "page") return;
          const page = { tab: `tab-${++tabNumber}`, target: p.targetInfo.targetId, url: p.targetInfo.url };
          pages.set(p.sessionId, page);
          try {
            await cdp.send("Network.enable", { maxPostDataSize: 0 }, p.sessionId);
            await cdp.send("Page.enable", {}, p.sessionId);
            write("tab_attached", { tab: page.tab, url: redactor.url(page.url) });
          } finally {
            await cdp.send("Runtime.runIfWaitingForDebugger", {}, p.sessionId);
          }
          return;
        }
        if (method === "Target.detachedFromTarget") {
          pages.delete(p.sessionId);
          return;
        }
        const page = pages.get(sessionId);
        if (!page) return;
        const key = `${sessionId}:${p.requestId}`;
        const common = { tab: page.tab, requestId: p.requestId };
        if (method === "Network.requestWillBeSent" && !allowed(p.request.url)) {
          if (tracked.has(key) && p.redirectResponse) {
            write("redirect_outside_scope", {
              ...common,
              url: redactor.url(p.redirectResponse.url),
              to: redactor.url(p.request.url),
              status: p.redirectResponse.status,
            });
          }
          tracked.delete(key);
          earlyExtras.delete(key);
        }
        if (method === "Network.requestWillBeSent" && allowed(p.request.url)) {
          tracked.add(key);
          const hop = (sequences.get(key) ?? -1) + 1;
          sequences.set(key, hop);
          if (p.redirectResponse)
            write("redirect", {
              ...common,
              hop,
              url: redactor.url(p.redirectResponse.url),
              status: p.redirectResponse.status,
              headers: redactor.headers(p.redirectResponse.headers, p.redirectResponse.url),
            });
          write("request", {
            ...common,
            hop,
            type: p.type,
            method: p.request.method,
            url: redactor.url(p.request.url),
            hasPostData: p.request.hasPostData === true,
            headers: redactor.headers(p.request.headers, p.request.url),
          });
          for (const extra of earlyExtras.get(key) ?? []) write(extra.event, extra.fields);
          earlyExtras.delete(key);
        }
        // CDP permits ExtraInfo before requestWillBeSent. Buffer only redacted
        // metadata until that request establishes scope; never guess ordering.
        if (["Network.requestWillBeSentExtraInfo", "Network.responseReceivedExtraInfo"].includes(method)) {
          const extra =
            method === "Network.requestWillBeSentExtraInfo"
              ? {
                  event: "request_cookies",
                  fields: {
                    ...common,
                    headers: redactor.headers(p.headers),
                    associated: p.associatedCookies
                      .filter((c) => allowedCookie(c.cookie))
                      .map((c) => ({ cookie: redactor.cookie(c.cookie), blockedReasons: c.blockedReasons })),
                  },
                }
              : {
                  event: "response_cookies",
                  fields: {
                    ...common,
                    status: p.statusCode,
                    headers: redactor.headers(p.headers),
                    blocked: p.blockedCookies.map((c) => ({
                      cookie: redactor.setCookie(c.cookieLine),
                      blockedReasons: c.blockedReasons,
                    })),
                  },
                };
          if (tracked.has(key)) write(extra.event, extra.fields);
          else {
            if (earlyExtras.size >= 1000) earlyExtras.delete(earlyExtras.keys().next().value);
            earlyExtras.set(key, [...(earlyExtras.get(key) ?? []), extra].slice(-8));
          }
        }
        if (method === "Network.responseReceived" && allowed(p.response.url)) {
          write("response", {
            ...common,
            type: p.type,
            url: redactor.url(p.response.url),
            status: p.response.status,
            mime: p.response.mimeType,
            protocol: p.response.protocol,
            fromServiceWorker: p.response.fromServiceWorker,
            headers: redactor.headers(p.response.headers, p.response.url),
          });
        }
        if (method === "Network.loadingFailed" && tracked.has(key)) {
          write("request_failed", {
            ...common,
            blockedReason: p.blockedReason,
            cancelled: p.canceled,
            error: /^net::[A-Z0-9_]+$/.test(p.errorText) ? p.errorText : "network_error",
          });
        }
        if (method === "Page.frameNavigated" && !p.frame.parentId) {
          page.url = p.frame.url;
          write("navigation", { tab: page.tab, url: redactor.url(page.url) });
        }
        if (method === "Page.navigatedWithinDocument" && allowed(p.url)) {
          page.url = p.url;
          write("same_document_navigation", { tab: page.tab, url: redactor.url(p.url) });
        }
        if (method === "Page.loadEventFired") await snapshot();
      } catch {
        if (!exited && !stopped) write("event_unavailable", { method });
      }
    });
    await cdp.send("Target.setAutoAttach", {
      autoAttach: true,
      waitForDebuggerOnStart: true,
      flatten: true,
      filter: [{ type: "page" }, { exclude: true }],
    });
    timer = setInterval(() => {
      void snapshot();
    }, 2000);
    await snapshot();
    closed.then(() => {
      clearInterval(timer);
      write("browser_closed");
      cdp.socket.close();
    });
    return { directory, profile, logPath, cdp, pages, snapshot, stop, closed };
  } catch (error) {
    await stop();
    throw error;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length) {
    console.error("Usage: node scripts/browser-trace.mjs (Node 22+, CHROME_BIN optional)");
    process.exitCode = 1;
  } else {
    try {
      const trace = await startBrowserTrace();
      console.log(
        `browser_trace_ready\nprofile: ${trace.profile}\nevents: ${trace.logPath}\ncookies: ${join(trace.directory, "cookies.latest.json")}`,
      );
      console.log(
        "Chrome 已打开空白页。请手动访问 E-Hall，完成授权回跳，再访问 https://ids.xidian.edu.cn/authserver。关闭此 Chrome 窗口结束监听。",
      );
      for (const signal of ["SIGINT", "SIGTERM"])
        process.once(signal, () => {
          void trace.stop();
        });
      await trace.closed;
    } catch {
      console.error(
        "browser_trace_failed: check Node 22+, Chrome installation, and graphical desktop availability",
      );
      process.exitCode = 1;
    }
  }
}
