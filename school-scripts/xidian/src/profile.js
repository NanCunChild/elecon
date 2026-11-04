/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { requireParams } from "./service_session.js";
import { readSession } from "./session.js";

export function profileName(value) {
  return typeof value === "string" &&
    value.trim() &&
    value.length <= 160 &&
    // biome-ignore lint/suspicious/noControlCharactersInRegex: reject control characters in display metadata.
    !/[\u0000-\u001f\u007f]/.test(value)
    ? value.trim()
    : undefined;
}

// Existing profile.me contract. An absent source name stays absent: account
// IDs, user-entered login names and role labels are not a person's name.
export function createProfile(role) {
  if (!["undergraduate", "postgraduate"].includes(role)) throw new Error("academic_role_invalid");
  return async (ctx, params = {}) => {
    requireParams(params);
    const service = role === "postgraduate" ? "yjspt" : "ehall";
    const session = await readSession(ctx, service);
    const primary = await readSession(ctx, "ids");
    const name = profileName(session?.data?.accountLabel) ?? profileName(primary?.data?.accountLabel);
    return name ? { name } : {};
  };
}
