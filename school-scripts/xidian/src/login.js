// 🔒 Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// ADR-034 §3/§5, ADR-035 §2: installed school fixes the academic identity.
import { login as browserLogin, LOGIN_TARGETS } from "./browser_login.js";
import { webviewLogin } from "./webview_login.js";

export { LOGIN_TARGETS };
export function createLogin(role) {
  if (!["undergraduate", "postgraduate"].includes(role)) throw new Error("academic_role_invalid");
  return (ctx, params = {}) => {
    if (params.role != null && params.role !== role) throw new Error("xidian_school_role_mismatch");
    const requested = { "card-session": "card", "library-session": "library" }[params.requiredRef];
    const system = params.system ?? requested ?? (role === "postgraduate" ? "yjspt" : "ehall");
    if (!Object.hasOwn(LOGIN_TARGETS, system)) throw new Error("xidian_login_system_invalid");
    if (role === "undergraduate" && system === "yjspt") throw new Error("xidian_school_system_mismatch");
    return ["ehall", "yjspt"].includes(system)
      ? webviewLogin(ctx, { ...params, system }, role)
      : browserLogin(ctx, { ...params, system }, role);
  };
}
export const capabilities = { "generic.section": createLogin("undergraduate") };
