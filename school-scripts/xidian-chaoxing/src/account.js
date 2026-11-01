/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

import { remoteId, requireParams, serviceClient, serviceError } from "../../xidian/src/service_session.js";
import { browserCookiesForUrl, replaceBrowserCookiesForUrl } from "../../xidian/src/session.js";

export const ACCOUNT_URL = "https://learn.chaoxing.com/apis/user/getUserImToken";
export const MOBILE = "https://mobilelearn.chaoxing.com";
export const ORIGINS = [
  "https://passport2.chaoxing.com",
  "https://learn.chaoxing.com",
  MOBILE,
  "https://sso.chaoxing.com",
  "https://i.chaoxing.com",
  "https://learning.xidian.edu.cn",
  "https://ids.xidian.edu.cn",
];
const config = { id: "chaoxing", name: "学习通", origins: ORIGINS };
const cookieUrls = [
  ACCOUNT_URL,
  ...[
    "/v2/apis/sign/getAttendInfo",
    "/v2/apis/active/getPPTActiveInfo",
    "/v2/apis/class/getClassDetail",
    "/pptSign/stuSignajax",
    "/newsign/preSign",
    "/pptSign/analysis",
    "/pptSign/analysis2",
    "/ppt/renwuAPI/getActive",
  ].map((path) => MOBILE + path),
];

export async function probe(client) {
  const value = await client.json(ACCOUNT_URL);
  const data = value?.msg;
  if (!data || data.puid === 0 || data.puid === "0" || data.uid === 0 || data.uid === "0") return null;
  const account = {
    id: remoteId(data.puid),
    tid: remoteId(data.uid),
    fid: remoteId(data.fid),
    label: String(data.name ?? "").slice(0, 160),
  };
  if (typeof data.hxToken !== "string" || !data.hxToken || data.hxToken.length > 4096) throw serviceError();
  return { ...account, token: data.hxToken };
}

export async function chaoxingClient(ctx, { login = false } = {}) {
  const client = await serviceClient(ctx, config);
  if (client.accountId && !login) {
    const account = await probe(client);
    if (!account || account.id !== client.accountId) {
      await client.logout();
      throw serviceError("authentication_required");
    }
    await client.save(account);
    return { client, account };
  }
  if (!login) throw serviceError("authentication_required");
  if (!ctx.browser) throw serviceError("input_unavailable");
  // Browser context is cleared by the host lease. Do not restore the previous
  // account when the user explicitly requests a fresh login.
  client.cookies = [];
  client.accountId = undefined;
  for (const url of cookieUrls)
    await ctx.browser.setCookies(url, browserCookiesForUrl(client, url, ctx.now()));
  await ctx.browser.open(
    "https://passport2.chaoxing.com/login?newversion=true&refer=" + encodeURIComponent(ACCOUNT_URL),
  );
  for (let i = 0; i < 90; i++) {
    let ready;
    try {
      ready = await ctx.browser.evaluate(async () => {
        await new Promise((resolve) => setTimeout(resolve, 750));
        // This is the redirect target chosen by the script. A login-looking URL
        // or arbitrary cookie is not authentication evidence.
        if (location.origin !== "https://learn.chaoxing.com") return false;
        try {
          const r = await fetch("/apis/user/getUserImToken", { credentials: "same-origin" });
          if (!r.ok || r.redirected) return false;
          const v = await r.json();
          return !!v?.msg?.puid && !!v?.msg?.uid && !!v?.msg?.hxToken;
        } catch {
          return false;
        }
      });
    } catch (e) {
      if (!/browser_navigation_changed|browser_not_loaded/.test(String(e))) throw e;
      continue;
    }
    if (!ready) continue;
    for (const url of cookieUrls)
      client.cookies = replaceBrowserCookiesForUrl(client.cookies, url, await ctx.browser.cookies(url));
    const account = await probe(client);
    if (!account) continue;
    await client.save(account);
    return { client, account };
  }
  throw serviceError("authentication_timeout");
}

export async function messagesSession(ctx, params = {}) {
  requireParams(params, ["operation"]);
  const operation = params.operation ?? "status";
  if (!["status", "login", "logout"].includes(operation)) throw serviceError("input_invalid_request");
  if (operation === "login") return (await chaoxingClient(ctx, { login: true })).client.state();
  const client = await serviceClient(ctx, config);
  if (operation === "logout") return client.logout();
  if (!client.accountId) return client.state();
  const account = await probe(client);
  if (!account || account.id !== client.accountId) return client.logout();
  await client.save(account);
  return client.state();
}
