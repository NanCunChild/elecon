// 🔒 Copyright 2023-2026 Traintime PDA authors; 2026 elecon contributors.
// SPDX-License-Identifier: MPL-2.0
// Adapted from ids_session.dart, ids_reauth_client.dart, semester_session.dart.
// ADR-034 §3/§5, ADR-035 §2/§3, redlines #1/#3/#5: current identity, direct HTTP,
// bounded trusted SDK only. Browser UI is an input surface, not the cookie jar.
import { getAttributeValue, parseDocument, selectAll } from "elecon:html";
import { failure } from "./errors.js";
import { IDS_LOGIN, IDS_ORIGIN, PDA_TARGETS, PDA_UA } from "./pda_constants.js";
import { clearPdaInput, encryptPda, pollPdaInput, preparePdaInput, renderPdaInput } from "./pda_ui.js";
import {
  cookieHeader,
  encodeForm,
  mergeCookies,
  parseSetCookie,
  parseUrl,
  readSession,
  resolveUrl,
  saveSession,
} from "./session.js";

const reauthPath = "/authserver/reAuthCheck/reAuthLoginView.do";
const redirectStatuses = new Set([301, 302, 303, 307, 308]);

export function passwordFields(html) {
  const forms = selectAll("form#pwdFromId", parseDocument(html));
  if (forms.length !== 1) throw failure("xidian_ids_form_invalid");
  const inputs = selectAll('input[type="hidden"]', forms[0]);
  const fields = {};
  for (const name of ["pwdEncryptSalt", "lt", "execution"]) {
    const matches = inputs.filter(
      (node) => getAttributeValue(node, "id") === name || getAttributeValue(node, "name") === name,
    );
    const value = matches.length === 1 ? getAttributeValue(matches[0], "value") : null;
    if (typeof value !== "string" || (name !== "lt" && !value.trim()))
      throw failure("xidian_ids_form_invalid");
    fields[name] = value;
  }
  return fields;
}

function continuation(html) {
  const forms = selectAll("form#continue", parseDocument(html));
  if (!forms.length) return null;
  if (forms.length !== 1) throw failure("xidian_ids_continue_invalid");
  const fields = {};
  for (const node of selectAll("input", forms[0])) {
    const name = getAttributeValue(node, "name");
    if (!name || Object.hasOwn(fields, name)) throw failure("xidian_ids_continue_invalid");
    fields[name] = getAttributeValue(node, "value") ?? "";
  }
  if (!Object.keys(fields).length) throw failure("xidian_ids_continue_invalid");
  return fields;
}

function query(url, name) {
  for (const pair of parseUrl(url).query.slice(1).split("&")) {
    const [key, ...value] = pair.split("=");
    if (decodeURIComponent(key) === name) return decodeURIComponent(value.join("=").replace(/\+/g, " "));
  }
  return null;
}

export async function pdaLogin(ctx, params, role) {
  const system = params.system;
  const target = PDA_TARGETS[system];
  if (!target) throw failure("xidian_login_system_invalid");
  const previousIds = await readSession(ctx, "ids");
  const previous = await readSession(ctx, system);
  // ADR-035 §3: reuse verified IDS SSO, but do not seed the new native business
  // exchange with WebView-specific cookies from the failed 0.8.x flow.
  let jar = mergeCookies(
    previous?.data?.authFlow === "pda" ? previous.cookies : [],
    previousIds?.cookies || [],
  );
  let username = previousIds?.data?.studentId || "";
  let inputOpened = false;
  let polls = 0;
  let requests = 0;
  const deadline = ctx.now() + 110000;
  let fingerprint = previousIds?.data?.browserFingerprint;
  let verifiedMetadata = null;
  const log = (stage) => ctx.log?.("info", `xidian_pda:${stage}`);
  function active() {
    if (ctx.now() >= deadline) throw failure("xidian_login_timeout");
  }
  function permitted(url) {
    const parsed = parseUrl(url);
    // PDA upgrades Location to HTTPS; apply only in this protocol client.
    const secured = url.replace(/^http:/, "https:");
    if (![IDS_ORIGIN, target.origin].includes(parseUrl(secured).origin))
      throw failure("xidian_redirect_origin_denied");
    return parsed.hash ? secured.slice(0, secured.indexOf("#")) : secured;
  }
  async function request(rawUrl, fields, xhr = false) {
    active();
    if (++requests > 40) throw failure("xidian_pda_request_limit");
    const url = permitted(rawUrl);
    const headers = { "User-Agent": PDA_UA };
    const cookie = cookieHeader({ cookies: jar }, url, ctx.now());
    if (cookie) headers.Cookie = cookie;
    if (fields != null) headers["Content-Type"] = "application/x-www-form-urlencoded";
    if (xhr) {
      headers.Accept = "application/json, text/javascript, */*; q=0.01";
      headers["X-Requested-With"] = "XMLHttpRequest";
      headers.Origin = IDS_ORIGIN;
    }
    const response = await ctx.fetch(url, {
      method: fields == null ? "GET" : "POST",
      headers,
      ...(fields == null ? {} : { body: encodeForm(fields) }),
      redirect: "manual",
    });
    const received = response.headers
      .getSetCookie()
      .map((line) => parseSetCookie(line, url, ctx.now()))
      .filter(Boolean);
    jar = mergeCookies(jar, received);
    jar = jar.filter((cookie) => cookie.expiresDate == null || cookie.expiresDate > ctx.now());
    // ADR-035 §3: retain verified IDS rotations even if the target later fails.
    if (verifiedMetadata && parseUrl(url).origin === IDS_ORIGIN && received.length) {
      await saveSession(ctx, "ids", {
        version: 1,
        service: "ids",
        cookies: jar.filter((c) => c.domain === "ids.xidian.edu.cn"),
        data: verifiedMetadata,
      });
    }
    if (response.status === 401) throw failure("xidian_ids_password_rejected");
    if (response.status < 200 || response.status >= 400) throw failure("xidian_pda_http_failed");
    return { response, url };
  }
  const location = (result) => {
    const value = result.response.headers.get("location");
    return redirectStatuses.has(result.response.status) && value
      ? permitted(resolveUrl(value, result.url))
      : null;
  };
  async function json(url, fields, xhr = false) {
    const result = await request(url, fields, xhr);
    if (location(result)) throw failure("xidian_pda_unexpected_redirect");
    try {
      return await result.response.json();
    } catch {
      throw failure("xidian_pda_non_json_response");
    }
  }
  async function openInput() {
    if (!ctx.browser) throw failure("xidian_login_browser_required");
    if (inputOpened) return;
    await ctx.browser.open(IDS_LOGIN);
    inputOpened = true;
  }
  async function bfp() {
    if (!/^[A-F0-9]{32}$/.test(fingerprint || "")) {
      await openInput();
      fingerprint = await ctx.browser.evaluate(preparePdaInput);
      if (!/^[A-F0-9]{32}$/.test(fingerprint)) throw failure("xidian_ids_fingerprint_invalid");
    }
    await request(`${IDS_ORIGIN}/authserver/bfp/info?bfp=${fingerprint}&_=${ctx.now()}`);
    // ADR-035 §3: fingerprint metadata alone must not create a credential or
    // make an unfinished primary login appear successful in the host UI.
    if (verifiedMetadata) {
      verifiedMetadata.browserFingerprint = fingerprint;
      await saveSession(ctx, "ids", {
        version: 1,
        service: "ids",
        cookies: jar.filter((c) => c.domain === "ids.xidian.edu.cn"),
        data: verifiedMetadata,
      });
    }
  }
  async function input(options) {
    active();
    await openInput();
    await ctx.browser.evaluate(renderPdaInput, options);
    while (++polls <= 135) {
      active();
      const value = await ctx.browser.evaluate(pollPdaInput);
      if (!value) continue;
      if (value.cancelled) throw failure("script_cancelled");
      return value;
    }
    throw failure("xidian_login_timeout");
  }
  async function completeMfa(challenge, service) {
    log("mfa");
    const page = await request(challenge);
    const html = await page.response.text();
    const deliveryUser = /"reAuthUserId"\s*:\s*"([^"\\]+)"/.exec(html)?.[1] || username;
    if (!deliveryUser) throw failure("xidian_ids_mfa_user_missing");
    await bfp();
    const choice = await input({ kind: "method" });
    if (!["3", "4"].includes(choice.type)) throw failure("xidian_ids_mfa_type_invalid");
    const common = {
      service: service || "",
      reAuthType: choice.type,
      isMultifactor: query(challenge, "isMultifactor") || "true",
    };
    const prepared = await json(`${IDS_ORIGIN}/authserver/reAuthCheck/changeReAuthType.do`, common);
    if (String(prepared?.code) !== "1") throw failure("xidian_ids_mfa_prepare_failed");
    const sent = await json(`${IDS_ORIGIN}/authserver/dynamicCode/getDynamicCodeByReauth.do`, {
      userName: deliveryUser,
      authCodeTypeName: choice.type === "3" ? "reAuthDynamicCodeType" : "reAuthWChatDynamicCodeType",
    });
    if (!["success", "other_success", "wechat_success", "code_time_fail"].includes(sent?.res))
      throw failure("xidian_ids_mfa_delivery_failed");
    for (let attempt = 0; attempt < 3; attempt++) {
      const value = await input({
        kind: "code",
        ...(attempt ? { message: "验证码未通过，请重新输入。" } : {}),
      });
      if (typeof value.code !== "string" || !value.code.trim() || value.code.length > 128)
        throw failure("xidian_ids_mfa_code_invalid");
      const submitted = await json(`${IDS_ORIGIN}/authserver/reAuthCheck/reAuthSubmit.do`, {
        ...common,
        password: "",
        dynamicCode: value.code.trim(),
        uuid: "",
        answer1: "",
        answer2: "",
        otpCode: "",
        skipTmpReAuth: String(value.trustDevice === true),
      });
      value.code = "";
      if (submitted?.code === "reAuth_failed") continue;
      if (submitted?.code !== "reAuth_success") throw failure("xidian_ids_mfa_expired");
      // PDA re-signs the service ticket after MFA; never reuse its old ticket.
      const signed = await request(
        service ? `${IDS_LOGIN}?service=${encodeURIComponent(service)}` : IDS_LOGIN,
      );
      const next = location(signed);
      if (!next || parseUrl(next).path === reauthPath) throw failure("xidian_ids_mfa_incomplete");
      return next;
    }
    throw failure("xidian_ids_mfa_code_rejected");
  }
  async function signedLocation(result, service) {
    let next = location(result);
    if (!next && result.response.status === 200) {
      const fields = continuation(await result.response.text());
      if (fields) next = location(await request(IDS_LOGIN, fields));
    }
    if (!next) throw failure("xidian_ids_login_rejected");
    if (parseUrl(next).origin === IDS_ORIGIN && parseUrl(next).path === reauthPath)
      next = await completeMfa(next, service);
    return next;
  }
  async function follow(first, service) {
    let next = first;
    for (let hop = 0; hop < 30; hop++) {
      const parsed = parseUrl(next);
      if (parsed.origin === IDS_ORIGIN && parsed.path === "/authserver/login") {
        const requestedService = query(next, "service");
        if (requestedService) {
          permitted(requestedService);
          service = requestedService;
        }
      }
      if (parsed.origin === IDS_ORIGIN && parsed.path === reauthPath) {
        next = await completeMfa(next, service);
        continue;
      }
      const result = await request(next);
      const redirect = location(result);
      if (!redirect) return result;
      next = redirect;
    }
    throw failure("xidian_redirect_limit");
  }
  try {
    log("ids_start");
    let first = await request(IDS_LOGIN);
    if (!location(first)) {
      const html = await first.response.text();
      const continued = continuation(html);
      if (continued) first = await request(IDS_LOGIN, continued);
      else {
        const fields = passwordFields(html);
        const value = await input({
          kind: "credentials",
          username: params.studentId || params.account || username,
        });
        if (
          typeof value.username !== "string" ||
          !value.username.trim() ||
          value.username.length > 128 ||
          typeof value.password !== "string" ||
          !value.password ||
          value.password.length > 1024
        )
          throw failure("xidian_ids_input_invalid");
        username = value.username.trim();
        let encrypted;
        try {
          encrypted = await ctx.browser.evaluate(encryptPda, {
            text: value.password,
            salt: fields.pwdEncryptSalt,
          });
        } finally {
          value.password = "";
        }
        await bfp();
        log("captcha");
        const captchaUrl = () => `${IDS_ORIGIN}/authserver/common/openSliderCaptcha.htl?_=${ctx.now()}`;
        // PDA primes the endpoint before its provider fetches a fresh puzzle.
        await request(captchaUrl());
        let solved = false;
        for (let attempt = 0; attempt < 3; attempt++) {
          const puzzle = await json(captchaUrl());
          if (
            ![puzzle?.bigImage, puzzle?.smallImage].every(
              (s) =>
                typeof s === "string" &&
                s.length >= 24 &&
                s.length < 120000 &&
                /^[A-Za-z0-9+/]+={0,2}$/.test(s),
            )
          )
            throw failure("xidian_ids_captcha_invalid");
          const value = await input({
            kind: "captcha",
            bigImage: puzzle.bigImage,
            smallImage: puzzle.smallImage,
          });
          const tracks = value.tracks;
          if (
            !Array.isArray(tracks) ||
            tracks.length < 2 ||
            tracks.length > 502 ||
            tracks.some(
              (p) =>
                ![p.a, p.b, p.c].every(Number.isInteger) ||
                p.a < 0 ||
                p.a > 280 ||
                Math.abs(p.b) > 2000 ||
                p.c < 0 ||
                p.c > 110000,
            )
          )
            throw failure("xidian_ids_captcha_tracks_invalid");
          const sign = await ctx.browser.evaluate(encryptPda, {
            text: JSON.stringify({ canvasLength: 280, moveLength: tracks[tracks.length - 1].a, tracks }),
            sliderKey: puzzle.smallImage,
          });
          const verified = await json(
            `${IDS_ORIGIN}/authserver/common/verifySliderCaptcha.htl`,
            { sign },
            true,
          );
          if (Number(verified?.errorCode) === 1) {
            solved = true;
            break;
          }
        }
        if (!solved) throw failure("xidian_ids_captcha_rejected");
        first = await request(IDS_LOGIN, {
          username,
          password: encrypted,
          rememberMe: "true",
          cllt: "userNameLogin",
          dllt: "generalLogin",
          _eventId: "submit",
          lt: fields.lt,
          execution: fields.execution,
        });
        encrypted = null;
      }
    }
    const globalLocation = await signedLocation(first, null);
    const globalUrl = parseUrl(globalLocation);
    // A service cookie/HTML landing alone never establishes global IDS SSO.
    if (
      globalUrl.origin !== IDS_ORIGIN ||
      !/^\/(authserver\/index\.do|personalInfo\/)/.test(globalUrl.path) ||
      !cookieHeader({ cookies: jar }, IDS_LOGIN, ctx.now())
        .split(/;\s*/)
        .some((c) => c.startsWith("CASTGC="))
    )
      throw failure("xidian_ids_global_session_missing");
    const metadata = {
      role,
      authFlow: "pda",
      ...(username ? { studentId: username } : {}),
      ...(/^[A-F0-9]{32}$/.test(fingerprint || "") ? { browserFingerprint: fingerprint } : {}),
    };
    verifiedMetadata = metadata;
    await saveSession(ctx, "ids", {
      version: 1,
      service: "ids",
      cookies: jar.filter((c) => c.domain === "ids.xidian.edu.cn"),
      data: metadata,
    });
    log("ids_saved");
    const ticket = await request(`${IDS_LOGIN}?service=${encodeURIComponent(target.service)}`);
    const serviceLocation = await signedLocation(ticket, target.service);
    const landed = await follow(serviceLocation, target.service);
    if (parseUrl(landed.url).origin !== target.origin) throw failure("xidian_pda_business_landing_invalid");
    log("business_probe");
    const probe = await json(target.probe, {});
    const term = system === "ehall" ? probe?.datas?.dqxnxq?.rows?.[0]?.DM : probe?.data?.xnxqdm;
    if (String(probe?.code) !== "0" || typeof term !== "string" || !/^\d{4}-\d{4}-[123]$/.test(term))
      throw failure("xidian_pda_business_probe_failed");
    await saveSession(ctx, "ids", {
      version: 1,
      service: "ids",
      cookies: jar.filter((c) => c.domain === "ids.xidian.edu.cn"),
      data: metadata,
    });
    await saveSession(ctx, system, {
      version: 1,
      service: system,
      cookies: jar.filter((c) => c.domain === parseUrl(target.origin).host),
      data: { ...metadata, origin: target.origin, currentTerm: term },
    });
    log("business_saved");
    return {
      sectionId: "xidian.login",
      title: "西电登录会话",
      fields: [
        { label: "系统", role: "label", value: system },
        { label: "状态", role: "status", value: "已验证并保存会话" },
      ],
    };
  } finally {
    if (inputOpened) {
      try {
        await ctx.browser.evaluate(clearPdaInput);
      } catch {
        /* browser may have been cancelled */
      }
    }
  }
}
