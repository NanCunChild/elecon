/**
 * signer：官方 adapter 签名 / 验签 / 吊销（ADR-002 §2.3–§2.4）。
 *
 * 🔒🔒 安全敏感承重路径（红线 #4：传输底座/adapter 仅官方签名加载）。
 *     按 AGENTS.md §1，**签名相关代码及其测试不得由 AI 独自闭环**——须人工主导 + 安全清单 + ≥1 人工审。
 *     硬件出签已接线（`./pkcs11.ts` 的 `YubiKeyPkcs11Signer`，2026-07-16 真机核验，经人工评审批准）。
 *     **密钥 ceremony（PIN/PUK/管理密钥/生成密钥）永不由自动化执行**——见
 *     `docs/reference/signing_ceremony.md`。
 *
 * 机制（摘自 ADR-002 §2.3，权威以 ADR 为准）：
 *  - 签什么：bundle 规范化内容摘要（manifest + entry 源码 + 资产）+ **裁定档位**，detached 签名。
 *  - 规范化（§2.3b 钉死）：文件按路径**字典序**、内容 **UTF-8 NFC**、换行 **LF**；文件末尾不追加也不剥除 newline。
 *  - digest：`SHA-256(SHA-256(file1) || SHA-256(file2) || ...)`（先各文件哈希，拼接后再 SHA-256）。
 *  - 签名：**Ed25519**（RFC 8032）over `{ digest, tier, adapterId, adapterVersion }` 的规范化 payload。
 *  - 私钥托管：**离线硬件密钥（YubiKey，PIV/PKCS#11，Ed25519）**，PIN+触碰本地签名，私钥永不导出/入仓/上服务器
 *    （2026-07-15 修订，取代 KMS）。dev 过渡期允许本地 Ed25519，**首次 release 前硬件签必须就位**（§2.3 硬 deadline）。
 *  - 校验：核心加载前对 **active** pin 公钥验签，fail-closed。
 *
 *   运行：cd tools && npm run sign -- --adapter=../adapters/school-x --tier=official   # 🔒 dev 后端
 *         cd tools && npx tsx src/signer/index.ts digest --adapter=../adapters/school-x
 *         cd tools && npx tsx src/signer/index.ts verify --adapter=../adapters/school-x --pubkey=...
 */

import { createHash, sign as edSign, verify as edVerify, type KeyObject } from "node:crypto";
import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

// ---- 类型 ----

export type TrustTier = "official" | "sideload";

/** detached 签名载荷（进签名的字节；tier 是**签名流程注入的裁定档位**，非 manifest 自报，§2.2）。 */
export interface SignaturePayload {
  adapterId: string;
  adapterVersion: string;
  tier: TrustTier;
  /** bundle 规范化摘要（hex）。 */
  digest: string;
}

/** 落盘的签名文件（adapter 目录下 `signature.json`）。 */
export interface SignatureFile extends SignaturePayload {
  /** Ed25519 签名（base64）。 */
  signature: string;
  /** 签名所用公钥标识（对应核心 pin 的 active key id）。 */
  keyId: string;
  algorithm: "ed25519";
}

// ---- 规范化 bundle digest（确定性、无密钥；可安全测试） ----

/** 应纳入 digest 的文件（排除签名文件自身与无关产物）。可随 ADR 细化。 */
const BUNDLE_INCLUDE = /\.(json|js|mjs|ts|html?|css|txt|svg|png)$/i;
const BUNDLE_EXCLUDE = /(^|\/)(signature\.json|node_modules|\.git|fixtures)(\/|$)/;

/** 递归收集 adapter 目录下参与签名的文件（相对路径），按字典序排序。 */
export function collectBundleFiles(dir: string): string[] {
  const out: string[] = [];
  const root = realpathSync(dir);
  const walk = (d: string): void => {
    if (lstatSync(d).isSymbolicLink()) {
      throw new Error(`bundle 禁止符号链接：${d}`);
    }
    for (const entry of readdirSync(d).sort()) {
      const p = join(d, entry);
      const rel = relative(dir, p);
      if (BUNDLE_EXCLUDE.test(rel)) continue;
      const stat = lstatSync(p);
      if (stat.isSymbolicLink()) {
        throw new Error(`bundle 禁止符号链接：${p}`);
      }
      const resolved = realpathSync(p);
      const outside = relative(root, resolved).startsWith("..");
      if (outside) throw new Error(`bundle 路径越界：${p}`);
      if (stat.isDirectory()) walk(p);
      else if (stat.isFile() && BUNDLE_INCLUDE.test(entry)) out.push(rel);
    }
  };
  walk(dir);
  return out.sort(); // 字典序（§2.3b）
}

function sha256(buf: Buffer): Buffer {
  return createHash("sha256").update(buf).digest();
}

/**
 * 规范化文件内容：UTF-8 NFC + LF 换行；不追加也不剥除文件末尾 newline（ADR-002 §2.3b）。
 * ⚠ 二进制资产（png 等）不做文本规范化——当前 include 名单以文本为主；若纳入二进制，
 *   须人工在 ADR 明确其规范化语义（本骨架暂对非 UTF-8 可解码内容按原字节处理）。
 */
export function canonicalizeContent(raw: Buffer): Buffer {
  // 尝试按 UTF-8 文本规范化；失败（真二进制）则原样。
  const text = raw.toString("utf-8");
  if (Buffer.from(text, "utf-8").equals(raw)) {
    const normalized = text.normalize("NFC").replace(/\r\n?/g, "\n");
    return Buffer.from(normalized, "utf-8");
  }
  return raw;
}

/**
 * bundle digest：`SHA-256(SHA-256(file1) || SHA-256(file2) || ...)`（§2.3 step 6）。
 * 确定性，无密钥——digest 本身可自由测试。
 */
export function computeBundleDigest(dir: string): string {
  const files = collectBundleFiles(dir);
  const parts: Buffer[] = [];
  for (const rel of files) {
    const content = canonicalizeContent(readFileSync(join(dir, rel)));
    parts.push(sha256(content));
  }
  return sha256(Buffer.concat(parts)).toString("hex");
}

/** 规范化签名 payload → 待签字节（稳定序列化，两端一致）。 */
export function serializePayload(p: SignaturePayload): Buffer {
  // 固定键序，避免 JSON 键序漂移影响签名/验签。
  const canonical = JSON.stringify({
    adapterId: p.adapterId,
    adapterVersion: p.adapterVersion,
    digest: p.digest,
    tier: p.tier,
  });
  return Buffer.from(canonical, "utf-8");
}

// ---- 签名后端（私钥操作接缝；生产 = 离线 YubiKey，🔒 人工闭环） ----

/**
 * 签名后端：把「私钥签名操作」抽象为接缝。
 *  - 生产：`YubiKeySignBackend`（离线 YubiKey PIV/PKCS#11，需人工 PIN + 触碰）。
 *  - dev 过渡：`LocalDevSignBackend`（本地 Ed25519 私钥，**仅 dev/staging**，产物不分发终端用户）。
 */
export interface SignBackend {
  readonly keyId: string;
  /** 对 payload 字节做 Ed25519 签名，返回 base64。私钥永不出后端。 */
  sign(payload: Buffer): Promise<string>;
}

/**
 * 硬件签名提供者接缝（PIV/PKCS#11 `CKM_EDDSA`）。私钥驻留 YubiKey、永不出;签名需 PIN+触碰。
 * **返回裸 64 字节 Ed25519 签名**（非 OpenPGP packet 封装），以对齐 verifyAdapter 的 `edVerify`。
 * 这是"硬件出签"的唯一接触点——把 YubiKeySignBackend 与具体 PKCS#11 实现解耦、便于测试。
 */
export interface HardwareEd25519Signer {
  readonly keyId: string;
  /** 对 data 做原始 Ed25519 签名（裸 r||s 64 字节）。私钥永不出硬件。 */
  signEd25519(data: Buffer): Promise<Buffer>;
}

/**
 * 显式 fail-closed 的硬件提供者占位——**构造即可、调用即抛**，杜绝"忘了接硬件却签出了东西"。
 *
 * **生产实现是 `YubiKeyPkcs11Signer`（`./pkcs11.ts`，PIV/PKCS#11 `CKM_EDDSA`，
 * 2026-07-16 已接线并真机核验）**。本类保留用于：① 需要一个"绝不出签"的哨兵时；
 * ② 测试 `YubiKeySignBackend` 在无硬件时确实 fail-closed。
 */
export class UnwiredHardwareSigner implements HardwareEd25519Signer {
  readonly keyId: string;
  constructor(keyId = "yubikey-unwired") {
    this.keyId = keyId;
  }
  signEd25519(): Promise<Buffer> {
    throw new Error(
      "🔒 本 HardwareEd25519Signer 是未接线占位，拒绝出签。生产请用 YubiKeyPkcs11Signer（./pkcs11.ts，ADR-002 §2.3，红线 #4）。",
    );
  }
}

/**
 * 离线 YubiKey 签名后端（ADR-002 §2.3，取代 KMS）。委托 {@link HardwareEd25519Signer} 出裸 64B
 * Ed25519 签名并转 base64。私钥永不入进程/仓库/服务器;签名需物理 PIN+触碰。
 *
 * 生产的硬件实现见 `./pkcs11.ts` 的 `YubiKeyPkcs11Signer`（2026-07-16 已接线并真机核验）。
 * 本类只做编排（委托 + 裸 64B 守卫 + keyId 透传），故可注入 fake provider 测试而不碰硬件。
 * 🔒 **密钥 ceremony（PIN/PUK/管理密钥/生成密钥）仍不得由任何自动化执行**——见
 * `docs/reference/signing_ceremony.md`（AGENTS.md §1）。
 */
export class YubiKeySignBackend implements SignBackend {
  readonly keyId: string;
  #hw: HardwareEd25519Signer;
  constructor(hw: HardwareEd25519Signer) {
    this.#hw = hw;
    this.keyId = hw.keyId;
  }
  async sign(payload: Buffer): Promise<string> {
    const raw = await this.#hw.signEd25519(payload);
    if (raw.length !== 64) {
      throw new Error(
        `Ed25519 签名须为裸 64 字节，得 ${raw.length}（PKCS#11 用 CKM_EDDSA raw，非 OpenPGP packet 封装）。`,
      );
    }
    return raw.toString("base64");
  }
}

/**
 * dev 过渡后端：本地 Ed25519 私钥签名。**仅限 dev/staging**（产物不分发终端用户）。
 * 生产（NODE_ENV=production）构造即 fail-closed，杜绝误用（仿 §2.7 决策 F 的护栏取向）。
 */
export class LocalDevSignBackend implements SignBackend {
  readonly keyId: string;
  #privateKey: KeyObject;
  constructor(privateKey: KeyObject, keyId = "dev-local") {
    if (process.env.NODE_ENV === "production") {
      throw new Error(
        "🔒 LocalDevSignBackend 禁止在生产使用（红线 #4）；生产须走 YubiKeySignBackend（离线硬件）。",
      );
    }
    this.#privateKey = privateKey;
    this.keyId = keyId;
  }
  async sign(payload: Buffer): Promise<string> {
    // Ed25519：algorithm 传 null（EdDSA 内建 SHA-512，不可参数化，见 ADR-002 §2.3）。
    return edSign(null, payload, this.#privateKey).toString("base64");
  }
}

// ---- 验签（无密钥，公钥公开；确定性可测） ----

/**
 * **tools 层统一验签结果约定**（勿再用裸 bool / 抛异常混用）：失败恒带 `reason`；成功携带**已验证产物**
 * （如裁定档位、已解析 catalog）——调用方只能经 `ok:true` 分支拿到产物，无法误用未验证数据。
 * **裁定「是否加载」仍在 🔒 加载器**（ADR-002 §2.6）；本层只回答"这份签名是否成立、成立则得到什么"。
 */
export type VerifyResult<T> = { ok: true; value: T } | { ok: false; reason: string };

/** 读 bundle 内 manifest 的权威身份（adapterId/adapterVersion）。 */
function readManifestIdentity(dir: string): { adapterId: string; adapterVersion: string } | null {
  try {
    const m = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf-8")) as {
      adapterId?: string;
      adapterVersion?: string;
    };
    if (!m.adapterId || !m.adapterVersion) return null;
    return { adapterId: m.adapterId, adapterVersion: m.adapterVersion };
  } catch {
    return null;
  }
}

/**
 * 对 adapter 目录验签：重算 digest → 用 pin 公钥验 Ed25519 → **核对签名身份与 bundle 内 manifest 一致**。
 * 全部通过才返回裁定档位。核心加载前调用（fail-closed）。
 *
 * 身份核对（ADR-002 §2.2「与 manifest 自报不符则拒绝加载」）：digest 只绑定**内容**，签名载荷里的
 * `adapterId/adapterVersion` 是**另一维**——若不核对，一份「内容为 A、身份写 B」的签名仍能验过，
 * 而运行时用的是 bundle 内 manifest（决定 allow/credentials）→ 身份混淆。故此处强制两者一致。
 */
export function verifyAdapter(dir: string, publicKey: KeyObject): VerifyResult<TrustTier> {
  const sigPath = join(dir, "signature.json");
  if (!existsSync(sigPath)) {
    return { ok: false, reason: "无 signature.json → 按 sideload 处理（release 拒绝加载）。" };
  }
  let sig: SignatureFile;
  try {
    sig = JSON.parse(readFileSync(sigPath, "utf-8")) as SignatureFile;
  } catch (err) {
    return { ok: false, reason: `signature.json 解析失败：${(err as Error).message}` };
  }
  if (sig.algorithm !== "ed25519") {
    return { ok: false, reason: `不支持的签名算法：${sig.algorithm}` };
  }
  if (computeBundleDigest(dir) !== sig.digest) {
    return { ok: false, reason: "bundle digest 与签名不符（内容被篡改或签名过期）→ fail-closed。" };
  }
  const identity = readManifestIdentity(dir);
  if (identity === null) {
    return { ok: false, reason: "manifest.json 缺失/损坏或无 adapterId/adapterVersion → fail-closed。" };
  }
  if (sig.adapterId !== identity.adapterId || sig.adapterVersion !== identity.adapterVersion) {
    return {
      ok: false,
      reason: `签名身份与 bundle 内 manifest 不符（签名 ${sig.adapterId}@${sig.adapterVersion} vs manifest ${identity.adapterId}@${identity.adapterVersion}）→ fail-closed（ADR-002 §2.2）。`,
    };
  }
  if (!edVerify(null, serializePayload(sig), publicKey, Buffer.from(sig.signature, "base64"))) {
    return { ok: false, reason: "Ed25519 验签失败 → fail-closed。" };
  }
  return { ok: true, value: sig.tier };
}

// ---- 签名流程 ----

/**
 * 对 adapter 目录签名并写 signature.json。
 * tier 是**签名流程显式注入的裁定档位**（§2.2），非取自 manifest 自报。
 * 🔒 「签 official」是需显式人工批准的动作——本函数不做批准，批准由持 YubiKey 的 release owner 之 PIN+触碰承担。
 */
export async function signAdapter(
  dir: string,
  tier: TrustTier,
  backend: SignBackend,
): Promise<SignatureFile> {
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf-8")) as {
    adapterId: string;
    adapterVersion: string;
  };
  const payload: SignaturePayload = {
    adapterId: manifest.adapterId,
    adapterVersion: manifest.adapterVersion,
    tier,
    digest: computeBundleDigest(dir),
  };
  const signature = await backend.sign(serializePayload(payload));
  const out: SignatureFile = { ...payload, signature, keyId: backend.keyId, algorithm: "ed25519" };
  writeFileSync(join(dir, "signature.json"), JSON.stringify(out, null, 2) + "\n");
  return out;
}

// ---- CLI ----

function argOf(name: string): string | undefined {
  const p = process.argv.find((a) => a.startsWith(`--${name}=`));
  return p?.slice(name.length + 3);
}

function main(): void {
  const cmd = process.argv[2];
  const dir = argOf("adapter");

  if (cmd === "digest") {
    if (!dir) throw new Error("用法：digest --adapter=<dir>");
    console.log(computeBundleDigest(dir));
    return;
  }

  // sign / verify 是 🔒 承重路径：本 CLI **刻意不做**「自动加载某把私钥/公钥就签」——
  // 密钥的选取与出签须是维护者的显式动作（ADR-002 §2.3「签 official = 需显式批准的动作」）。
  console.log("🔒 signer CLI：");
  console.log("  - `digest` 已可用（确定性 bundle 摘要，无密钥）。");
  console.log("  - 硬件出签：`npx tsx src/signer/pkcs11.ts selftest`（PIN + 触碰）；");
  console.log("    密钥 ceremony 见 docs/reference/signing_ceremony.md（永不自动化）。");
  console.log(
    "  - `sign` / `verify` 无 CLI 子命令：请用可编程 API（signAdapter / verifyAdapter）在显式脚本里调，",
  );
  console.log("    避免「随手一条命令就签出 official」（ADR-002 §2.3，AGENTS.md §1）。");
  console.log("  - 可编程 API：signAdapter() / verifyAdapter() / computeBundleDigest()。");
  process.exitCode = 2;
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
