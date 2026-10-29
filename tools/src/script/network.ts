/** ADR-034 §4: authoring preflight mirrors the client's origin/IP syntax. */
import { isIP } from "node:net";

function invalid(code: string): never {
  throw new Error(code);
}

/** Shape has already passed script-package.schema.json. */
export function validateScriptNetwork(network: { origins: string[]; ipAllow?: string[] }): void {
  const origins = new Set<string>();
  for (const raw of network.origins) {
    const match = /^(https?):\/\/(\[[^\]]+\]|[^:/]+)(?::([0-9]+))?\/?$/.exec(raw);
    if (!match) invalid("script_package_origin_invalid");
    const scheme = match[1]!;
    const bracketed = match[2]!;
    const host = bracketed.startsWith("[") ? bracketed.slice(1, -1) : bracketed.toLowerCase();
    const port = match[3] === undefined ? (scheme === "https" ? 443 : 80) : Number(match[3]);
    if (port < 1 || port > 65535) invalid("script_package_origin_invalid");
    const family = isIP(host);
    if (bracketed.startsWith("[")) {
      if (family !== 6) invalid("script_package_origin_invalid");
    } else if (family !== 4) {
      // WHATWG URL accepts platform-specific aliases such as 127.1; the Dart
      // host deliberately rejects those, so inspect the original host first.
      if (
        /^[0-9.]+$/.test(host) ||
        /(^|\.)0x[0-9a-f]+($|\.)/i.test(host) ||
        host.length > 253 ||
        host.endsWith(".") ||
        !host.split(".").every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))
      ) {
        invalid("script_package_origin_invalid");
      }
    }
    let origin: string;
    try {
      origin = new URL(raw).origin;
    } catch {
      invalid("script_package_origin_invalid");
    }
    if (origins.has(origin)) invalid("script_package_origin_duplicate");
    origins.add(origin);
  }
  for (const raw of network.ipAllow ?? []) {
    const parts = raw.split("/");
    if (parts.length > 2 || raw.trim() !== raw || raw.includes("%")) {
      invalid("script_package_ip_allow_invalid");
    }
    const family = isIP(parts[0]!);
    if (family !== 4 && family !== 6) invalid("script_package_ip_allow_invalid");
    if (
      parts[1] !== undefined &&
      (!/^(0|[1-9][0-9]*)$/.test(parts[1]) || Number(parts[1]) > (family === 4 ? 32 : 128))
    ) {
      invalid("script_package_ip_allow_invalid");
    }
  }
}
