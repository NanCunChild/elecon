// Copyright 2023-2025 BenderBlog Rodriguez and contributors
// Copyright 2025-2026 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0
// Protocol/target references: traintime_pda ids_session/{ids_session,
// school_card_session,library_session,classtable_session}.dart. Reimplemented
// with the trusted SDK: school pages perform password, slider and MFA UI.

import { failure } from "./errors.js";
import { browserCookiesForUrl, readSession, replaceBrowserCookiesForUrl, saveSession } from "./session.js";

const IDS_LOGIN = "https://ids.xidian.edu.cn/authserver/login";
const IDS_URLS = [
  IDS_LOGIN,
  "https://ids.xidian.edu.cn/authserver/reAuthCheck/reAuthLoginView.do",
  "https://ids.xidian.edu.cn/authserver/bfp/info",
];
export const IDS_ACCOUNT_URLS = [
  ...IDS_URLS,
  "https://ids.xidian.edu.cn/personalInfo/personCenter/index.html",
  "https://ids.xidian.edu.cn/personalInfo/personalMobile/index.html",
  "https://ids.xidian.edu.cn/personalInfo/accountSecurity/accountSetting",
];
const EHALL = "https://ehall.xidian.edu.cn";
const EHALL_HTTP = "http://ehall.xidian.edu.cn";
const YJSPT = "https://yjspt.xidian.edu.cn";
const CARD = "https://v8scan.xidian.edu.cn";
const LIBRARY = "https://mfindxidian.libsp.cn";
const CHAOXING = "https://tyrzfw.chaoxing.com";
const LIBRARY_SERVICE = `${CHAOXING}/auth/xidian/cas/init?isLogout=0&refer=${encodeURIComponent(`${LIBRARY}/find/sso/login/xidian/1`)}`;

export const LOGIN_TARGETS = {
  ehall: {
    // Business destination, visited after portal login and independent IDS
    // verification (2026-10-30 browser experiment; ADR-034 §5 / ADR-035 §3).
    openUrl: `${EHALL}/appShow?appId=4770397878132218`,
    cookieUrls: [
      `${EHALL}/appShow`,
      ...[
        "wdkb/modules/jshkcb/dqxnxq.do",
        "wdkb/modules/jshkcb/cxjcs.do",
        "wdkb/modules/xskcb/xskcb.do",
        "wdkb/modules/xskcb/xsdkkc.do",
        "cjcx/modules/cjcx/xscjcx.do",
        "studentWdksapApp/modules/wdksap/wdksap.do",
        "studentWdksapApp/modules/wdksap/cxyxkwapkwdkc.do",
        "kxjas/modules/kxjas/jxlcx.do",
        "kxjas/modules/kxjas/rqzhzcjc.do",
        "kxjas/modules/kxjas/cxjsqk.do",
      ].map((path) => `${EHALL}/jwapp/sys/${path}`),
    ],
  },
  yjspt: {
    service: `${YJSPT}/gsapp/sys/yjsemaphome/portal/index.do`,
    cookieUrls: [
      `${YJSPT}/gsapp/sys/yjsemaphome/portal/index.do`,
      ...[
        "yjsemaphome/modules/pubWork/getUserInfo.do",
        "yjsemaphome/homeAppend/getSchoolCalendar.do",
        "wdkbapp/modules/xskcb/xspkjgcx.do",
        "wdcjapp/modules/wdcj/xscjcx.do",
        "wdksapp/modules/ksxxck/wdksxxcx.do",
      ].map((path) => `${YJSPT}/gsapp/sys/${path}`),
    ],
  },
  card: {
    // This endpoint starts its own official OAuth/CAS chain. It is not a
    // guessed CAS service URL; xxcapp.xidian.edu.cn is its OAuth intermediary (2026-10-30 probe).
    // the final page contains the real hidden openid.
    openUrl: `${CARD}/home/openXDOAuth2Page`,
    cookieUrls: [
      `${CARD}/home/openXDOAuth2Page`,
      `${CARD}/home/openHomePage`,
      `${CARD}/myaccount/openMyAccount`,
      `${CARD}/selftrade/queryCardSelfTradeList`,
    ],
  },
  library: {
    // The official entry first sets firstReferer, then starts IDS with its
    // /cas/index callback (unauthenticated page inspection, 2026-11-02).
    // Enter it directly so the page owns this initialization and callback;
    // treating /cas/init as an IDS service skips the normal initial step.
    openUrl: LIBRARY_SERVICE,
    cookieUrls: [
      `${CHAOXING}/auth/xidian/cas/init`,
      `${CHAOXING}/auth/xidian/cas/login`,
      `${LIBRARY}/find/sso/login/xidian/1`,
      `${LIBRARY}/find/loanInfo/loanList`,
      `${LIBRARY}/oga/userinfo`,
      `${LIBRARY}/find/homePage/getGroupCode`,
    ],
  },
};

export const capabilities = {
  "generic.section": createLogin("undergraduate"),
};

function cookieUrls(system, data) {
  const urls = LOGIN_TARGETS[system].cookieUrls;
  return system === "ehall" && data?.origin === EHALL_HTTP
    ? urls.map((url) => url.replace(EHALL, EHALL_HTTP))
    : urls;
}

// ADR-034 §3 / ADR-035 §2: bind login to the installed school, before any I/O.
export function createLogin(role) {
  if (role !== "undergraduate" && role !== "postgraduate") throw new Error("academic_role_invalid");
  return (ctx, params = {}) => {
    if (params.role != null && params.role !== role) throw new Error("xidian_school_role_mismatch");
    const requested = { "card-session": "card", "library-session": "library" }[params.requiredRef];
    const system = params.system ?? requested ?? (role === "postgraduate" ? "yjspt" : "ehall");
    if (role === "undergraduate" && system === "yjspt") throw new Error("xidian_school_system_mismatch");
    // PG may explicitly log into E-Hall for the shared classroom application.
    return login(ctx, { ...params, system }, role);
  };
}

export async function login(ctx, params = {}, schoolRole) {
  const system = params.system ?? "ehall";
  if (typeof system !== "string" || !Object.hasOwn(LOGIN_TARGETS, system))
    throw new Error("xidian_login_system_invalid");
  if (!ctx.browser) throw new Error("xidian_login_browser_required");
  const target = LOGIN_TARGETS[system];
  const previous = await readSession(ctx, system);
  let ids = await readSession(ctx, "ids");
  const staged = system === "ehall";
  const idsUrls = staged ? IDS_ACCOUNT_URLS : IDS_URLS;
  const progress = { polls: 0, phaseLogs: 0, staged, studentId: undefined };
  const deadline = ctx.now() + 100000;
  await restore(ctx, ids, idsUrls);
  await restore(ctx, previous, cookieUrls(system, previous?.data));
  const openUrl = target.openUrl ?? `${IDS_LOGIN}?service=${encodeURIComponent(target.service)}`;
  const suppliedStudentId = params.studentId ?? params.account;
  const studentId = typeof suppliedStudentId === "string" ? suppliedStudentId.trim() : "";
  if (staged) {
    ctx.log?.("info", "xidian_login_open:ehall_portal");
    await ctx.browser.open(`${EHALL}/`);
    const landing = await waitForLogin(ctx, "ehall-portal", deadline, previous, ids, progress);
    if (!landing.idsLanding) ctx.log?.("info", "xidian_login_verified:ehall_portal");
    // Use the no-service HTTPS login entry: the bare /authserver path has
    // HTTP Location hops which desktop Chrome internally upgrades via HSTS.
    await ctx.browser.open(IDS_LOGIN);
    const verified = await waitForLogin(ctx, "ids", deadline, ids, ids, progress);
    const metadata = { ...(ids?.data ?? {}), role: schoolRole ?? "undergraduate" };
    delete metadata.studentId;
    if (studentId || progress.studentId) metadata.studentId = studentId || progress.studentId;
    // ADR-035 §3: this verified IDS result survives later business failures.
    ids = await saveIds(ctx, null, metadata, verified.cookies);
    ctx.log?.("info", "xidian_login_saved:ids");
    if (landing.idsLanding) {
      // Android IDS may finish at its mobile personal center instead of
      // returning to the service. Keep verified SSO, then resume the portal
      // once using the same browser session (ADR-034 §5 / ADR-035 §3).
      progress.portalResumed = true;
      ctx.log?.("info", "xidian_login_resume:ehall_portal");
      await ctx.browser.open(`${EHALL}/`);
      await waitForLogin(ctx, "ehall-portal", deadline, previous, ids, progress);
      ctx.log?.("info", "xidian_login_verified:ehall_portal");
    }
  }
  // Only stable stages/system names enter diagnostics; never URL/ticket/cookies.
  ctx.log?.("info", `xidian_login_open:${system}`);
  await ctx.browser.open(openUrl);
  const verified = await waitForLogin(ctx, system, deadline, previous, ids, progress);
  const { data, cookies } = verified;
  if (system === "card") data.openidFetchedAt = ctx.now();
  if (studentId) data.studentId = studentId;
  else if (!data.studentId && typeof previous?.data?.studentId === "string")
    data.studentId = previous.data.studentId;
  // Save authentication before producing business output. Tokens/openid and
  // the student id are never included in the generic result or log messages.
  await saveSession(ctx, system, {
    version: 1,
    service: system,
    cookies,
    data,
    updatedAt: ctx.now(),
  });
  if (!staged) {
    const idsForSuccess = { ...ids, data: { ...(ids?.data ?? {}) } };
    if (system === "yjspt" && !data.studentId) delete idsForSuccess.data.studentId;
    await saveIds(
      ctx,
      idsForSuccess,
      {
        ...(schoolRole ? { role: schoolRole } : system === "yjspt" ? { role: "postgraduate" } : {}),
        ...(data.studentId ? { studentId: data.studentId } : {}),
      },
      verified.idsCookies,
    );
  }
  ctx.log?.("info", `xidian_login_saved:${system}`);
  return {
    sectionId: "xidian.login",
    title: "西电登录会话",
    fields: [
      { label: "系统", role: "label", value: system },
      { label: "状态", role: "status", value: "已保存会话，可返回业务脚本取数" },
    ],
  };
}

export async function restore(ctx, session, urls) {
  if (!session) return;
  for (const url of urls) {
    const cookies = browserCookiesForUrl(session, url, ctx.now());
    if (cookies.length) await ctx.browser.setCookies(url, cookies);
  }
}

async function capture(ctx, urls, existing) {
  let cookies = existing;
  for (const url of urls) {
    // Each native result is the latest snapshot for this actual business URL,
    // including an empty result after deletion. Unknown Android attributes are
    // conservatively bound by the shared helper to their captured URL.
    cookies = replaceBrowserCookiesForUrl(cookies, url, await ctx.browser.cookies(url));
  }
  return cookies;
}

async function saveIds(ctx, previous, data = {}, cookies) {
  if (!previous && !cookies.length && !Object.keys(data).length) return;
  const session = {
    version: 1,
    service: "ids",
    cookies,
    data: { ...(previous?.data ?? {}), ...data },
    updatedAt: ctx.now(),
  };
  await saveSession(ctx, "ids", session);
  return session;
}

export async function waitForLogin(ctx, system, deadline, previous, ids, progress) {
  // ADR-034 §6: staged login shares 135 polls, five phase logs and at most
  // four IDS/five business snapshots. With 17 restore URLs, final checks,
  // two credential reads and two writes the largest E-Hall case is <=254,
  // including one optional portal resume after a mobile IDS landing.
  // host calls. Legacy targets keep their existing six-snapshot bound.
  let fingerprint;
  let stableSince = 0;
  let captures = 0;
  let lastCapture = -Infinity;
  let lastPhase;
  for (let attempt = 0; progress.polls < (progress.staged ? 135 : 150) && ctx.now() < deadline; attempt++) {
    progress.polls++;
    let state;
    try {
      state = await ctx.browser.evaluate(
        inspectLoginPage,
        system,
        attempt ? (progress.staged ? 750 : 500) : 0,
      );
    } catch (error) {
      // Page navigation invalidates the old document's promise. Retrying is
      // appropriate only for that transition, never for user cancellation.
      if (
        ["browser_navigation_changed", "browser_not_loaded", "browser_failed"].some((code) =>
          String(error).includes(code),
        )
      ) {
        fingerprint = undefined;
        // The current host masks native bridge failures as browser_failed.
        // Its pinned QuickJS runtime installs setTimeout; use it only while
        // there is no ready document in which to run the normal page timer.
        await new Promise((resolve) => setTimeout(resolve, 500));
        continue;
      }
      throw error;
    }
    if (typeof state?.studentId === "string" && /^\d{6,20}$/.test(state.studentId)) {
      progress.studentId = state.studentId;
    }
    if (system === "ehall-portal" && state?.verifiedIdsLanding && !progress.portalResumed) {
      return { idsLanding: true };
    }
    if (
      !state?.ready &&
      [
        "business_page_pending",
        "business_http_failed",
        "business_redirect",
        "business_data_invalid",
        "business_probe_failed",
        "maintenance_page",
      ].includes(state?.phase) &&
      state.phase !== lastPhase &&
      progress.phaseLogs < (progress.staged ? 5 : 8)
    ) {
      lastPhase = state.phase;
      progress.phaseLogs++;
      ctx.log?.("info", `xidian_login_wait:${system}:${state.phase}`);
    }
    if (!state?.ready && !(system === "library" && state?.libraryOrigin)) {
      fingerprint = undefined;
      continue;
    }
    if (system === "ehall-portal") return { data: state.data ?? {} };
    let data = { ...(state.data ?? {}), ...(progress.studentId ? { studentId: progress.studentId } : {}) };
    if (system === "library" && !data.token) {
      if (!captures && attempt % 10 !== 0) continue;
      const cookies = await ctx.browser.cookies(`${LIBRARY}/find/loanInfo/loanList`);
      data = {
        token: cookies.find((cookie) => cookie.name === "jwt" && typeof cookie.value === "string")?.value,
      };
    }
    if (system === "library" && !data.token) {
      fingerprint = undefined;
      continue;
    }
    // Bound all snapshot work as well as page polling to the SDK host budget.
    if (progress.staged && ctx.now() - lastCapture < 750) continue;
    lastCapture = ctx.now();
    if (++captures > (progress.staged ? (system === "ids" ? 4 : 5) : 6))
      throw new Error("xidian_login_unstable");
    const cookies = await capture(
      ctx,
      system === "ids" ? IDS_ACCOUNT_URLS : cookieUrls(system, data),
      previous?.cookies ?? [],
    );
    const idsCookies = progress.staged ? [] : await capture(ctx, IDS_URLS, ids?.cookies ?? []);
    if (["ids", "ehall", "yjspt"].includes(system) && !cookies.length) {
      fingerprint = undefined;
      continue;
    }
    const next = JSON.stringify([state.page, data, cookies, idsCookies]);
    if (next !== fingerprint) {
      fingerprint = next;
      stableSince = ctx.now();
      continue;
    }
    if (ctx.now() - stableSince < 1200) continue;
    if (system === "library") {
      const groupCode = await ctx.browser.evaluate(libraryGroupCode, data.token);
      if (groupCode) data = { ...data, groupCode };
    }
    // Cookie reads and optional library work can span a redirect into MFA.
    // Recheck the actual page and authenticated endpoint before any writes.
    const final = await ctx.browser.evaluate(inspectLoginPage, system, 0);
    if (
      !(system === "library" ? final?.libraryOrigin : final?.ready) ||
      final.page !== state.page ||
      (system === "card" && final.data?.openid !== data.openid) ||
      (system === "library" && final.data?.token && final.data.token !== data.token)
    ) {
      fingerprint = undefined;
      continue;
    }
    if (ctx.now() >= deadline) throw failure("xidian_login_timeout");
    return { data, cookies, idsCookies };
  }
  throw failure("xidian_login_timeout");
}

// Executed in the actual school page. No QuickJS closure variables are used.
export async function inspectLoginPage(system, delayMs) {
  if (delayMs) await new Promise((resolve) => setTimeout(resolve, delayMs));
  const url = new URL(location.href);
  if (url.origin === "https://ids.xidian.edu.cn" && url.pathname.startsWith("/authserver/")) {
    const studentId = document.querySelector("#username")?.value?.trim();
    return { ready: false, ...(/^\d{6,20}$/.test(studentId ?? "") ? { studentId } : {}) };
  }
  // ADR-034 §4: HTTP E-Hall is an explicitly declared school origin. Keep
  // the real page scheme for its business probe and cookie snapshot.
  const allowedHttp =
    (system === "ehall" || system === "ehall-portal") && url.origin === "http://ehall.xidian.edu.cn";
  if (
    (!allowedHttp && url.protocol !== "https:") ||
    document.readyState !== "complete" ||
    document.querySelector("#pwdFromId")
  )
    return { ready: false };
  const page = `${url.origin}${url.pathname}`;
  if (system === "ehall-portal" || system === "ids") {
    const idsCenter =
      url.origin === "https://ids.xidian.edu.cn" &&
      ["/personalInfo/personCenter/index.html", "/personalInfo/personalMobile/index.html"].includes(
        url.pathname,
      );
    const idsLanding = system === "ehall-portal" && idsCenter;
    const portal = system === "ehall-portal" && !idsLanding;
    if (
      portal
        ? !["https://ehall.xidian.edu.cn", "http://ehall.xidian.edu.cn"].includes(url.origin) ||
          url.pathname !== "/new/index_xd.html"
        : !idsCenter
    )
      return { ready: false, phase: "business_page_pending" };
    try {
      const response = await fetch(
        portal ? "/jsonp/getUserAllUsableApp?searchKey=" : "/personalInfo/accountSecurity/accountSetting",
        {
          method: portal ? "GET" : "POST",
          credentials: "same-origin",
          ...(portal ? {} : { headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "" }),
        },
      );
      if (!response.ok) return { ready: false, phase: "business_http_failed" };
      if (response.redirected || (response.url && new URL(response.url).origin !== url.origin))
        return { ready: false, phase: "business_redirect" };
      const result = await response.json();
      const account = result?.datas?.userid;
      const valid = portal
        ? result?.hasLogin === true && Array.isArray(result.data)
        : String(result?.code) === "0" &&
          ((typeof account === "string" && !!account.trim() && account.trim() !== "0") ||
            (typeof account === "number" && Number.isFinite(account) && account > 0));
      const ready = valid && location.href === url.href && document.readyState === "complete";
      // Return neither account identifiers nor settings data from the page.
      return {
        ready: ready && !idsLanding,
        page,
        ...(ready && idsLanding ? { verifiedIdsLanding: true } : {}),
        ...(!ready ? { phase: "business_data_invalid" } : {}),
      };
    } catch (_) {
      return { ready: false, phase: "business_probe_failed" };
    }
  }
  if (system === "ehall" || system === "yjspt") {
    const pg = system === "yjspt";
    if (
      url.hostname !== (pg ? "yjspt.xidian.edu.cn" : "ehall.xidian.edu.cn") ||
      !url.pathname.startsWith(pg ? "/gsapp/" : "/jwapp/")
    )
      return { ready: false, phase: "business_page_pending" };
    try {
      // Read-only authenticated endpoints witnessed in Traintime semester_session.dart.
      // A business-looking URL, session Cookie or HTTP 200 alone is insufficient.
      const response = await fetch(
        pg
          ? "/gsapp/sys/yjsemaphome/modules/pubWork/getUserInfo.do"
          : "/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do",
        {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: "",
        },
      );
      if (!response.ok) return { ready: false, phase: "business_http_failed" };
      if (response.redirected || (response.url && new URL(response.url).origin !== url.origin))
        return { ready: false, phase: "business_redirect" };
      const result = await response.json();
      const term = pg ? result?.data?.xnxqdm : result?.datas?.dqxnxq?.rows?.[0]?.DM;
      const ready =
        (result.code == null ? !pg : String(result.code) === "0") &&
        (pg ||
          result.datas.dqxnxq.extParams?.code == null ||
          Number(result.datas.dqxnxq.extParams.code) === 1) &&
        typeof term === "string" &&
        /^\d{4}-\d{4}-[12]$/.test(term) &&
        location.href === url.href &&
        document.readyState === "complete";
      return {
        ready,
        page,
        data: pg ? {} : { origin: url.origin },
        ...(!ready ? { phase: "business_data_invalid" } : {}),
      };
    } catch (_) {
      const maintenance = /正在维护|系统维护中|under maintenance/i.test(document.body?.innerText ?? "");
      return { ready: false, phase: maintenance ? "maintenance_page" : "business_probe_failed" };
    }
  }
  if (system === "card") {
    const openid = document.querySelector('input#openid[type="hidden"]')?.value;
    return {
      ready: url.hostname === "v8scan.xidian.edu.cn" && typeof openid === "string" && !!openid.trim(),
      page,
      data: typeof openid === "string" ? { openid: openid.trim() } : {},
    };
  }
  if (url.hostname !== "mfindxidian.libsp.cn") return { ready: false };
  const fragmentQuery = url.hash.indexOf("?");
  const fragmentParams = new URLSearchParams(fragmentQuery >= 0 ? url.hash.slice(fragmentQuery + 1) : "");
  const cookie = document.cookie
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith("jwt="));
  const token = url.searchParams.get("jwt") || fragmentParams.get("jwt") || (cookie ? cookie.slice(4) : "");
  return { libraryOrigin: true, ready: !!token, page, data: token ? { token } : {} };
}

export async function libraryGroupCode(token) {
  // JWT claims are server-provided metadata, not a local authorization check.
  try {
    const encoded = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "=")));
    if (typeof payload.groupCode === "string" && payload.groupCode) return payload.groupCode;
    if (typeof payload.groupCode === "number" && Number.isFinite(payload.groupCode))
      return String(payload.groupCode);
  } catch (_) {}
  try {
    const response = await fetch("/find/homePage/getGroupCode", {
      method: "POST",
      headers: { "Content-Type": "application/json;charset=utf-8", jwtOpacAuth: token },
      body: JSON.stringify({ mappingPath: "" }),
    });
    if (!response.ok) return null;
    const value = (await response.json())?.data?.groupCode;
    return typeof value === "string" || typeof value === "number" ? String(value) : null;
  } catch (_) {
    return null;
  }
}
