/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { termList } from "./academic.js";
import { createLogin } from "./login.js";
import { forumSession } from "./ruisi.js";
import { requireParams, serviceError } from "./service_session.js";
import { readSession } from "./session.js";

export function createAccountSession(role) {
  return async (ctx, params = {}) => {
    requireParams(params, ["account", "operation"]);
    const { account, operation } = params;
    if (!["status", "login"].includes(operation)) throw serviceError("input_invalid_request");
    if (account === "apptunnel") {
      if (!ctx.appTunnel) throw serviceError("input_unavailable");
      return ctx.appTunnel[operation]("hermes-atrust");
    }
    if (account === "ruisi") {
      const address = { namespace: "xidian.services" };
      const saved = await ctx.credentials.get("ruisi", address);
      try {
        const state = await forumSession(ctx, { operation });
        if (state.status === "authenticated") {
          await ctx.credentials.delete("ruisi-expired", address);
          return {
            status: "authenticated",
            accountId: state.accountId,
            ...(state.accountLabel ? { accountLabel: state.accountLabel } : {}),
            checkedAt: new Date(ctx.now()).toISOString(),
          };
        }
        if (saved) await ctx.credentials.set("ruisi-expired", "true", address);
        return {
          status: saved || (await ctx.credentials.get("ruisi-expired", address)) ? "expired" : "signedOut",
          ...(saved ? { checkedAt: new Date(ctx.now()).toISOString() } : {}),
        };
      } catch (error) {
        if (operation === "login") throw error;
        return { status: "unknown" };
      }
    }
    if (account !== "school") throw serviceError("input_invalid_request");
    if (operation === "login") await createLogin(role)(ctx, { forceLogin: true });
    const system = role === "postgraduate" ? "yjspt" : "ehall";
    const saved = await readSession(ctx, system);
    if (!saved?.cookies?.length) return { status: "signedOut" };
    try {
      // Deliberately bypass automatic login used by business queries.
      await termList(ctx, { role });
      const id = saved.data?.studentId;
      return {
        status: "authenticated",
        ...(typeof id === "string" && id ? { accountId: id } : {}),
        checkedAt: new Date(ctx.now()).toISOString(),
      };
    } catch (error) {
      const expired = /^xidian_login_required_(ehall|yjspt)$/.test(error?.message ?? "");
      return {
        status: expired ? "expired" : "unknown",
        ...(expired ? { checkedAt: new Date(ctx.now()).toISOString() } : {}),
      };
    }
  };
}
