/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// A platform protocol string, never a claim about physical device identity.
// Reuse the independently implemented AES block primitive in the school package.
import { aes128Cbc, utf8 } from "../../xidian/src/energy_crypto.js";
import { md5 } from "../../xidian/src/md5.js";
export function clientIdentity(accountId) {
  const clientId = md5(accountId);
  const padded = [...utf8(clientId), ...Array(16).fill(16)];
  const encrypted = [];
  for (let i = 0; i < padded.length; i += 16) {
    // With zero IV the first CBC block is the AES block permutation. Ignore
    // its appended padding block; ECB's padding was applied above exactly once.
    encrypted.push(
      ...aes128Cbc(padded.slice(i, i + 16), utf8("QrCbNY@MuK1X8HGw"), Array(16).fill(0)).slice(0, 16),
    );
  }
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let deviceCode = "";
  for (let i = 0; i < encrypted.length; i += 3) {
    const word = encrypted[i] * 65536 + (encrypted[i + 1] ?? 0) * 256 + (encrypted[i + 2] ?? 0);
    deviceCode +=
      alphabet[word >>> 18] +
      alphabet[(word >>> 12) & 63] +
      (i + 1 < encrypted.length ? alphabet[(word >>> 6) & 63] : "=") +
      (i + 2 < encrypted.length ? alphabet[word & 63] : "=");
  }
  return { clientId, deviceCode };
}
