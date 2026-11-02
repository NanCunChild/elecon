/**
 * ADR-034 §2: deterministic source packaging, with no evaluation or signing.
 * Packages gain execution trust only after the client's installation dialog.
 */
import { randomBytes } from "node:crypto";
import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import { validateScriptNetwork } from "./network.js";

export const MAX_SCRIPT_PACKAGE_BYTES = 1024 * 1024;

export class ScriptPackageError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "ScriptPackageError";
  }
}

const schemaPath = fileURLToPath(new URL("../../../contract/script-package.schema.json", import.meta.url));
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(record)
        .sort()
        .map((key) => [key, canonical(record[key])]),
    );
  }
  return value;
}

/** Returns stable UTF-8 JSON; never creates a runtime or evaluates source. */
export function packageScript(manifest: unknown, source: unknown): string {
  if (typeof source !== "string" || !source.trim() || source.includes("\0")) {
    throw new ScriptPackageError("script_package_source_invalid");
  }
  const candidate = { format: "elecon-script/1", manifest, source };
  if (!validate(candidate)) {
    // AJV errors can include source-controlled fields. Keep CLI diagnostics
    // stable instead of accidentally echoing embedded credentials or URLs.
    throw new ScriptPackageError("script_package_manifest_invalid");
  }
  const typed = manifest as {
    name: string;
    homeTitle?: string;
    websocketOrigins?: string[];
    network: { origins: string[]; ipAllow?: string[] };
    capabilities: Array<{ id: string }>;
    home?: Array<{ capability: string; params?: Record<string, unknown> }>;
    sdkVersion: number;
    cards?: Array<{ type: string; defaultVariant: string; id?: string; title?: string }>;
    accounts?: Array<{
      id: string;
      name: string;
      instructions: string;
      capabilities: string[];
      login?: { capability: string; params?: Record<string, unknown> };
      status?: { capability: string; params?: Record<string, unknown> };
    }>;
  };
  if (
    typed.name.includes("\0") ||
    typed.name.length > 160 ||
    (typed.homeTitle !== undefined && Array.from(typed.homeTitle).length > 80) ||
    new Set(typed.capabilities.map((capability) => capability.id)).size !== typed.capabilities.length
  ) {
    throw new ScriptPackageError("script_package_manifest_invalid");
  }
  const capabilityIds = new Set(typed.capabilities.map((capability) => capability.id));
  if (
    typed.accounts &&
    (new Set(typed.accounts.map((account) => account.id)).size !== typed.accounts.length ||
      typed.accounts.some(
        (account) =>
          account.name.length > 160 ||
          account.instructions.length > 2048 ||
          (account.login && !capabilityIds.has(account.login.capability)) ||
          (account.login?.capability === "account.session" &&
            (account.login.params?.account !== account.id ||
              account.login.params?.operation !== "login" ||
              Object.keys(account.login.params ?? {}).length !== 2)) ||
          (account.status &&
            (account.status.capability !== "account.session" ||
              !capabilityIds.has(account.status.capability) ||
              account.status.params?.operation !== "status" ||
              account.status.params?.account !== account.id ||
              Object.keys(account.status.params ?? {}).length !== 2)) ||
          account.capabilities.some((id) => !capabilityIds.has(id)) ||
          Buffer.byteLength(JSON.stringify(account.login?.params ?? {}), "utf8") > 4096,
      ))
  ) {
    throw new ScriptPackageError("script_package_manifest_invalid");
  }
  if (typed.cards && new Set(typed.cards.map((card) => card.id ?? card.type)).size !== typed.cards.length)
    throw new ScriptPackageError("script_package_manifest_invalid");
  // ADR-043 §3: the JSON schema checks card types, variants, uniqueness and
  // capability dependencies. Keep suggestions inside the approved manifest.
  // ADR-038 §1: semantic bounds mirror the client parser.
  if (
    typed.home &&
    (new Set(typed.home.map((entry) => entry.capability)).size !== typed.home.length ||
      typed.home.some(
        (entry) =>
          entry.capability === "climate.command" ||
          entry.capability === "card.qr" ||
          [
            "account.session",
            "forum.session",
            "messages.session",
            "messages.list",
            "messages.conversations",
            "messages.history",
            "messages.send",
            "attendance.checkin",
          ].includes(entry.capability) ||
          !typed.capabilities.some((cap) => cap.id === entry.capability) ||
          Buffer.byteLength(JSON.stringify(entry.params ?? {}), "utf8") > 4096,
      ))
  ) {
    throw new ScriptPackageError("script_package_manifest_invalid");
  }
  try {
    validateScriptNetwork(typed.network);
    validateScriptNetwork({
      origins: (typed.websocketOrigins ?? []).map((s) => s.replace(/^wss:/, "https:")),
      ...(typed.network.ipAllow ? { ipAllow: typed.network.ipAllow } : {}),
    });
  } catch (error) {
    throw new ScriptPackageError(error instanceof Error ? error.message : "script_package_network_invalid");
  }
  const encoded = `${JSON.stringify(canonical(candidate))}\n`;
  if (Buffer.byteLength(encoded, "utf8") > MAX_SCRIPT_PACKAGE_BYTES) {
    throw new ScriptPackageError("script_package_too_large");
  }
  return encoded;
}

function readBoundedUtf8(path: string): string {
  const descriptor = openSync(path, "r");
  try {
    const buffer = Buffer.alloc(MAX_SCRIPT_PACKAGE_BYTES + 1);
    let size = 0;
    while (size < buffer.length) {
      const count = readSync(descriptor, buffer, size, buffer.length - size, null);
      if (count === 0) break;
      size += count;
    }
    if (size > MAX_SCRIPT_PACKAGE_BYTES) {
      throw new ScriptPackageError("script_package_input_too_large");
    }
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size));
    } catch {
      throw new ScriptPackageError("script_package_utf8_invalid");
    }
  } finally {
    closeSync(descriptor);
  }
}

function argumentsFor(args: string[]): Map<string, string> {
  const allowed = new Set(["--manifest", "--source", "--out"]);
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    const equal = argument.indexOf("=");
    const key = equal < 0 ? argument : argument.slice(0, equal);
    const value = equal < 0 ? args[++index] : argument.slice(equal + 1);
    if (!allowed.has(key) || values.has(key) || !value || value.startsWith("--")) {
      throw new ScriptPackageError("script_package_usage");
    }
    values.set(key, value);
  }
  if (values.size !== allowed.size) throw new ScriptPackageError("script_package_usage");
  return values;
}

/** Validates before writing and atomically replaces the output on success. */
export function packageScriptFiles(args: string[]): void {
  const values = argumentsFor(args);
  // npm workspace scripts run with cwd=tools, but arguments are supplied from
  // the user's invocation directory. Direct CLI use keeps ordinary cwd rules,
  // even if it inherited INIT_CWD from some unrelated npm parent process.
  const callerDirectory =
    process.env.npm_lifecycle_event === "scripts:package" && process.env.INIT_CWD
      ? process.env.INIT_CWD
      : process.cwd();
  const manifestPath = resolve(callerDirectory, values.get("--manifest")!);
  const sourcePath = resolve(callerDirectory, values.get("--source")!);
  const output = resolve(callerDirectory, values.get("--out")!);
  if (output === manifestPath || output === sourcePath) {
    throw new ScriptPackageError("script_package_output_is_input");
  }
  let manifest: unknown;
  try {
    manifest = JSON.parse(readBoundedUtf8(manifestPath));
  } catch (error) {
    if (error instanceof ScriptPackageError) throw error;
    if (error instanceof SyntaxError) throw new ScriptPackageError("script_package_json_invalid");
    throw error;
  }
  const encoded = packageScript(manifest, readBoundedUtf8(sourcePath));
  const directory = dirname(output);
  mkdirSync(directory, { recursive: true });
  const temporary = join(directory, `.elecon-script-${randomBytes(12).toString("hex")}.tmp`);
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporary, "wx", 0o600);
    writeFileSync(descriptor, encoded, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, output);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporary, { force: true });
  }
}

const invokedPath = process.argv[1];
if (invokedPath && resolve(invokedPath) === fileURLToPath(import.meta.url)) {
  try {
    packageScriptFiles(process.argv.slice(2));
    console.log("script_package_created");
  } catch (error) {
    console.error(error instanceof ScriptPackageError ? error.code : "script_package_io_failed");
    process.exitCode = 1;
  }
}
