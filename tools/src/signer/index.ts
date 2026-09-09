/**
 * signer：官方 adapter 签名 / 验签 / 吊销（ADR-002 §2.3–§2.4）。
 *
 * 🔒🔒 安全敏感承重路径（红线 #4：DEPLOY 仅运行官方签名 adapter）。
 *
 * 注：本模块只签 adapter bundle。transport 不经此路径——它编译期编入二进制，
 * 由平台应用签名承担完整性（ADR-003 §2.3，2026-09-09 修订）。
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

import { sign as edSign, type KeyObject } from "node:crypto";
import { lstatSync, readdirSync, realpathSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
// CLI-only：digest 子命令走 bundle 层唯一那条实现（模块顶层无循环依赖——
// envelope.ts 只从本模块取无方向性原语，不反向依赖 CLI）。

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

/**
 * **显式排除名单**（本身进版本控制，故每次增删都过 code review）。
 *
 * `.md`：adapter 目录里的 README / COVERAGE 等文档面向**贡献者与审查者**，运行时从不读取。
 * 排除 ≠ 夹带面：被排除的文件**根本不进 bundle**，永远到不了客户端；纳入才是把几十 KB
 * 无用字节推给每个终端用户。与「全量文件承诺」（[CollectOptions.assertFullCommitment]）不冲突——
 * 该纪律要求的是「目录里的每个文件都被**显式裁决过**」，而非「每个文件都必须被签」。
 */
const BUNDLE_EXCLUDE = /(^|\/)(signature\.json|node_modules|\.git|fixtures)(\/|$)|\.md$/i;

export interface CollectOptions {
  /**
   * **全量文件承诺**（ADR-002 §2.3 纪律 5，digest v2 起默认要求）：目录内存在既不在
   * `BUNDLE_INCLUDE` 也不在 `BUNDLE_EXCLUDE` 的文件时**拒签**，取代原先的静默剔除。
   *
   * 否则 digest 只承诺「这些文件」，不承诺「**只有**这些文件」——目录侧路径
   * （DEV-Sideload、ADR-033 本地导入）即存在夹带面：塞一个 `.bin` 进去，签名照过。
   */
  assertFullCommitment?: boolean;
}

/** 递归收集 adapter 目录下参与签名的文件（相对路径），按字典序排序。 */
export function collectBundleFiles(dir: string, opts: CollectOptions = {}): string[] {
  const out: string[] = [];
  const uncommitted: string[] = [];
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
      else if (stat.isFile()) {
        if (BUNDLE_INCLUDE.test(entry)) out.push(rel);
        else uncommitted.push(rel);
      }
    }
  };
  walk(dir);
  if (opts.assertFullCommitment === true && uncommitted.length > 0) {
    throw new Error(
      `拒签：目录内存在未进 envelope 的文件（全量文件承诺，ADR-002 §2.3）——` +
        `${uncommitted.join(", ")}。要么纳入 BUNDLE_INCLUDE，要么按 BUNDLE_EXCLUDE 显式排除` +
        `（排除名单本身进版本控制）。`,
    );
  }
  return out.sort(); // 字典序（§2.3b）
}

/**
 * **断言**文件内容已规范化：UTF-8 NFC + LF 换行。**不符即抛（digest v2 起拒绝而非改写）**。
 *
 * **为何改判**（原为 `canonicalizeContent`，哈希前静默改写）：改写使多份不同的磁盘文件映射到
 * 同一 digest，签名因此**不唯一标识磁盘上的真实字节**，也迫使 🔒 Dart 加载器必须论证自己为何
 * 不做 NFC。改为拒绝后，签名与磁盘字节一一对应，Dart 侧不引入任何 Unicode 规范化实现。
 *
 * 二进制资产（png 等）不做文本规范化：非 UTF-8 可解码的内容直接放行。
 */
export function assertCanonical(rel: string, raw: Buffer): void {
  const text = raw.toString("utf-8");
  if (!Buffer.from(text, "utf-8").equals(raw)) return; // 真二进制，跳过文本规范化断言
  if (text.includes("\r")) {
    throw new Error(`拒签：${rel} 含 CR/CRLF 换行，须为 LF（ADR-002 §2.3，构建期检查不改写）`);
  }
  if (text.normalize("NFC") !== text) {
    throw new Error(`拒签：${rel} 非 UTF-8 NFC 规范化（ADR-002 §2.3，构建期检查不改写）`);
  }
}

// ---- 签名域分隔（ADR-002 §2.3，2026-09-01 新增） ----

/**
 * 同一把密钥下的多个签名协议必须**显式隔离**：
 *
 *     签名输入 = contextTag ‖ 0x00 ‖ 被签字节
 *
 * v2 之前，bundle 载荷 / catalog / revocation 三者只靠「JSON 形状恰好互不满足对方 schema」
 * **偶然隔开**——第四个签名对象出现时随时可能撞上。**传输对象不变**，前缀只加在签/验输入上，
 * 故「验字节 → 再 parse」的取向不受影响。
 *
 * **新增任何签名对象必须分配一个新 tag，不得复用。**
 */
export const CONTEXT_TAG_BUNDLE = "elecon.bundle-payload/2";
export const CONTEXT_TAG_CATALOG = "elecon.catalog/1";
export const CONTEXT_TAG_REVOCATION = "elecon.revocation/1";

/** 给待签字节加域分隔前缀。 */
export function withContext(tag: string, bytes: Buffer): Buffer {
  return Buffer.concat([Buffer.from(tag, "utf-8"), Buffer.from([0x00]), bytes]);
}

/**
 * 规范化签名 payload → **待签字节**（含 `elecon.bundle-payload/2` 域分隔前缀）。
 *
 * `digest` 是 envelope 字节的哈希（digest v2）。`tier` 是签名流程注入的裁定档位、
 * **不在 envelope 内**（故 bundle 保留「载荷套一层」，而 catalog/revocation 直签字节）。
 */
export function serializePayload(p: SignaturePayload): Buffer {
  // 固定键序，避免 JSON 键序漂移影响签名/验签。
  const canonical = JSON.stringify({
    adapterId: p.adapterId,
    adapterVersion: p.adapterVersion,
    digest: p.digest,
    tier: p.tier,
  });
  return withContext(CONTEXT_TAG_BUNDLE, Buffer.from(canonical, "utf-8"));
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
 * **返回裸 64 字节 Ed25519 签名**（非 OpenPGP packet 封装），以对齐验端 `openBundle` 的 Ed25519 验签。
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

// ---- v1 目录式 API 已删除（digest v2） ----
//
// `computeBundleDigest(dir)` / `verifyAdapter(dir)` / `signAdapter(dir)` 是 digest v1 的
// 目录式接口：它们把「收集文件 → 逐个哈希 → 拼接再哈希」写在一起，而 v2 的 digest 是
// **envelope 序列化字节的哈希**，目录只是构建 envelope 的一个来源。保留一份「从目录直接算
// digest」的旁路等于**第二条 digest 实现**，必然与 `buildEnvelope` 漂移——正是 §2.5 给 catalog
// 定「字节精确、不重新规范化序列化」时要消除的那类东西。
//
// 替代：`buildEnvelope(dir)`（bundle/envelope.ts）→ `signEnvelope(built, tier, backend)`
// （bundle/sign.ts）→ `packBundle(bytes, sig, blobs)` / `openBundle(gz, key)`（bundle/package.ts）。
// 本模块只保留**无方向性的原语**：文件收集、规范化断言、域分隔、payload 序列化、签名后端。

// ---- CLI ----

function argOf(name: string): string | undefined {
  const p = process.argv.find((a) => a.startsWith(`--${name}=`));
  return p?.slice(name.length + 3);
}

async function main(): Promise<void> {
  const cmd = process.argv[2];
  const dir = argOf("adapter");

  if (cmd === "digest") {
    // digest v2 = SHA-256(envelopeBytes)。经 buildEnvelope 走**唯一那条**实现，
    // 不另开「从目录直接算」的旁路（否则必然漂移）。
    //
    // **动态 import**：`bundle/envelope.ts` 依赖本模块的原语（collectBundleFiles /
    // assertCanonical），本模块若在顶层反向静态 import 它就成了 ESM 循环依赖。依赖方向
    // 应当是单向的「原语 ← 组装」；这条 CLI 分支是唯一的反向引用，且只在**命令实际被调用时**
    // 才需要，故以动态 import 隔开，而不是让整个模块图为一个子命令背上环。
    if (!dir) throw new Error("用法：digest --adapter=<dir>");
    const { buildEnvelope, envelopeDigest } = await import("../bundle/envelope.js");
    console.log(envelopeDigest(buildEnvelope(dir).bytes));
    return;
  }

  // sign / verify 是 🔒 承重路径：本 CLI **刻意不做**「自动加载某把私钥/公钥就签」——
  // 密钥的选取与出签须是维护者的显式动作（ADR-002 §2.3「签 official = 需显式批准的动作」）。
  console.log("🔒 signer CLI：");
  console.log("  - `digest` 已可用（确定性 bundle 摘要，无密钥）。");
  console.log("  - 硬件出签：`npx tsx src/signer/pkcs11.ts selftest`（PIN + 触碰）；");
  console.log("    密钥 ceremony 见 docs/reference/signing_ceremony.md（永不自动化）。");
  console.log("  - `sign` / `verify` 无 CLI 子命令：请在显式脚本里调可编程 API，");
  console.log("    避免「随手一条命令就签出 official」（ADR-002 §2.3，AGENTS.md §1）。");
  console.log("  - 可编程 API：buildEnvelope() / signEnvelope() / packBundle() / openBundle()。");
  process.exitCode = 2;
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main().catch((err: unknown) => {
    console.error((err as Error).message);
    process.exitCode = 1;
  });
}
