/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { termList } from "./academic.js";
import { createLogin } from "./login.js";
import { profileName } from "./profile.js";
import { forumSession } from "./ruisi.js";
import { requireParams, serviceError } from "./service_session.js";
import { readSession } from "./session.js";
import { establishAcademicSession } from "./webview_login.js";

export function createAccountSession(role) {
  return async (ctx, params = {}) => {
    requireParams(params, ["account", "operation"]);
    const { account, operation } = params;
    if (!["status", "login"].includes(operation)) throw serviceError("input_invalid_request");
    if (account === "apptunnel") {
      if (!ctx.appTunnel) throw serviceError("input_unavailable");
      return operation === "login"
        ? ctx.appTunnel.login("hermes-atrust", { accountId: "apptunnel" })
        : ctx.appTunnel.status("hermes-atrust");
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
    const schoolState = async (state, reason) => {
      if (ctx.accounts)
        await ctx.accounts.report("school", {
          status: state.status,
          reason:
            reason ??
            {
              authenticated: "verified",
              signedOut: "signedOut",
              expired: "primaryExpired",
              unknown: "networkUnknown",
            }[state.status],
        });
      return state;
    };
    if (operation === "login") await createLogin(role)(ctx, { forceLogin: true, passwordLogin: true });
    const system = role === "postgraduate" ? "yjspt" : "ehall";
    try {
      let saved = await readSession(ctx, system);
      const ids = await readSession(ctx, "ids");
      if (!saved?.cookies?.length && !ids?.cookies?.length) return schoolState({ status: "signedOut" });
      try {
        // Verify the actual service without the business query's login wrapper.
        await termList(ctx, { role });
      } catch (error) {
        if (error?.message !== `xidian_login_required_${system}`) throw error;
        if (!ids?.cookies?.length) return schoolState({ status: "unknown" }, "networkUnknown");
        // A rejected child ticket proves nothing about IDS. Exchange existing
        // SSO once and verify the business API; status never opens a browser or
        // retrieves/submits a saved password, including on older SDKs.
        await establishAcademicSession(ctx, system, { ...ids.data, role }, ctx.now() + 30000);
      }
      saved = await readSession(ctx, system);
      const id = saved?.data?.studentId;
      // Optional school-owned display metadata; never use an identifier as a
      // person's name, and never pass arbitrary account settings to the UI.
      const label = profileName(saved?.data?.accountLabel);
      return schoolState({
        status: "authenticated",
        ...(typeof id === "string" && id ? { accountId: id } : {}),
        ...(label ? { accountLabel: label } : {}),
        checkedAt: new Date(ctx.now()).toISOString(),
      });
    } catch (error) {
      const expired = error?.message === `xidian_login_required_${system}` && error.authStage === "primary";
      return schoolState({
        status: expired ? "expired" : "unknown",
        ...(expired ? { checkedAt: new Date(ctx.now()).toISOString() } : {}),
      });
    }
  };
}
