/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// Standard MD5 wire digest, used only by legacy service authentication. This
// does not provide password storage or a security hash for package identity.
export function md5(text) {
  const encoded = unescape(encodeURIComponent(text));
  const bytes = Array.from(encoded, (c) => c.charCodeAt(0));
  const bits = bytes.length * 8;
  bytes.push(128);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (let i = 0; i < 8; i++) bytes.push(Math.floor(bits / 2 ** (8 * i)) & 255);
  let state = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476];
  const shifts = [
    [7, 12, 17, 22],
    [5, 9, 14, 20],
    [4, 11, 16, 23],
    [6, 10, 15, 21],
  ];
  for (let offset = 0; offset < bytes.length; offset += 64) {
    const words = Array.from(
      { length: 16 },
      (_, i) =>
        bytes[offset + i * 4] |
        (bytes[offset + i * 4 + 1] << 8) |
        (bytes[offset + i * 4 + 2] << 16) |
        (bytes[offset + i * 4 + 3] << 24),
    );
    let [a, b, c, d] = state;
    for (let i = 0; i < 64; i++) {
      const round = i >> 4;
      const f =
        round === 0
          ? (b & c) | (~b & d)
          : round === 1
            ? (d & b) | (~d & c)
            : round === 2
              ? b ^ c ^ d
              : c ^ (b | ~d);
      const g =
        round === 0 ? i : round === 1 ? (5 * i + 1) % 16 : round === 2 ? (3 * i + 5) % 16 : (7 * i) % 16;
      const x = (a + f + Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) + words[g]) | 0;
      const shift = shifts[round][i % 4];
      [a, b, c, d] = [d, (b + ((x << shift) | (x >>> (32 - shift)))) | 0, b, c];
    }
    state = state.map((v, i) => (v + [a, b, c, d][i]) | 0);
  }
  return state
    .flatMap((v) => [0, 8, 16, 24].map((n) => ((v >>> n) & 255).toString(16).padStart(2, "0")))
    .join("");
}
