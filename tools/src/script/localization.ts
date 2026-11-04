/** ADR-070: semantic checks shared with the Dart installation parser. */
export const MAX_SCRIPT_LOCALIZATION_BYTES = 256 * 1024;
const locale = /^[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-[A-Z]{2}|-[0-9]{3})?$(?![\s\S])/;
const keyPattern = /^[A-Za-z][A-Za-z0-9_.-]{0,127}$(?![\s\S])/;
const placeholder = /\{([A-Za-z][A-Za-z0-9_]{0,63})\}/g;

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function wellFormed(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i);
    if ((unit < 32 && ![9, 10, 13].includes(unit)) || (unit >= 127 && unit <= 159)) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length || value.charCodeAt(i) < 0xdc00 || value.charCodeAt(i) > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}

export function validateScriptLocalization(value: unknown): void {
  const invalid = () => {
    throw new Error("script_package_localization_invalid");
  };
  if (
    !object(value) ||
    Object.keys(value).length !== 2 ||
    !Object.hasOwn(value, "defaultLocale") ||
    !Object.hasOwn(value, "messages") ||
    Buffer.byteLength(JSON.stringify(value), "utf8") > MAX_SCRIPT_LOCALIZATION_BYTES
  )
    return invalid();
  const { defaultLocale, messages } = value;
  if (
    typeof defaultLocale !== "string" ||
    !locale.test(defaultLocale) ||
    !object(messages) ||
    Object.keys(messages).length < 1 ||
    Object.keys(messages).length > 32 ||
    !Object.hasOwn(messages, defaultLocale)
  )
    return invalid();
  const placeholders = new Map<string, Map<string, Set<string>>>();
  for (const [language, dictionary] of Object.entries(messages)) {
    if (
      !locale.test(language) ||
      !object(dictionary) ||
      Object.keys(dictionary).length < 1 ||
      Object.keys(dictionary).length > 1024
    )
      return invalid();
    const names = new Map<string, Set<string>>();
    for (const [key, message] of Object.entries(dictionary)) {
      if (
        !keyPattern.test(key) ||
        typeof message !== "string" ||
        Array.from(message).length > 4096 ||
        !wellFormed(message) ||
        /[{}]/.test(message.replace(placeholder, ""))
      )
        return invalid();
      names.set(key, new Set([...message.matchAll(placeholder)].map((match) => match[1]!)));
    }
    placeholders.set(language, names);
  }
  const defaults = placeholders.get(defaultLocale)!;
  for (const language of placeholders.values()) {
    for (const [key, names] of language) {
      const expected = defaults.get(key);
      if (!expected || expected.size !== names.size || [...names].some((name) => !expected.has(name)))
        return invalid();
    }
  }
}
