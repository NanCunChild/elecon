/** ADR-073: package-owned HTML bytes; parsing never executes markup. */
export function validateScriptWebContent(raw: unknown): void {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 8) throw new Error("invalid_web_content");
  const ids = new Set<string>();
  let total = 0;
  for (const value of raw) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_web_content");
    const page = value as Record<string, unknown>;
    if (
      Object.keys(page).length !== 3 ||
      !Object.keys(page).every((key) => ["id", "title", "html"].includes(key)) ||
      typeof page.id !== "string" ||
      !/^[a-z][a-z0-9._-]{0,63}$/.test(page.id) ||
      page.id.includes("\n") ||
      ids.has(page.id) ||
      typeof page.title !== "string" ||
      !page.title.trim() ||
      Array.from(page.title).length > 80 ||
      // biome-ignore lint/suspicious/noControlCharactersInRegex: reject control characters in host chrome.
      /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]/.test(page.title) ||
      /[\ud800-\udfff]/u.test(page.title) ||
      typeof page.html !== "string" ||
      !page.html ||
      page.html.includes("\0") ||
      /[\ud800-\udfff]/u.test(page.html) ||
      Buffer.byteLength(page.html, "utf8") > 256 * 1024
    )
      throw new Error("invalid_web_content");
    ids.add(page.id);
    total += Buffer.byteLength(page.html, "utf8");
  }
  if (total > 512 * 1024) throw new Error("invalid_web_content");
}
