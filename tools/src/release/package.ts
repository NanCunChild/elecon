/**
 * 🔒 official adapter release packaging (ADR-018 §2.3/§2.9).
 *
 * This command produces the complete static dist tree consumed by endpoint D:
 *   catalog.json.gz, revocation.json, and bundles/<digest>.json.gz.
 *
 * The dist tree is endpoint-agnostic (ADR-018 §2.5.1): the catalog only lists
 * digests, never URLs, so the same signed tree can be hosted at any base URL
 * (official endpoint, mirrors, a local smoke server). The client owns the base.
 *
 * It never stores credentials and never signs automatically with a local key.
 * The CLI obtains a YubiKey PIN interactively and every signature remains gated
 * by the hardware touch policy. Tests use the exported buildRelease function
 * with a fake SignBackend only for deterministic packaging coverage.
 */

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import { buildEnvelope } from "../bundle/envelope.js";
import { inspectBundle, packBundle } from "../bundle/package.js";
import { signEnvelope } from "../bundle/sign.js";
import { signCatalog } from "../catalog/sign.js";
import { type Catalog, checkCatalog, loadCatalogValidator, loadRegistryIds } from "../catalog/validate.js";
import { type SignBackend, YubiKeySignBackend } from "../signer/index.js";
import { PinentryPinProvider } from "../signer/pinentry.js";
import { promptPin, YubiKeyPkcs11Signer } from "../signer/pkcs11.js";
import { type RevocationList, signRevocation } from "../signer/revocation.js";
import { loadContract, validateAdapterDir } from "../validator/index.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

export interface ReleaseOptions {
  adaptersRoot: string;
  outputDir: string;
  sequence: number;
  issuedAt: string;
  ttlSeconds: number;
  revocation: RevocationList;
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
    if (lstatSync(dir).isSymbolicLink()) {
      throw new Error(`adapter 根目录禁止符号链接：${dir}`);
    }
    if (existsSync(join(dir, "manifest.json"))) {
      found.push(dir);
      return;
    }
    for (const entry of readdirSync(dir).sort()) {
      const child = join(dir, entry);
      const childStat = lstatSync(child);
      if (childStat.isSymbolicLink()) {
        throw new Error(`adapter 目录禁止符号链接：${child}`);
      }
      if (childStat.isDirectory()) walk(child);
    }
  };
  walk(resolve(root));
  return found.sort();
}

function readManifest(dir: string): AdapterManifest {
  return JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")) as AdapterManifest;
}

function capabilityIds(manifest: AdapterManifest): string[] {
  if (!Array.isArray(manifest.capabilities)) {
    throw new Error(`${manifest.adapterId} manifest.capabilities 非数组（fail-closed）`);
  }
  return manifest.capabilities.map((cap) => (typeof cap === "string" ? cap : (cap.id ?? "")));
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
export async function buildRelease(options: ReleaseOptions, backend: SignBackend): Promise<ReleaseResult> {
  const outputDir = resolve(options.outputDir);
  const adapterDirs = discoverAdapters(options.adaptersRoot);
  if (adapterDirs.length === 0) throw new Error("没有发现可发布 adapter（fail-closed）");

  const contract = loadContract();
  for (const dir of adapterDirs) {
    // release 一律按 official 校验：档位由**本流水线声明**，不向 manifest 提问（ADR-002 §2.2）。
    // manifest 若声明了别的档位，validateAdapterDir 会给出 C0_intended_tier_mismatch（error）。
    const findings = validateAdapterDir(dir, contract, "official");
    const errors = findings.filter((finding) => finding.level === "error");
    if (errors.length > 0) {
      throw new Error(
        `${basename(dir)} 校验失败：${errors.map((finding) => `[${finding.code}] ${finding.message}`).join("; ")}`,
      );
    }
  }

  const bundlesDir = join(outputDir, "bundles");
  mkdirSync(bundlesDir, { recursive: true });
  const entries: Catalog["entries"] = [];
  const bundleDigests: string[] = [];

  for (const dir of adapterDirs) {
    const manifest = readManifest(dir);
    // 档位由流水线注入（下方 signEnvelope 的 "official"），不取自 manifest 自报。此处只核对
    // claim 不与之冲突——冲突说明作者意图与发布意图不一致，须人工澄清（ADR-002 §2.2）。
    // 上面的 validateAdapterDir(…, "official") 已用 C0_intended_tier_mismatch 拦下同一情形，
    // 本检查是发布路径的纵深防御，不依赖校验器被正确调用。
    if (manifest.trustTier !== undefined && manifest.trustTier !== "official") {
      throw new Error(
        `${manifest.adapterId} 的 manifest.trustTier='${manifest.trustTier}' 与 release 的 official 意图冲突，禁止进入 release（fail-closed）`,
      );
    }
    const built = buildEnvelope(dir);
    const signature = await signEnvelope(built, "official", backend);
    const packed = packBundle(built.bytes, signature, built.blobs);
    // 签发侧**自验**（keyless，只跳过 Ed25519——签发侧拿不到公钥）：卫生闸门、blob 集合
    // 精确相等、身份三方一致都在出厂前跑一遍，避免签出一份自己都装不上的产物。
    const selfCheck = inspectBundle(packed);
    if (!selfCheck.ok) {
      throw new Error(`${manifest.adapterId} bundle 签发自验失败：${selfCheck.reason}`);
    }
    const digest = selfCheck.value;
    const bundlePath = join(bundlesDir, `${digest}.json.gz`);
    writeFileSync(bundlePath, packed);
    bundleDigests.push(digest);
    entries.push({
      adapterId: manifest.adapterId,
      adapterVersion: manifest.adapterVersion,
      digest,
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
    if (arg("base-url") !== undefined) {
      throw new Error("--base-url 已移除：catalog 不再描述端点（ADR-018 §2.5.1），base URL 由客户端自持");
    }
    const keyId = arg("key-id") ?? "elecon-official-ncc-1";
    const pinProvider =
      arg("pin-provider") === "tty"
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
