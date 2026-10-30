// 🔒 Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// ADR-034 §3/§5, ADR-035 §2/§3: the official page owns primary authentication.
// Harvest verified SSO independently; business requests never render app HTML.
import { IDS_ACCOUNT_URLS, restore, waitForLogin } from "./browser_login.js";
import { failure } from "./errors.js";
import { createClient, parseUrl, readSession, saveSession } from "./session.js";

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
  if (!ctx.browser) throw new Error("xidian_login_browser_required");
  const deadline = ctx.now() + 100000;
  const ids = await readSession(ctx, "ids");
  const progress = { polls: 0, phaseLogs: 0, staged: true };
  await restore(ctx, ids, IDS_ACCOUNT_URLS);
  ctx.log?.("info", "xidian_login_open:ids");
  // No service parameter, password extraction, replacement form or protocol
  // login. The user completes the school's own slider and MFA in this page.
  await ctx.browser.open(IDS_LOGIN);
  const verified = await waitForLogin(ctx, "ids", deadline, ids, ids, progress);
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
