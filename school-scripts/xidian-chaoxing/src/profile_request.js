/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// Public client wire constants, not an IM token, password or device identifier.
// Independently implemented from the request protocol recorded in research/.
import { md5 } from "../../xidian/src/md5.js";

const endpoint = "https://useryd.chaoxing.com/apis/user/getUsers4C";
const clientToken = "4faa8662c59590c6f43ae9fe5b002b42";
const wireSalt = "Z(AfY@XS";

function requestNonce() {
  // A transient UUIDv4-shaped request nonce. It grants no authentication and
  // never represents a physical device or a persistent client identifier.
  return "xxxxxxxxxxxx4xxxyxxxxxxxxxxxxxxx".replace(/[xy]/g, (kind) => {
    const value = Math.floor(Math.random() * 16);
    return (kind === "x" ? value : (value & 3) | 8).toString(16);
  });
}

export function profileRequestUrl(now, nonce = requestNonce()) {
  if (!Number.isSafeInteger(now) || now < 0 || !/^[0-9a-f]{32}$/.test(nonce))
    throw new Error("invalid_profile_request");
  const query = `_c_0_=${nonce}&token=${clientToken}&_time=${now}`;
  const signature = md5(`${query}&DESKey=${wireSalt}`);
  return `${endpoint}?${query}&inf_enc=${signature}`;
}
