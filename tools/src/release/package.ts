/**
 * 🔒 official adapter release packaging (ADR-018 §2.3/§2.9).
 *
 * This command produces the complete static dist tree consumed by endpoint D:
 *   catalog.json.gz, revocation.json, and bundles/<digest>.json.gz.
 *
 * It never stores credentials and never signs automatically with a local key.
 * The CLI obtains a YubiKey PIN interactively and every signature remains gated
 * by the hardware touch policy. Tests use the exported buildRelease function
 * with a fake SignBackend only for deterministic packaging coverage.
 */

import { gzipSync } from "node:zlib";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildEnvelope } from "../bundle/envelope.js";
import { packBundle, unpackBundle, verifyBundleIntegrity } from "../bundle/package.js";
import { signEnvelope } from "../bundle/sign.js";
import { signCatalog } from "../catalog/sign.js";
import { checkCatalog, loadCatalogValidator, loadRegistryIds, type Catalog } from "../catalog/validate.js";
import { type SignBackend } from "../signer/index.js";
import { promptPin, YubiKeyPkcs11Signer } from "../signer/pkcs11.js";
import { PinentryPinProvider } from "../signer/pinentry.js";
import { signRevocation, type RevocationList } from "../signer/revocation.js";
import { loadContract, validateAdapterDir } from "../validator/index.js";
import { YubiKeySignBackend } from "../signer/index.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

export interface ReleaseOptions {
  adaptersRoot: string;
  outputDir: string;
  baseUrl: string;
  sequence: number;
  issuedAt: string;
  ttlSeconds: number;
  revocation: RevocationList;
  validate?: boolean;
}

export interface ReleaseResult {
  catalog: Catalog;
  bundleDigests: string[];
  outputDir: string;
}

interface AdapterManifest {
  adapterId: string;
  adapterVersion: string;
  trustTier?: string;
  runtime?: { stdlibMin?: string };
  capabilities?: Array<string | { id?: string }>;
}

function discoverAdapters(root: string): string[] {
  const found: string[] = [];
  const walk = (dir: string): void => {
    if (existsSync(join(dir, "manifest.json"))) {
      found.push(dir);
      return;
    }
    for (const entry of readdirSync(dir).sort()) {
      const child = join(dir, entry);
      if (statSync(child).isDirectory()) walk(child);
    }
  };
  walk(resolve(root));
  return found.sort();
}

function readManifest(dir: string): AdapterManifest {
  return JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")) as AdapterManifest;
}

function requireHttpsBase(raw: string): string {
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.username || url.password || !url.hostname) {
    throw new Error("release base URL 必须是无 userinfo 的 https URL（fail-closed）");
  }
  return url.toString().replace(/\/$/, "");
}

function capabilityIds(manifest: AdapterManifest): string[] {
  if (!Array.isArray(manifest.capabilities)) {
    throw new Error(`${manifest.adapterId} manifest.capabilities 非数组（fail-closed）`);
  }
  return manifest.capabilities.map((cap) => (typeof cap === "string" ? cap : cap.id ?? ""));
}

function writeGzipJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, gzipSync(Buffer.from(JSON.stringify(value), "utf8")));
}

function writeJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value)}\n`);
}

/**
 * Build and sign one complete endpoint-D dist tree.
 *
 * The caller must supply the signing backend explicitly. The function validates
 * the adapter set and catalog before any signed catalog is written.
 */
export async function buildRelease(
  options: ReleaseOptions,
  backend: SignBackend,
): Promise<ReleaseResult> {
  const baseUrl = requireHttpsBase(options.baseUrl);
  const outputDir = resolve(options.outputDir);
  const adapterDirs = discoverAdapters(options.adaptersRoot);
  if (adapterDirs.length === 0) throw new Error("没有发现可发布 adapter（fail-closed）");

  if (options.validate !== false) {
    const contract = loadContract();
    for (const dir of adapterDirs) {
      const findings = validateAdapterDir(dir, contract);
      const errors = findings.filter((finding) => finding.level === "error");
      if (errors.length > 0) {
        throw new Error(
          `${basename(dir)} 校验失败：${errors.map((finding) => `[${finding.code}] ${finding.message}`).join("; ")}`,
        );
      }
    }
  }

  const bundlesDir = join(outputDir, "bundles");
  mkdirSync(bundlesDir, { recursive: true });
  const entries: Catalog["entries"] = [];
  const bundleDigests: string[] = [];

  for (const dir of adapterDirs) {
    const manifest = readManifest(dir);
    if (manifest.trustTier !== "official") {
      throw new Error(`${manifest.adapterId} 不是 official adapter，禁止进入 release（fail-closed）`);
    }
    const envelope = buildEnvelope(dir);
    const signature = await signEnvelope(envelope, "official", backend);
    const packed = packBundle(envelope, signature);
    const unpacked = unpackBundle(packed);
    const integrity = verifyBundleIntegrity(unpacked.envelope, signature);
    if (!integrity.ok) throw new Error(`${manifest.adapterId} bundle 内容寻址复核失败`);

    const digest = integrity.value;
    const bundlePath = join(bundlesDir, `${digest}.json.gz`);
    writeFileSync(bundlePath, packed);
    bundleDigests.push(digest);
    entries.push({
      adapterId: manifest.adapterId,
      adapterVersion: manifest.adapterVersion,
      digest,
      url: `${baseUrl}/bundles/${digest}.json.gz`,
      ...(manifest.runtime?.stdlibMin ? { stdlibMin: manifest.runtime.stdlibMin } : {}),
      capabilities: capabilityIds(manifest),
    });
  }

  const catalog: Catalog = {
    catalogVersion: "1.0",
    sequence: options.sequence,
    issuedAt: options.issuedAt,
    ttlSeconds: options.ttlSeconds,
    entries,
  };
  const findings = checkCatalog(catalog, {
    catalogValidate: loadCatalogValidator(),
    registryIds: loadRegistryIds(),
  });
  const catalogErrors = findings.filter((finding) => finding.level === "error");
  if (catalogErrors.length > 0) {
    throw new Error(`catalog 校验失败：${catalogErrors.map((finding) => finding.message).join("; ")}`);
  }

  const signedCatalog = await signCatalog(catalog, backend);
  const signedRevocation = await signRevocation(options.revocation, backend);
  writeGzipJson(join(outputDir, "catalog.json.gz"), signedCatalog);
  writeJson(join(outputDir, "revocation.json"), signedRevocation);

  return { catalog, bundleDigests, outputDir };
}

function arg(name: string): string | undefined {
  return process.argv.find((value) => value.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function requiredArg(name: string): string {
  const value = arg(name);
  if (!value) throw new Error(`缺少 --${name}= 参数`);
  return value;
}

function main(): void {
  void (async () => {
    const adaptersRoot = arg("adapters") ?? join(repoRoot, "adapters");
    const outputDir = arg("out") ?? join(repoRoot, "dist");
    const sequence = Number(arg("sequence") ?? "1");
    const ttlSeconds = Number(arg("ttl-seconds") ?? "86400");
    const issuedAt = arg("issued-at") ?? new Date().toISOString();
    const revocationPath = requiredArg("revocation");
    const baseUrl = requiredArg("base-url");
    const keyId = arg("key-id") ?? "elecon-official-ncc-1";
    const pinProvider = arg("pin-provider") === "tty"
      ? async () => promptPin()
      : () => new PinentryPinProvider({ command: arg("pinentry-command") }).getPin();
    const hardware = new YubiKeyPkcs11Signer(keyId, pinProvider, {
      serial: arg("serial"),
      module: arg("pkcs11-module"),
    });
    const backend = new YubiKeySignBackend(hardware);
    try {
      const revocation = JSON.parse(readFileSync(resolve(revocationPath), "utf8")) as RevocationList;
      const result = await buildRelease(
        {
          adaptersRoot,
          outputDir,
          baseUrl,
          sequence,
          issuedAt,
          ttlSeconds,
          revocation,
        },
        backend,
      );
      console.log(`release dist 已生成：${result.outputDir}`);
      console.log(`bundles: ${result.bundleDigests.length}`);
    } finally {
      hardware.close();
    }
  })().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) main();
