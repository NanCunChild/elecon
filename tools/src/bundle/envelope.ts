/**
 * bundle 信封 v2（ADR-018 §2.9.1，digest v2）—— **清单 + 签名对象**。
 *
 * v1 的 envelope 同时当**容器**（装文件字节）和**清单**（声明有哪些文件），病根是「清单」被
 * 「容器」吞掉，唯一没被签的字段恰是 `path` → 保序重命名可让 official 签名背书恶意入口
 * （见 `docs/archive/bundle_digest_v1_superseded.md`）。v2 把容器拆出去：
 *
 *     envelope  = { bundleFormat, adapterId, adapterVersion, files:[{path,size,sha256}] }
 *     digest    = SHA-256( envelopeBytes )        envelopeBytes = UTF-8(JSON(envelope))
 *     on-wire   = gzip(JSON({ envelopeB64, signature, blobs }))   ← 传输封套，不是信封
 *
 * 路径 / 编码 / 顺序 / 文件个数 / `bundleFormat` / 身份**全部落在签名范围内**，因为它们都在
 * 那串被哈希的字节里。文件字节改由**按内容哈希寻址**的 blob 表承载。
 *
 * **不可分割的配套纪律**（ADR-002 §2.3，缺一条即退化）：
 *  1. **签名对象以不透明字节上线**——验端哈希**收到的那一串**，任何路径下都不得
 *     「解析成对象 → 重新序列化 → 再哈希」（那等于把 canonical JSON 的全部漂移面请回来）。
 *     故 [ParsedEnvelope] 恒携带其 `bytes`，[envelopeDigest] 只接受字节、不接受对象。
 *  2. **验签先于解析**——见 `package.ts` 的 `openBundle`。
 *  3. **卫生闸门在验签之后**——[assertPathHygiene]。
 *  4. **blob 集合精确相等**——[assertBlobSetExact]，多一个即夹带通道。
 *  5. **全量文件承诺**——[buildEnvelope] 对目录内未进 envelope 的文件**拒签**。
 *  6. **`bundleFormat` 严格相等**——[parseEnvelope]。
 *
 * **keyless**（无私钥，纯确定性），可安全测试。签名本身见 signer（🔒）。
 *
 * 🔒 承重路径（红线 #4）。按 AGENTS.md §1，本文件与其测试不得由 AI 独自闭环。
 */

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { assertCanonical, collectBundleFiles } from "../signer/index.js";

/** 当前唯一在役的 bundle 格式标识。v1（`elecon-bundle/1`）路径已整体删除，不设双读。 */
export const BUNDLE_FORMAT = "elecon-bundle/2";

/** 单个文件在清单里的**描述符**——不含内容，内容由 blob 表按 `sha256` 寻址。 */
export interface EnvelopeFileDescriptor {
  /** 相对 adapter 目录的路径。签名范围内。 */
  path: string;
  /** 文件字节数。**先按它界定再解码**，防 endless-data（同 TUF 携带 length 的理由）。 */
  size: number;
  /** 文件内容的 SHA-256（小写 hex）。blob 表的寻址键。 */
  sha256: string;
}

/** 解析后的 bundle 信封。 */
export interface BundleEnvelope {
  bundleFormat: string;
  /** 权威身份的**核对副本**——权威值仍在 `manifest.json`；此处只用于核对，不用于裁定。 */
  adapterId: string;
  adapterVersion: string;
  files: EnvelopeFileDescriptor[];
}

/**
 * 信封 + 它的**原始字节**。字节是第一性的：digest 与签名都只认这串字节。
 * 任何拿到 [ParsedEnvelope] 的代码都不得重新序列化 `envelope` 去算 digest。
 */
export interface ParsedEnvelope {
  readonly envelope: BundleEnvelope;
  readonly bytes: Buffer;
}

/** blob 表：`sha256`（小写 hex）→ 原始字节。 */
export type BlobTable = Record<string, Buffer>;

export function sha256Hex(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/**
 * **显式确定性序列化器**：固定键序、无多余空白、无缩进。
 *
 * 刻意不依赖 `JSON.stringify` 对对象字面量的插入序——那是"碰巧稳定"，不是保证。
 * 键序即签名范围的一部分，必须由本函数唯一决定。
 */
export function serializeEnvelope(env: BundleEnvelope): Buffer {
  const files = env.files.map((f) => ({ path: f.path, size: f.size, sha256: f.sha256 }));
  const canonical = {
    bundleFormat: env.bundleFormat,
    adapterId: env.adapterId,
    adapterVersion: env.adapterVersion,
    files,
  };
  return Buffer.from(JSON.stringify(canonical), "utf-8");
}

/**
 * digest v2 = `SHA-256(envelopeBytes)`。
 *
 * **只接受字节**——这是纪律 1 的类型级落实：没有 `envelopeDigest(env: BundleEnvelope)` 重载，
 * 调用方无从"解析成对象再哈希"。
 */
export function envelopeDigest(envelopeBytes: Buffer): string {
  return sha256Hex(envelopeBytes);
}

const RE_SHA256 = /^[0-9a-f]{64}$/;
const NUL = "\u0000";

/**
 * 合法路径段：`[A-Za-z0-9._-]`，至少一字符。
 *
 * **为何收紧到 ASCII 子集**：本侧靠 `String.normalize("NFC")` 拒非 NFC 路径，而 🔒 Dart
 * 加载器**无内建 Unicode NFC**。若 Dart 略过该检查，两端的卫生闸门就对同一份 bundle 给出
 * 不同判定——这正是 ADR-002 §3 风险 5（跨语言实现漂移）的活样本，且方向是 fail-open；
 * 给 Dart 引入第三方 NFC 实现只是把漂移面换个地方。
 *
 * 故改从源头消灭：本集合内**不存在**非 NFC 形式，也不存在同形异码与 RTL override 之类的
 * 显示欺骗，于是「要不要做 NFC」在两端都不再是问题。下面的 NFC 断言因此成了纯冗余的
 * 第二道锁，保留是因为它**零成本**且能在字符集规则将来被放宽时立刻兜住。
 *
 * 代价：adapter 内文件名不得使用非 ASCII。现有全部 adapter 均已满足，且这是**内部打包路径**，
 * 与任何面向用户的展示文本无关。
 */
const RE_SEGMENT = /^[A-Za-z0-9._-]+$/;

/**
 * 严格解析 envelope 字节。**验签之后才允许调用**（纪律 2）。
 *
 * 严格性是防降级面：多余字段、缺字段、错类型、`bundleFormat` 不等一律拒。
 */
export function parseEnvelope(bytes: Buffer): ParsedEnvelope {
  let raw: unknown;
  try {
    raw = JSON.parse(bytes.toString("utf-8"));
  } catch (err) {
    throw new Error(`envelope 不是合法 JSON：${(err as Error).message}（fail-closed）`);
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("envelope 不是对象（fail-closed）");
  }
  const o = raw as Record<string, unknown>;
  const allowed = new Set(["bundleFormat", "adapterId", "adapterVersion", "files"]);
  for (const k of Object.keys(o)) {
    if (!allowed.has(k)) throw new Error(`envelope 含未知字段 ${JSON.stringify(k)}（fail-closed）`);
  }
  if (o.bundleFormat !== BUNDLE_FORMAT) {
    throw new Error(
      `bundleFormat 不符：期望 ${BUNDLE_FORMAT}，得 ${JSON.stringify(o.bundleFormat)}（fail-closed）`,
    );
  }
  if (typeof o.adapterId !== "string" || o.adapterId.length === 0) {
    throw new Error("envelope 缺 adapterId（fail-closed）");
  }
  if (typeof o.adapterVersion !== "string" || o.adapterVersion.length === 0) {
    throw new Error("envelope 缺 adapterVersion（fail-closed）");
  }
  if (!Array.isArray(o.files)) throw new Error("envelope.files 不是数组（fail-closed）");
  const files: EnvelopeFileDescriptor[] = o.files.map((entry, i) => {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      throw new Error(`envelope.files[${i}] 不是对象（fail-closed）`);
    }
    const e = entry as Record<string, unknown>;
    for (const k of Object.keys(e)) {
      if (k !== "path" && k !== "size" && k !== "sha256") {
        throw new Error(`envelope.files[${i}] 含未知字段 ${JSON.stringify(k)}（fail-closed）`);
      }
    }
    if (typeof e.path !== "string") throw new Error(`envelope.files[${i}].path 非字符串（fail-closed）`);
    if (typeof e.size !== "number" || !Number.isSafeInteger(e.size) || e.size < 0) {
      throw new Error(`envelope.files[${i}].size 非非负整数（fail-closed）`);
    }
    if (typeof e.sha256 !== "string" || !RE_SHA256.test(e.sha256)) {
      throw new Error(`envelope.files[${i}].sha256 非 64 位小写 hex（fail-closed）`);
    }
    return { path: e.path, size: e.size, sha256: e.sha256 };
  });
  return {
    envelope: {
      bundleFormat: o.bundleFormat,
      adapterId: o.adapterId,
      adapterVersion: o.adapterVersion,
      files,
    },
    bytes,
  };
}

// ---- 路径卫生闸门（纪律 3：验签**之后**、使用**之前**） ----

/**
 * 路径卫生。**签名只证明发布者确实想要这些路径，不证明这些路径安全**——
 * 哈希再多字节也不会让 `../../` 变安全。
 *
 * **重复路径不是纯纵深防御**：Dart `List.sort` 不保证稳定而 TS `Array.sort` 保证，
 * 同名条目会造成跨语言解析差分（ADR-002 §3 风险 5）。
 */
export function assertPathHygiene(env: BundleEnvelope): void {
  const seen = new Set<string>();
  for (const f of env.files) {
    const p = f.path;
    if (p.length === 0) throw new Error("路径为空（fail-closed）");
    if (p.includes(NUL)) throw new Error(`路径含 NUL 字节：${JSON.stringify(p)}（fail-closed）`);
    if (p.includes("\\")) throw new Error(`路径含反斜杠：${JSON.stringify(p)}（fail-closed）`);
    if (p.startsWith("/")) throw new Error(`绝对路径（POSIX）：${p}（fail-closed）`);
    if (/^[A-Za-z]:/.test(p)) throw new Error(`绝对路径（Windows 盘符）：${p}（fail-closed）`);
    if (p.endsWith("/")) throw new Error(`尾随分隔符：${p}（fail-closed）`);
    for (const seg of p.split("/")) {
      if (seg === "" || seg === "." || seg === "..") {
        throw new Error(`非法路径段 ${JSON.stringify(seg)} 于 ${p}（fail-closed）`);
      }
      // 字符集白名单（而非逐类黑名单）：反斜杠、NUL、非 ASCII 全落在这一条里。
      if (!RE_SEGMENT.test(seg)) {
        throw new Error(`路径段 ${JSON.stringify(seg)} 含 [A-Za-z0-9._-] 之外的字符于 ${p}（fail-closed）`);
      }
    }
    if (p.normalize("NFC") !== p) throw new Error(`路径非 NFC 规范化：${p}（fail-closed）`);
    if (seen.has(p)) throw new Error(`重复路径：${p}（fail-closed）`);
    seen.add(p);
  }
}

// ---- blob 校验（纪律 4） ----

/**
 * blob 集合**精确相等**：descriptor 的 `sha256` 集合 ↔ blob 键集合一一对应。
 *
 * **这是 v2 唯一新增的、可以搞砸的不变量**：少一个会被 [assertBlobsMatchDescriptors] 抓到，
 * **多一个不会**——必须由本函数显式拒绝，否则就是夹带通道。
 */
export function assertBlobSetExact(env: BundleEnvelope, blobs: BlobTable): void {
  const want = new Set(env.files.map((f) => f.sha256));
  const have = new Set(Object.keys(blobs));
  for (const h of have) {
    if (!RE_SHA256.test(h)) {
      throw new Error(`blob 键非 64 位小写 hex：${JSON.stringify(h)}（fail-closed）`);
    }
    if (!want.has(h)) {
      throw new Error(`blob 表多出未被引用的条目 ${h.slice(0, 12)}…（夹带通道，fail-closed）`);
    }
  }
  for (const h of want) {
    if (!have.has(h)) {
      throw new Error(`blob 表缺 ${h.slice(0, 12)}…（descriptor 引用了不存在的 blob，fail-closed）`);
    }
  }
}

/** 逐文件：长度**精确等于** `size`，且 SHA-256 命中 descriptor。 */
export function assertBlobsMatchDescriptors(env: BundleEnvelope, blobs: BlobTable): void {
  for (const f of env.files) {
    const blob = blobs[f.sha256];
    if (blob === undefined) throw new Error(`blob 缺失：${f.path}（fail-closed）`);
    if (blob.length !== f.size) {
      throw new Error(`${f.path} 长度 ${blob.length} ≠ descriptor.size ${f.size}（fail-closed）`);
    }
    const actual = sha256Hex(blob);
    if (actual !== f.sha256) {
      throw new Error(
        `${f.path} 内容哈希 ${actual.slice(0, 12)}… ≠ descriptor ${f.sha256.slice(0, 12)}…（fail-closed）`,
      );
    }
  }
}

/** 按路径取文件字节（校验通过后使用）。路径不在清单内 → null。 */
export function fileBytesByPath(env: BundleEnvelope, blobs: BlobTable, path: string): Buffer | null {
  const d = env.files.find((f) => f.path === path);
  if (d === undefined) return null;
  return blobs[d.sha256] ?? null;
}

// ---- 从目录构建（签发侧） ----

export interface BuiltBundle {
  readonly envelope: BundleEnvelope;
  readonly bytes: Buffer;
  readonly blobs: BlobTable;
}

export interface EnvelopeIdentity {
  adapterId: string;
  adapterVersion: string;
}

/** 从 `manifest.json` 字节读**权威身份**。 */
export function readManifestIdentity(manifestBytes: Buffer): EnvelopeIdentity {
  const m = JSON.parse(manifestBytes.toString("utf-8")) as {
    adapterId?: string;
    adapterVersion?: string;
  };
  if (!m.adapterId || !m.adapterVersion) {
    throw new Error("manifest.json 缺 adapterId/adapterVersion（fail-closed）");
  }
  return { adapterId: m.adapterId, adapterVersion: m.adapterVersion };
}

/**
 * 从 adapter 目录构建 envelope + blob 表。
 *
 * **全量文件承诺（纪律 5）**：目录内存在未进 envelope 的文件即**拒签**——由
 * `collectBundleFiles` 的 `assertFullCommitment` 落实。否则 digest 只承诺「这些文件」，
 * 不承诺「只有这些文件」，目录侧路径（DEV-Sideload、ADR-033 本地导入）即存在夹带面。
 *
 * **LF/NFC 不符即拒签（不再静默改写）**：改写会使多份不同的磁盘文件映射到同一 digest，
 * 签名因此不唯一标识磁盘字节，也迫使 🔒 Dart 加载器论证它为何不做 NFC。
 */
export function buildEnvelope(dir: string): BuiltBundle {
  const rels = collectBundleFiles(dir, { assertFullCommitment: true });
  const blobs: BlobTable = {};
  const files: EnvelopeFileDescriptor[] = [];
  for (const rel of rels) {
    const raw = readFileSync(join(dir, rel));
    assertCanonical(rel, raw);
    const hash = sha256Hex(raw);
    blobs[hash] = raw;
    files.push({ path: rel, size: raw.length, sha256: hash });
  }
  const manifestDescriptor = files.find((f) => f.path === "manifest.json");
  if (manifestDescriptor === undefined) {
    throw new Error("bundle 缺 manifest.json → 无法确定权威身份（fail-closed）");
  }
  const manifestBytes = blobs[manifestDescriptor.sha256];
  if (manifestBytes === undefined) throw new Error("内部不变量破坏：manifest blob 缺失");
  const identity = readManifestIdentity(manifestBytes);
  // 顺序即签名范围的一部分：按 UTF-8 code point 字典序。路径已由卫生闸门限制，
  // 与 Dart String.compareTo（UTF-16 码元序）在闸门允许的字符集内一致。
  files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const envelope: BundleEnvelope = {
    bundleFormat: BUNDLE_FORMAT,
    adapterId: identity.adapterId,
    adapterVersion: identity.adapterVersion,
    files,
  };
  assertPathHygiene(envelope);
  return { envelope, bytes: serializeEnvelope(envelope), blobs };
}

/**
 * **身份三方一致**（ADR-002 §2.2 加强版）：`签名载荷` ↔ `envelope 顶层` ↔ `manifest.json 内容`。
 * 任一不符即 fail-closed。`manifest.json` 仍是运行时策略的唯一权威源；envelope 顶层身份
 * **只用于核对，不用于裁定**。
 */
export function assertIdentityTriple(
  env: BundleEnvelope,
  blobs: BlobTable,
  signatureIdentity: EnvelopeIdentity,
): void {
  const manifestBytes = fileBytesByPath(env, blobs, "manifest.json");
  if (manifestBytes === null) {
    throw new Error("bundle 缺 manifest.json → 无法核对身份（fail-closed）");
  }
  const fromManifest = readManifestIdentity(manifestBytes);
  if (env.adapterId !== fromManifest.adapterId || env.adapterVersion !== fromManifest.adapterVersion) {
    throw new Error(
      `envelope 顶层身份 ${env.adapterId}@${env.adapterVersion} ≠ manifest.json ${fromManifest.adapterId}@${fromManifest.adapterVersion}（fail-closed，ADR-002 §2.2）`,
    );
  }
  if (
    signatureIdentity.adapterId !== env.adapterId ||
    signatureIdentity.adapterVersion !== env.adapterVersion
  ) {
    throw new Error(
      `签名载荷身份 ${signatureIdentity.adapterId}@${signatureIdentity.adapterVersion} ≠ envelope 顶层 ${env.adapterId}@${env.adapterVersion}（fail-closed，ADR-002 §2.2）`,
    );
  }
}
