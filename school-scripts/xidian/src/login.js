// 🔒 Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// ADR-034 §3/§5, ADR-035 §2: installed school fixes the academic identity.
import { login as browserLogin, LOGIN_TARGETS } from "./browser_login.js";
import { readSession } from "./session.js";
import { establishAcademicSession, passwordLogin, webviewLogin } from "./webview_login.js";

export { LOGIN_TARGETS };

// ADR-068: a rejected child ticket does not imply expired primary credentials.
// This exchanges existing SSO only; it never submits a saved password or opens
// a hidden browser. Unexpected responses/cancellation must not trigger login.
export async function recoverAcademicSession(ctx, role, system) {
  if (
    !["undergraduate", "postgraduate"].includes(role) ||
    !["ehall", "yjspt"].includes(system) ||
    (role === "undergraduate" && system === "yjspt")
  )
    throw new Error("xidian_school_system_mismatch");
  const ids = await readSession(ctx, "ids");
  let primaryExpired = false;
  if (ids?.cookies?.length) {
    // Stored role metadata is not authority; the installed school determines
    // the target even when old session metadata is stale.
    try {
      await establishAcademicSession(ctx, system, { ...ids.data, role }, ctx.now() + 30000);
      return;
    } catch (error) {
      if (error?.message !== `xidian_login_required_${system}` || error.authStage !== "primary") throw error;
      primaryExpired = true;
    }
  }
  if (ctx.accounts) {
    const hasChild = (await readSession(ctx, system))?.cookies?.length > 0;
    await ctx.accounts.report(
      "school",
      primaryExpired
        ? { status: "expired", reason: "primaryExpired" }
        : hasChild
          ? { status: "unknown", reason: "networkUnknown" }
          : { status: "signedOut", reason: "signedOut" },
    );
    // SDK14 has no authorized hidden-browser presenter. Recovery must not
    // turn a normal query into a repeated password attempt or a login popup.
    const error = new Error(`xidian_login_required_${system}`);
    error.code = "authentication_required";
    throw error;
  }
  // Existing SDK 12 foreground browser gate remains authoritative. Background
  // execution fails at that gate; this helper does not grant interaction.
  await createLogin(role)(ctx, { system });
}

export function createLogin(role) {
  if (!["undergraduate", "postgraduate"].includes(role)) throw new Error("academic_role_invalid");
  return (ctx, params = {}) => {
    if (params.role != null && params.role !== role) throw new Error("xidian_school_role_mismatch");
    const requested = { "card-session": "card", "library-session": "library" }[params.requiredRef];
    const system = params.system ?? requested ?? (role === "postgraduate" ? "yjspt" : "ehall");
    if (!Object.hasOwn(LOGIN_TARGETS, system)) throw new Error("xidian_login_system_invalid");
    if (role === "undergraduate" && system === "yjspt") throw new Error("xidian_school_system_mismatch");
    return ["ehall", "yjspt"].includes(system)
      ? (params.passwordLogin && ctx.accounts ? passwordLogin : webviewLogin)(
          ctx,
          { ...params, system },
          role,
        )
      : browserLogin(ctx, { ...params, system }, role);
  };
}
export const capabilities = { "generic.section": createLogin("undergraduate") };
