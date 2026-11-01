/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-052: one independently verified account per service in the current
// Profile/school. Namespace is addressing, not a same-school security sandbox.
import { cookieHeader, encodeForm, mergeCookies, parseSetCookie, parseUrl, resolveUrl } from "./session.js";

export function serviceError(code = "source_response_invalid") {
  const error = new Error(code);
  error.code = code;
  return error;
}
export function requireParams(params, allowed = []) {
  if (
    !params ||
    typeof params !== "object" ||
    Array.isArray(params) ||
    Object.keys(params).some((k) => !allowed.includes(k))
  )
    throw serviceError("input_invalid_request");
}
export function remoteId(value) {
  if (typeof value === "number" && !Number.isSafeInteger(value)) throw serviceError();
  const id = String(value ?? "");
  if (!/^[1-9][0-9]{0,39}$/.test(id)) throw serviceError();
  return id;
}
export async function serviceClient(ctx, config) {
  const address = { namespace: "xidian.services" };
  const record = await ctx.credentials.get(config.id, address);
  let saved = null;
  if (record) {
    try {
      saved = JSON.parse(record.value);
    } catch {
      throw serviceError();
    }
    if (
      saved.version !== 1 ||
      saved.serviceId !== config.id ||
      !Array.isArray(saved.cookies) ||
      !saved.accountId
    )
      throw serviceError();
  }
  const client = {
    cookies: saved?.cookies ?? [],
    accountId: saved?.accountId,
    accountLabel: saved?.accountLabel,
    state: () => ({
      serviceId: config.id,
      serviceName: config.name,
      status: client.accountId ? "authenticated" : "signedOut",
      ...(client.accountId ? { accountId: client.accountId, accountLabel: client.accountLabel ?? "" } : {}),
    }),
    async save(account) {
      client.accountId = remoteId(account.id);
      client.accountLabel = String(account.label || "").slice(0, 160);
      await ctx.credentials.set(
        config.id,
        JSON.stringify({
          version: 1,
          serviceId: config.id,
          accountId: client.accountId,
          accountLabel: client.accountLabel,
          cookies: client.cookies,
        }),
        { ...address, type: "cookie", scope: config.origins.map((o) => `${o}/*`), expiresAt: null },
      );
    },
    async logout() {
      await ctx.credentials.delete(config.id, address);
      client.cookies = [];
      client.accountId = undefined;
      client.accountLabel = undefined;
      return client.state();
    },
    async request(initialUrl, init = {}) {
      let url = initialUrl;
      const method = init.method || "GET";
      const body = init.body;
      let headers = { ...init.headers };
      for (let i = 0; i < 8; i++) {
        const target = parseUrl(url);
        if (!config.origins.includes(target.origin)) throw serviceError("network_denied");
        const cookie = cookieHeader(client, url, ctx.now());
        const response = await ctx.fetch(url, {
          method,
          ...(body === undefined ? {} : { body }),
          headers: { ...headers, ...(cookie ? { Cookie: cookie } : {}) },
          redirect: "manual",
        });
        const incoming = response.headers
          .getSetCookie()
          .map((v) => parseSetCookie(v, url, ctx.now()))
          .filter(Boolean);
        if (incoming.length) {
          client.cookies = mergeCookies(client.cookies, incoming).filter(
            (c) => c.expiresDate == null || c.expiresDate > ctx.now(),
          );
          if (client.accountId) await client.save({ id: client.accountId, label: client.accountLabel });
        }
        if (response.status < 300 || response.status >= 400) return response;
        // Never replay a submitted login/check-in body on a redirect.
        if (method !== "GET" || init.redirect === "error") throw serviceError();
        const location = response.headers.get("location");
        if (!location) throw serviceError();
        const next = resolveUrl(location, url);
        if (parseUrl(next).origin !== target.origin) headers = {};
        url = next;
      }
      throw serviceError();
    },
    async text(url, init) {
      const response = await client.request(url, init);
      if (!response.ok) throw serviceError();
      return response.text();
    },
    async json(url) {
      try {
        return JSON.parse(await client.text(url));
      } catch (e) {
        if (e.code) throw e;
        throw serviceError();
      }
    },
    async post(url, fields) {
      return client.text(url, {
        method: "POST",
        redirect: "error",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: encodeForm(fields),
      });
    },
  };
  return client;
}
