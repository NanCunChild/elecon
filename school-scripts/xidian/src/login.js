// Copyright 2023-2025 BenderBlog Rodriguez and contributors
// Copyright 2025-2026 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0
// Protocol/target references: traintime_pda ids_session/{ids_session,
// school_card_session,library_session,classtable_session}.dart. Reimplemented
// with the trusted SDK: school pages perform password, slider and MFA UI.
import { browserCookiesForUrl, readSession, replaceBrowserCookiesForUrl, saveSession } from "./session.js";

const IDS_LOGIN = "https://ids.xidian.edu.cn/authserver/login";
const IDS_URLS = [
  IDS_LOGIN,
  "https://ids.xidian.edu.cn/authserver/reAuthCheck/reAuthLoginView.do",
  "https://ids.xidian.edu.cn/authserver/bfp/info",
];
const EHALL = "https://ehall.xidian.edu.cn";
const YJSPT = "https://yjspt.xidian.edu.cn";
const CARD = "https://v8scan.xidian.edu.cn";
const LIBRARY = "https://mfindxidian.libsp.cn";
const CHAOXING = "https://tyrzfw.chaoxing.com";
const LIBRARY_SERVICE = `${CHAOXING}/auth/xidian/cas/init?isLogout=0&refer=${encodeURIComponent(`${LIBRARY}/find/sso/login/xidian/1`)}`;

export const LOGIN_TARGETS = {
  ehall: {
    service: `${EHALL}/appShow?appId=4770397878132218`,
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
    // guessed CAS service URL; the final page contains the real hidden openid.
    openUrl: `${CARD}/home/openXDOAuth2Page`,
    cookieUrls: [
      `${CARD}/home/openXDOAuth2Page`,
      `${CARD}/home/openHomePage`,
      `${CARD}/myaccount/openMyAccount`,
      `${CARD}/selftrade/queryCardSelfTradeList`,
    ],
  },
  library: {
    service: LIBRARY_SERVICE,
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
  "generic.section": login,
};

export async function login(ctx, params = {}) {
  const system = params.system ?? "ehall";
  if (typeof system !== "string" || !Object.hasOwn(LOGIN_TARGETS, system))
    throw new Error("xidian_login_system_invalid");
  if (!ctx.browser) throw new Error("xidian_login_browser_required");
  const target = LOGIN_TARGETS[system];
  const previous = await readSession(ctx, system);
  const ids = await readSession(ctx, "ids");
  const deadline = ctx.now() + 100000;
  await restore(ctx, ids, IDS_URLS);
  await restore(ctx, previous, target.cookieUrls);
  const openUrl = target.openUrl ?? `${IDS_LOGIN}?service=${encodeURIComponent(target.service)}`;
  try {
    await ctx.browser.open(openUrl);
    const data = await waitForLogin(ctx, system, deadline);
    if (system === "card") data.openidFetchedAt = ctx.now();
    const suppliedStudentId = params.studentId ?? params.account;
    const studentId = typeof suppliedStudentId === "string" ? suppliedStudentId.trim() : "";
    if (studentId) data.studentId = studentId;
    else if (typeof previous?.data?.studentId === "string") data.studentId = previous.data.studentId;
    const cookies = await capture(ctx, target.cookieUrls, previous?.cookies ?? []);
    if ((system === "ehall" || system === "yjspt") && cookies.length === 0) {
      throw new Error("xidian_login_cookie_missing");
    }
    // Save authentication before producing business output. Tokens/openid and
    // the student id are never included in the generic result or log messages.
    await saveSession(ctx, system, {
      version: 1,
      service: system,
      cookies,
      data,
      updatedAt: ctx.now(),
    });
    const idsForSuccess = { ...ids, data: { ...(ids?.data ?? {}) } };
    if ((system === "ehall" || system === "yjspt") && !data.studentId) delete idsForSuccess.data.studentId;
    await saveIds(ctx, idsForSuccess, {
      ...(system === "ehall" ? { role: "undergraduate" } : {}),
      ...(system === "yjspt" ? { role: "postgraduate" } : {}),
      ...(data.studentId ? { studentId: data.studentId } : {}),
    });
    return {
      sectionId: "xidian.login",
      title: "西电登录会话",
      fields: [
        { label: "系统", role: "label", value: system },
        { label: "状态", role: "status", value: "已保存会话，可返回业务脚本取数" },
      ],
    };
  } catch (error) {
    // Preserve a newly issued IDS cookie even if a later service challenge or
    // business page fails. Cancellation still rejects writes in the host.
    try {
      await saveIds(ctx, ids);
    } catch (_) {}
    throw error;
  }
}

async function restore(ctx, session, urls) {
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

async function saveIds(ctx, previous, data = {}) {
  const cookies = await capture(ctx, IDS_URLS, previous?.cookies ?? []);
  if (!previous && !cookies.length && !Object.keys(data).length) return;
  await saveSession(ctx, "ids", {
    version: 1,
    service: "ids",
    cookies,
    data: { ...(previous?.data ?? {}), ...data },
    updatedAt: ctx.now(),
  });
}

async function waitForLogin(ctx, system, deadline) {
  // At most 150 page calls, leaving the 256-host-call budget for restoring and
  // collecting cookies. Page timers avoid assuming QuickJS has browser timers.
  for (let attempt = 0; attempt < 150 && ctx.now() < deadline; attempt++) {
    let state;
    try {
      state = await ctx.browser.evaluate(inspectLoginPage, system, attempt ? 500 : 0);
    } catch (error) {
      // Page navigation invalidates the old document's promise. Retrying is
      // appropriate only for that transition, never for user cancellation.
      if (
        ["browser_navigation_changed", "browser_not_loaded", "browser_failed"].some((code) =>
          String(error).includes(code),
        )
      ) {
        // The current host masks native bridge failures as browser_failed.
        // Its pinned QuickJS runtime installs setTimeout; use it only while
        // there is no ready document in which to run the normal page timer.
        await new Promise((resolve) => setTimeout(resolve, 500));
        continue;
      }
      throw error;
    }
    if (state?.ready && system !== "library") return state.data ?? {};
    if (system !== "library" || !state?.libraryOrigin) continue;
    let token = state.data?.token;
    if (!token && attempt % 10 === 0) {
      const cookies = await ctx.browser.cookies(`${LIBRARY}/find/loanInfo/loanList`);
      token = cookies.find((cookie) => cookie.name === "jwt" && typeof cookie.value === "string")?.value;
    }
    if (!token) continue;
    const groupCode = await ctx.browser.evaluate(libraryGroupCode, token);
    return { token, ...(groupCode ? { groupCode } : {}) };
  }
  throw new Error("xidian_login_timeout");
}

// Executed in the actual school page. No QuickJS closure variables are used.
export async function inspectLoginPage(system, delayMs) {
  if (delayMs) await new Promise((resolve) => setTimeout(resolve, delayMs));
  const url = new URL(location.href);
  if (url.protocol !== "https:" || document.querySelector("#pwdFromId")) return { ready: false };
  if (system === "ehall")
    return { ready: url.hostname === "ehall.xidian.edu.cn" && url.pathname.startsWith("/jwapp/"), data: {} };
  if (system === "yjspt")
    return { ready: url.hostname === "yjspt.xidian.edu.cn" && url.pathname.startsWith("/gsapp/"), data: {} };
  if (system === "card") {
    const openid = document.querySelector('input#openid[type="hidden"]')?.value;
    return {
      ready: url.hostname === "v8scan.xidian.edu.cn" && typeof openid === "string" && !!openid.trim(),
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
  return { libraryOrigin: true, ready: !!token, data: token ? { token } : {} };
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
