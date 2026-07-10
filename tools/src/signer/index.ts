/**
 * signer：官方 adapter 签名 / 验签 / 吊销（ADR-002 §2.3–§2.4）。
 *
 * 🔒🔒 安全敏感承重路径（红线 #4：传输底座/adapter 仅官方签名加载）。
 *     按 AGENTS.md §1，**签名相关代码及其测试不得由 AI 独自闭环**——本文件是
 *     **骨架（skeleton）**：确定性部分（bundle 规范化 digest、验签）已实现供审阅，
 *     但**私钥签名操作（KMS）与生产密钥托管必须由维护者人工闭环 + 安全清单审**。
 *     标 `🔒 待人工闭环` 处不得在未经人工审阅前用于任何面向用户的 release。
 *
 * 机制（摘自 ADR-002 §2.3，权威以 ADR 为准）：
 *  - 签什么：bundle 规范化内容摘要（manifest + entry 源码 + 资产）+ **裁定档位**，detached 签名。
 *  - 规范化（§2.3b 钉死）：文件按路径**字典序**、内容 **UTF-8 NFC**、换行 **LF**；文件末尾不追加也不剥除 newline。
 *  - digest：`SHA-256(SHA-256(file1) || SHA-256(file2) || ...)`（先各文件哈希，拼接后再 SHA-256）。
 *  - 签名：**Ed25519**（RFC 8032）over `{ digest, tier, adapterId, adapterVersion }` 的规范化 payload。
 *  - 私钥托管：**OIDC → 云 KMS 委托签名**（AWS KMS，永不导出/入仓）。dev 过渡期允许本地 Ed25519，
 *    **首次 release 前 KMS 必须就位**（§2.3 硬 deadline）。
 *  - 校验：核心加载前对 **active** pin 公钥验签，fail-closed。
 *
 *   运行：cd tools && npm run sign -- --adapter=../adapters/school-x --tier=official   # 🔒 dev 后端
 *         cd tools && npx tsx src/signer/index.ts digest --adapter=../adapters/school-x
 *         cd tools && npx tsx src/signer/index.ts verify --adapter=../adapters/school-x --pubkey=...
 */

import {
  readFileSync,
  readdirSync,
  writeFileSync,
  existsSync,
  statSync,
  realpathSync,
} from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, sign as edSign, verify as edVerify, KeyObject } from "node:crypto";

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
  const walk = (d: string): void => {
    for (const entry of readdirSync(d).sort()) {
      const p = join(d, entry);
      const rel = relative(dir, p);
      if (BUNDLE_EXCLUDE.test(rel)) continue;
      if (statSync(p).isDirectory()) walk(p);
      else if (BUNDLE_INCLUDE.test(entry)) out.push(rel);
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

// ---- 签名后端（私钥操作接缝；生产 = KMS，🔒 人工闭环） ----

/**
 * 签名后端：把「私钥签名操作」抽象为接缝。
 *  - 生产：`KmsSignBackend`（OIDC→AWS KMS，**未实现**，🔒 首次 release 前人工闭环）。
 *  - dev 过渡：`LocalDevSignBackend`（本地 Ed25519 私钥，**仅 dev/staging**，产物不分发终端用户）。
 */
export interface SignBackend {
  readonly keyId: string;
  /** 对 payload 字节做 Ed25519 签名，返回 base64。私钥永不出后端。 */
  sign(payload: Buffer): Promise<string>;
}

/**
 * 🔒🔒 生产 KMS 后端——**未实现**。
 * 必须由维护者人工实现：GitHub OIDC → AWS KMS 短时联合身份 → 单次签名操作（拿签名，不拿密钥），
 * 配合受保护 Environment + required reviewer + 仅 tag 触发（ADR-002 §2.3）。
 */
export class KmsSignBackend implements SignBackend {
  readonly keyId: string;
  constructor(keyId: string) {
    this.keyId = keyId;
  }
  async sign(_payload: Buffer): Promise<string> {
    throw new Error(
      "🔒 KmsSignBackend 未实现：生产签名须经 OIDC→KMS，由维护者人工闭环（ADR-002 §2.3，红线 #4）。",
    );
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
      throw new Error("🔒 LocalDevSignBackend 禁止在生产使用（红线 #4）；生产须走 KmsSignBackend。");
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
 * 对 adapter 目录验签：重算 digest → 用 pin 公钥验 Ed25519 → 校验 tier/adapterId 与签名载荷一致。
 * 返回裁定档位（fail 时 throw）。核心加载前调用（fail-closed）。
 */
export function verifyAdapter(dir: string, publicKey: KeyObject): TrustTier {
  const sigPath = join(dir, "signature.json");
  if (!existsSync(sigPath)) {
    throw new Error("无 signature.json → 按 sideload 处理（release 拒绝加载）。");
  }
  const sig = JSON.parse(readFileSync(sigPath, "utf-8")) as SignatureFile;
  if (sig.algorithm !== "ed25519") throw new Error(`不支持的签名算法：${sig.algorithm}`);

  const digest = computeBundleDigest(dir);
  if (digest !== sig.digest) {
    throw new Error("bundle digest 与签名不符（内容被篡改或签名过期）→ fail-closed。");
  }
  const payload = serializePayload(sig);
  const ok = edVerify(null, payload, publicKey, Buffer.from(sig.signature, "base64"));
  if (!ok) throw new Error("Ed25519 验签失败 → fail-closed。");

  return sig.tier;
}

// ---- 签名流程 ----

/**
 * 对 adapter 目录签名并写 signature.json。
 * tier 是**签名流程显式注入的裁定档位**（§2.2），非取自 manifest 自报。
 * 🔒 「签 official」是需显式人工批准的动作——本函数不做批准，批准由 KMS 侧 required reviewer 承担。
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

  // sign / verify 是 🔒 承重路径：dev 后端接线与密钥加载留给维护者人工闭环。
  // 骨架不在此自动加载任意私钥/公钥（避免 AI 独自闭环签名操作）。
  console.log("🔒 signer 骨架：");
  console.log("  - `digest` 已可用（确定性 bundle 摘要，无密钥）。");
  console.log("  - `sign` / `verify` 的密钥加载与 KMS 接线由维护者人工闭环（ADR-002 §2.3，AGENTS.md §1）。");
  console.log("  - 可编程 API：signAdapter() / verifyAdapter() / computeBundleDigest()。");
  process.exitCode = 2;
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
