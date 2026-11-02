// 🔒 Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// ADR-034 §3/§5, ADR-035 §2/§3: the official page owns primary authentication.
// Harvest verified SSO independently; business requests never render app HTML.
import { IDS_ACCOUNT_URLS, inspectLoginPage, restore } from "./browser_login.js";
import { failure } from "./errors.js";
import { createClient, parseUrl, readSession, replaceBrowserCookiesForUrl, saveSession } from "./session.js";

const IDS_LOGIN = "https://ids.xidian.edu.cn/authserver/login";
const TARGETS = {
  ehall: {
    origin: "https://ehall.xidian.edu.cn",
    service: "https://ehall.xidian.edu.cn/appShow?appId=4770397878132218",
    probe: "/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do",
  },
  yjspt: {
    origin: "https://yjspt.xidian.edu.cn",
    service: "https://yjspt.xidian.edu.cn/",
    probe: "/gsapp/sys/yjsemaphome/modules/pubWork/getUserInfo.do",
  },
};

export async function webviewLogin(ctx, params, role) {
  const system = params.system;
  const target = TARGETS[system];
  if (!target) throw new Error("xidian_login_system_invalid");
  const { metadata, deadline } = await loginIds(ctx, params, role);
  await establishAcademicSession(ctx, system, metadata, deadline);
  return {
    sectionId: "xidian.login",
    title: "西电登录会话",
    fields: [
      { label: "系统", role: "label", value: system },
      { label: "状态", role: "status", value: "已验证并保存会话" },
    ],
  };
}

// ADR-040 §2: water/electricity reuse verified IDS without requiring E-Hall.
export async function loginIds(ctx, params, role) {
  if (!ctx.browser) throw new Error("xidian_login_browser_required");
  const deadline = ctx.now() + 100000;
  const ids = params.forceLogin ? null : await readSession(ctx, "ids");
  const progress = {};
  await restore(ctx, ids, IDS_ACCOUNT_URLS);
  ctx.log?.("info", "xidian_login_open:ids");
  // No service parameter, password extraction, replacement form or protocol
  // login. The user completes the school's own slider and MFA in this page.
  await ctx.browser.open(IDS_LOGIN);
  const verified = await waitForIdsSession(ctx, deadline, ids, progress);
  const supplied = params.studentId ?? params.account;
  const studentId = (typeof supplied === "string" ? supplied.trim() : "") || progress.studentId;
  const metadata = { role, authFlow: "webview", ...(studentId ? { studentId } : {}) };
  await saveSession(ctx, "ids", {
    version: 1,
    service: "ids",
    cookies: verified.cookies,
    data: metadata,
  });
  ctx.log?.("info", "xidian_login_saved:ids");
  return { metadata, deadline };
}

// ADR-039 §2: two authenticated, matching snapshots replace the legacy
// multi-stage 1200ms settle window. Never log snapshot contents or page URLs.
export async function waitForIdsSession(ctx, deadline, previous, progress) {
  let fingerprint;
  let sampleAt = 0;
  let captures = 0;
  let busy = false;
  for (let poll = 0; poll < 150 && ctx.now() < deadline; poll++) {
    let state;
    try {
      state = await ctx.browser.evaluate(inspectLoginPage, "ids", poll ? (busy ? 250 : 750) : 0);
    } catch (error) {
      if (
        !["browser_navigation_changed", "browser_not_loaded", "browser_failed"].some((code) =>
          String(error).includes(code),
        )
      )
        throw error;
      fingerprint = undefined;
      if (busy) {
        await ctx.browser.setBusy(false);
        busy = false;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
      continue;
    }
    if (typeof state?.studentId === "string" && /^\d{6,20}$/.test(state.studentId))
      progress.studentId = state.studentId;
    if (!state?.ready) {
      fingerprint = undefined;
      if (busy) {
        await ctx.browser.setBusy(false);
        busy = false;
      }
      continue;
    }
    if (!busy) {
      await ctx.browser.setBusy(true);
      busy = true;
    }
    if (++captures > 6) throw new Error("xidian_login_unstable");
    const snapshots = await Promise.all(IDS_ACCOUNT_URLS.map((url) => ctx.browser.cookies(url)));
    let cookies = previous?.cookies ?? [];
    for (let i = 0; i < IDS_ACCOUNT_URLS.length; i++)
      cookies = replaceBrowserCookiesForUrl(cookies, IDS_ACCOUNT_URLS[i], snapshots[i]);
    const sorted = cookies.map((cookie) => JSON.stringify(cookie)).sort();
    const next = JSON.stringify([state.page, sorted]);
    if (!cookies.length || next !== fingerprint) {
      fingerprint = cookies.length ? next : undefined;
      sampleAt = ctx.now();
      continue;
    }
    if (ctx.now() - sampleAt < 250) continue;
    // Native Cookie reads may span navigation into login/MFA. The final
    // location check performs no extra accountSetting request.
    if ((await ctx.browser.evaluate(inspectIdsLocation)) !== state.page) {
      fingerprint = undefined;
      await ctx.browser.setBusy(false);
      busy = false;
      continue;
    }
    if (ctx.now() >= deadline) throw failure("xidian_login_timeout");
    return { cookies };
  }
  throw failure("xidian_login_timeout");
}

export function inspectIdsLocation() {
  const url = new URL(location.href);
  return url.origin === "https://ids.xidian.edu.cn" &&
    ["/personalInfo/personCenter/index.html", "/personalInfo/personalMobile/index.html"].includes(
      url.pathname,
    ) &&
    document.readyState === "complete" &&
    !document.querySelector("#pwdFromId")
    ? `${url.origin}${url.pathname}`
    : null;
}

// Read-only CAS service exchange after harvesting. Does not accept passwords
// or perform primary login; the separate PDA experiment is not imported here.
export async function establishAcademicSession(ctx, system, metadata, deadline) {
  const target = TARGETS[system];
  if (!target) throw new Error("xidian_login_system_invalid");
  const pending = { version: 1, service: system, cookies: [], data: { ...metadata } };
  const client = await createClient(ctx, system, { initialSession: pending, persistSession: false });
  ctx.log?.("info", `xidian_login_exchange:${system}`);
  const landing = await client.request(`${IDS_LOGIN}?service=${encodeURIComponent(target.service)}`);
  const actual = parseUrl(landing.url);
  if (actual.host === "ids.xidian.edu.cn") throw failure(`xidian_login_required_${system}`);
  if (!landing.ok || actual.host !== parseUrl(target.origin).host) throw failure("academic_response_invalid");
  // Never execute the mobile/desktop app's HTML bootstrap. A successful CAS
  // callback and its Cookie alone are insufficient: verify the actual API.
  pending.data.origin = actual.origin;
  ctx.log?.("info", `xidian_login_probe:${system}`);
  let result;
  try {
    result = await client.postForm(`${actual.origin}${target.probe}`);
  } catch (error) {
    if (["xidian_non_json_response", "xidian_http_failed"].includes(error?.message))
      throw failure("academic_response_invalid");
    throw error;
  }
  const term = system === "ehall" ? result?.datas?.dqxnxq?.rows?.[0]?.DM : result?.data?.xnxqdm;
  const match = typeof term === "string" && /^(\d{4})-(\d{4})-[12]$/.exec(term);
  if (
    String(result?.code) !== "0" ||
    !match ||
    Number(match[2]) !== Number(match[1]) + 1 ||
    (system === "ehall" &&
      result.datas.dqxnxq.extParams?.code != null &&
      Number(result.datas.dqxnxq.extParams.code) !== 1) ||
    !pending.cookies.length
  )
    throw failure("academic_response_invalid");
  if (ctx.now() >= deadline) throw failure("xidian_login_timeout");
  pending.data.currentTerm = term;
  await saveSession(ctx, system, pending);
  ctx.log?.("info", `xidian_login_saved:${system}`);
}
