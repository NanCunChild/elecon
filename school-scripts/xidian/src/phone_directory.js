/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
import { phoneDirectoryData } from "./phone_directory_data.js";

// Read-only public data: no credentials, authentication, browser, or network.
export async function phoneDirectory(_ctx, params = {}) {
  if (!params || typeof params !== "object" || Array.isArray(params) || Object.keys(params).length) {
    throw new Error("invalid_params");
  }
  // A caller cannot mutate the module's data and affect subsequent requests.
  return { ...phoneDirectoryData, items: phoneDirectoryData.items.map((item) => ({ ...item })) };
}
