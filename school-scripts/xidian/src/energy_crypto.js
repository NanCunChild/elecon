/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
 * ADR-040 §2: school wire encoding only; no native crypto or new dependency.
 * AES-128 CBC / PKCS7 follows FIPS 197; independently tested with Node/OpenSSL.
 */
const mul = (a, b) => {
  let result = 0;
  for (; b; b >>= 1, a = ((a << 1) ^ (a & 128 ? 0x11b : 0)) & 255) if (b & 1) result ^= a;
  return result;
};
const sbox = Array.from({ length: 256 }, (_, value) => {
  let inverse = value ? 1 : 0;
  for (let n = 0; n < 254 && value; n++) inverse = mul(inverse, value);
  const rotate = (n) => ((inverse << n) | (inverse >>> (8 - n))) & 255;
  return inverse ^ rotate(1) ^ rotate(2) ^ rotate(3) ^ rotate(4) ^ 0x63;
});

export function aes128Cbc(bytes, key, iv) {
  if (key.length !== 16 || iv.length !== 16) throw new Error("energy_crypto_key_invalid");
  const expanded = Array.from(key);
  let rcon = 1;
  for (let offset = 16; offset < 176; offset += 4) {
    let word = expanded.slice(offset - 4, offset);
    if (offset % 16 === 0) {
      word = [sbox[word[1]] ^ rcon, sbox[word[2]], sbox[word[3]], sbox[word[0]]];
      rcon = mul(rcon, 2);
    }
    for (let n = 0; n < 4; n++) expanded.push(expanded[offset + n - 16] ^ word[n]);
  }
  const padded = Array.from(bytes),
    padding = 16 - (bytes.length % 16);
  padded.push(...Array(padding).fill(padding));
  const output = [];
  let previous = Array.from(iv);
  for (let offset = 0; offset < padded.length; offset += 16) {
    let state = padded.slice(offset, offset + 16).map((value, n) => value ^ previous[n] ^ expanded[n]);
    for (let round = 1; round <= 10; round++) {
      const substituted = state.map((value) => sbox[value]);
      state = substituted.map((_, n) => substituted[((Math.floor(n / 4) + (n % 4)) % 4) * 4 + (n % 4)]);
      if (round !== 10) {
        for (let n = 0; n < 16; n += 4) {
          const [a, b, c, d] = state.slice(n, n + 4);
          state.splice(
            n,
            4,
            mul(a, 2) ^ mul(b, 3) ^ c ^ d,
            a ^ mul(b, 2) ^ mul(c, 3) ^ d,
            a ^ b ^ mul(c, 2) ^ mul(d, 3),
            mul(a, 3) ^ b ^ c ^ mul(d, 2),
          );
        }
      }
      state = state.map((value, n) => value ^ expanded[round * 16 + n]);
    }
    output.push(...state);
    previous = state;
  }
  return output;
}

export function utf8(value) {
  const bytes = [];
  for (const char of value) {
    const n = char.codePointAt(0);
    if (n < 128) bytes.push(n);
    else if (n < 2048) bytes.push(192 | (n >> 6), 128 | (n & 63));
    else if (n < 65536) bytes.push(224 | (n >> 12), 128 | ((n >> 6) & 63), 128 | (n & 63));
    else bytes.push(240 | (n >> 18), 128 | ((n >> 12) & 63), 128 | ((n >> 6) & 63), 128 | (n & 63));
  }
  return bytes;
}

export function encryptEnergy(data) {
  // Public constants used by the school's protocol, not account secrets.
  const key = utf8("1234567812345678");
  const bytes = aes128Cbc(utf8(JSON.stringify(data)), key, key);
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let result = "";
  for (let n = 0; n < bytes.length; n += 3) {
    const bits = (bytes[n] << 16) | ((bytes[n + 1] || 0) << 8) | (bytes[n + 2] || 0);
    result +=
      alphabet[bits >>> 18] +
      alphabet[(bits >>> 12) & 63] +
      (n + 1 < bytes.length ? alphabet[(bits >>> 6) & 63] : "=") +
      (n + 2 < bytes.length ? alphabet[bits & 63] : "=");
  }
  return result;
}
