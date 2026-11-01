/*! Ruisi form protocol adapted from traintime_pda/lib/external/ruisi_flutter.
 * Copyright 2026 BenderBlog Rodriguez and Contributors.
 * Copyright 2026 elecon contributors. SPDX-License-Identifier: BSD-3-Clause
 *
 * BSD 3-Clause License
 *
 * Copyright (c) 2026, BenderBlog Rodriguez
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
import { getAttributeValue, getText, parseDocument, selectAll } from "elecon:html";
import { md5 } from "./md5.js";
import { requireParams, serviceClient, serviceError } from "./service_session.js";
import { browserCookiesForUrl, replaceBrowserCookiesForUrl } from "./session.js";

const ORIGIN = "https://rs.xidian.edu.cn";
const LOGIN = `${ORIGIN}/member.php?mod=logging&action=login`;
const SPACE = `${ORIGIN}/home.php?mod=space`;
const config = { id: "xidian.ruisi", name: "睿思学术论坛", origins: [ORIGIN] };

export function ruisiAccount(html) {
  const doc = parseDocument(html);
  // Only the current-user header paired with a logout control is evidence.
  // Arbitrary uid links in posts/friends must never identify the logged-in user.
  if (!selectAll('a[href*="action=logout"]', doc).length) return null;
  for (const node of selectAll('#um .vwmy a, #um a[href*="mod=space"], #um a[href*="space-uid-"]', doc)) {
    const href = getAttributeValue(node, "href") || "";
    const id = /(?:[?&]uid=|space-uid-)([1-9][0-9]*)/.exec(href)?.[1];
    if (id) return { id, label: getText(node).trim().slice(0, 160) };
  }
  return null;
}

async function browserLogin(ctx, client) {
  if (!ctx.browser) throw serviceError("input_unavailable");
  await ctx.browser.setCookies(SPACE, browserCookiesForUrl(client, SPACE, ctx.now()));
  await ctx.browser.open(LOGIN);
  for (let i = 0; i < 100; i++) {
    let html;
    try {
      html = await ctx.browser.evaluate(async () => {
        await new Promise((resolve) => setTimeout(resolve, 750));
        if (
          location.origin !== "https://rs.xidian.edu.cn" ||
          !document.querySelector('a[href*="action=logout"]')
        )
          return null;
        return document.documentElement.outerHTML;
      });
    } catch (e) {
      if (!/browser_navigation_changed|browser_not_loaded/.test(String(e))) throw e;
      // Navigation rejects evaluate before its in-page timer can run. Yield in
      // the script too, otherwise a redirect consumes every retry immediately.
      await new Promise((resolve) => setTimeout(resolve, 250));
      continue;
    }
    if (typeof html !== "string" || !ruisiAccount(html)) continue;
    client.cookies = replaceBrowserCookiesForUrl(client.cookies, SPACE, await ctx.browser.cookies(SPACE));
    const account = ruisiAccount(await client.text(SPACE));
    if (!account) continue;
    await client.save(account);
    return client.state();
  }
  throw serviceError("authentication_timeout");
}

export async function forumSession(ctx, params = {}) {
  requireParams(params, ["operation"]);
  const operation = params.operation ?? "status";
  if (!["status", "login", "logout"].includes(operation)) throw serviceError("input_invalid_request");
  const client = await serviceClient(ctx, config);
  if (operation === "logout") return client.logout();
  if (operation === "status") {
    if (!client.accountId) return client.state();
    const account = ruisiAccount(await client.text(SPACE));
    if (!account) return client.logout();
    await client.save(account);
    return client.state();
  }
  // Explicit login starts a fresh platform jar; it does not reuse school SSO.
  // The old stored session survives cancellation until a new account verifies.
  client.cookies = [];
  client.accountId = undefined;
  const html = await client.text(LOGIN);
  const doc = parseDocument(html);
  if (selectAll('input[name="seccodehash"]', doc).length || /updateseccode\(/.test(html))
    return browserLogin(ctx, client);
  const hashNode = selectAll('input[name="formhash"]', doc)[0];
  const form = selectAll('form[id^="loginform_"]', doc)[0];
  const formhash = hashNode && getAttributeValue(hashNode, "value");
  const loginhash = /[?&]loginhash=(\w+)/.exec(form ? getAttributeValue(form, "action") || "" : "")?.[1];
  if (!formhash || !loginhash) throw serviceError();
  const input = await ctx.ui.requestInput({
    title: "登录睿思",
    message: "请输入睿思论坛账号，与学校统一认证账号分别保存。",
    fields: [
      { id: "username", label: "睿思用户名", maxLength: 80 },
      { id: "password", label: "睿思密码", type: "password", maxLength: 256 },
    ],
  });
  if (!input) throw serviceError("input_cancelled");
  const result = await client.post(
    `${LOGIN}&loginsubmit=yes&loginhash=${encodeURIComponent(loginhash)}&inajax=1`,
    {
      formhash,
      referer: `${ORIGIN}/`,
      loginfield: "username",
      username: input.username,
      password: md5(input.password),
      questionid: "0",
      answer: "",
      cookietime: "2592000",
    },
  );
  if (/验证码|seccode/.test(result)) return browserLogin(ctx, client);
  if (!result.includes("欢迎您回来")) throw serviceError("authentication_required");
  const account = ruisiAccount(await client.text(SPACE));
  if (!account) throw serviceError("authentication_required");
  await client.save(account);
  return client.state();
}
