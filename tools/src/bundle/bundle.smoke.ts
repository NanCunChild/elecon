/**
 * bundle 信封 v2 + 传输封套 冒烟（ADR-018 §2.9.1，digest v2）。
 *
 * 用真实 adapter（school-xidian）驱动**签发 → 传输 → 收端**的完整往返：
 *   ① buildEnvelope：descriptor 形态、blob 按内容寻址、身份取自 manifest.json、排除 fixtures
 *   ② digest 只认字节：envelopeDigest(bytes) 稳定；**且不存在「对象 → 重序列化 → 哈希」的旁路**
 *   ③ packBundle → openBundle 往返一致 + 产物是 gzip（magic 1f 8b）
 *   ④ 🔒 Ed25519 验签：dev keypair 签 → 过；篡改 blob / 错公钥 → 拒（fail-closed）
 *   ⑤ inspectBundle（keyless 签发侧自验）：跳过第 6 步，其余照跑
 *   ⑥ 🔒 身份混淆：内容 A / 身份 B → 拒（ADR-002 §2.2 身份三方一致）
 *
 * **负例的系统性覆盖在 `path-binding.redcase.ts`**（A/B/C/D + E1–E8，14 项验收门）；
 * 本文件只跑「真实 adapter 能走通」这条正路 + 几个最贴身的负例。
 *
 *   运行：cd tools && npx tsx src/bundle/bundle.smoke.ts
 */

import { strict as assert } from "node:assert";
import { generateKeyPairSync } from "node:crypto";
import { fileURLToPath } from "node:url";
import { LocalDevSignBackend } from "../signer/index.js";
import { requireAdapterDir } from "../test-utils/adapter-path.js";
import {
  type BlobTable,
  buildEnvelope,
  envelopeDigest,
  fileBytesByPath,
  parseEnvelope,
  serializeEnvelope,
  sha256Hex,
} from "./envelope.js";
import { inspectBundle, openBundle, packBundle, verifyBundleIntegrity } from "./package.js";
import { signEnvelope } from "./sign.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const dir = requireAdapterDir(repoRoot, "school-xidian");

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const backend = new LocalDevSignBackend(privateKey, "dev-local");

// ① 从目录构建：descriptor + blob 表
const built = buildEnvelope(dir);
{
  assert.equal(built.envelope.bundleFormat, "elecon-bundle/3", "应是 v3 格式（masker 断代，ADR-026 §2.7.1）");
  assert.equal(built.envelope.adapterId, "school-xidian", "身份应取自 manifest.json，非调用方");
  assert.ok(built.envelope.adapterVersion.length > 0, "envelope 顶层应带 adapterVersion");

  const paths = built.envelope.files.map((f) => f.path);
  assert.ok(paths.includes("manifest.json") && paths.includes("index.js"), "应含 manifest.json + index.js");
  assert.ok(!paths.some((p) => p.startsWith("fixtures")), "不应含 fixtures（BUNDLE_EXCLUDE）");
  assert.deepEqual(paths, [...paths].sort(), "files 须按路径字典序（顺序在签名范围内）");

  // descriptor 不含内容——内容一律走 blob 表按 sha256 寻址（v2 的容器/清单分离）。
  for (const f of built.envelope.files) {
    assert.deepEqual(Object.keys(f).sort(), ["path", "sha256", "size"], "descriptor 恰含三字段");
    const blob = built.blobs[f.sha256];
    assert.ok(blob !== undefined, `blob 表应含 ${f.path}`);
    assert.equal(blob.length, f.size, `${f.path} 的 size 应等于真实字节数`);
    assert.equal(sha256Hex(blob), f.sha256, `${f.path} 的 sha256 应命中内容`);
  }

  // blob 表按**内容**寻址：内容相同的两个路径共用一个 blob，故 blob 数 ≤ 文件数。
  assert.ok(
    Object.keys(built.blobs).length <= built.envelope.files.length,
    "blob 表按内容寻址，条目数不应超过文件数",
  );
  console.log("  ✓ buildEnvelope：descriptor 形态 / 内容寻址 blob / 身份取自 manifest / 字典序");
}

// ② digest 只认字节
const digest = envelopeDigest(built.bytes);
{
  assert.match(digest, /^[0-9a-f]{64}$/, "digest 应为 64 位小写 hex");
  assert.equal(envelopeDigest(built.bytes), digest, "同一串字节两次 digest 必须一致");

  // 纪律 1 的可执行形式：**再序列化一次**必须得到逐字节相同的结果，否则
  // 「解析→重序列化→哈希」与「直接哈希收到的字节」会分叉，而只有后者是安全的。
  assert.ok(
    serializeEnvelope(built.envelope).equals(built.bytes),
    "serializeEnvelope 须确定性：重新序列化应逐字节等于 buildEnvelope 的字节",
  );
  // parse 回来再序列化，仍须逐字节相同（往返稳定 → 没有隐藏的键序/空白自由度）。
  const reparsed = parseEnvelope(built.bytes);
  assert.ok(reparsed.bytes.equals(built.bytes), "ParsedEnvelope 须恒携带原始字节");
  assert.ok(serializeEnvelope(reparsed.envelope).equals(built.bytes), "parse → serialize 须字节稳定");
  console.log("  ✓ envelopeDigest 只认字节 + 序列化确定性（parse↔serialize 字节稳定）");
}

// ③ pack → open 往返
const signature = await signEnvelope(built, "official", backend);
assert.equal(signature.digest, digest, "signEnvelope 的 digest 应 = envelopeDigest(bytes)");
assert.equal(signature.adapterId, "school-xidian", "签名身份应取自 envelope 顶层");
assert.equal(signature.keyId, "dev-local", "keyId 应来自 backend");

const packed = packBundle(built.bytes, signature, built.blobs);
{
  assert.equal(packed[0], 0x1f, "packBundle 产物应为 gzip（magic 0x1f）");
  assert.equal(packed[1], 0x8b, "packBundle 产物应为 gzip（magic 0x8b）");

  const opened = openBundle(packed, publicKey);
  assert.ok(opened.ok, `openBundle 应通过：${opened.ok ? "" : opened.reason}`);
  assert.ok(opened.value.envelopeBytes.equals(built.bytes), "往返后 envelopeBytes 应逐字节一致");
  assert.deepEqual(opened.value.envelope, built.envelope, "往返后 envelope 应结构一致");
  assert.equal(opened.value.tier, "official", "应返回裁定档位 official");
  assert.equal(
    fileBytesByPath(opened.value.envelope, opened.value.blobs, "manifest.json")?.toString("utf-8"),
    built.blobs[built.envelope.files.find((f) => f.path === "manifest.json")!.sha256]!.toString("utf-8"),
    "按路径取 manifest 字节应与签发侧一致",
  );
  console.log("  ✓ packBundle → openBundle 往返一致（gzip，字节级）");
}

// ④ 🔒 篡改 / 错公钥 → 拒
{
  // 篡改 blob 内容：blob 键不变但字节变了 → 第 10 步（哈希命中）抓到。
  const tamperedBlobs: BlobTable = { ...built.blobs };
  const entryDesc = built.envelope.files.find((f) => f.path === "index.js")!;
  tamperedBlobs[entryDesc.sha256] = Buffer.concat([
    built.blobs[entryDesc.sha256]!,
    Buffer.from("// tamper\n", "utf-8"),
  ]);
  const bad = openBundle(packBundle(built.bytes, signature, tamperedBlobs), publicKey);
  assert.equal(bad.ok, false, "篡改 blob 内容必须拒");
  assert.match(!bad.ok ? bad.reason : "", /哈希|长度/, "失败原因应指向内容不符");

  // 篡改 envelope 字节：digest 在第 5 步（验签之前）就对不上。
  const tamperedBytes = Buffer.from(built.bytes.toString("utf-8").replace("index.js", "index.jZ"), "utf-8");
  const bad2 = openBundle(packBundle(tamperedBytes, signature, built.blobs), publicKey);
  assert.equal(bad2.ok, false, "篡改 envelope 字节必须拒");
  assert.match(!bad2.ok ? bad2.reason : "", /digest/, "应在 digest 比对处就被拒（早于验签）");

  // 错公钥
  const { publicKey: otherKey } = generateKeyPairSync("ed25519");
  assert.equal(openBundle(packed, otherKey).ok, false, "错公钥必须拒");

  // 算法降级
  const bad3 = openBundle(
    packBundle(built.bytes, { ...signature, algorithm: "rsa-sha256" as never }, built.blobs),
    publicKey,
  );
  assert.equal(bad3.ok, false, "非 ed25519 算法必须拒");
  assert.match(!bad3.ok ? bad3.reason : "", /算法/, "失败原因应指明算法");

  console.log("  ✓ 篡改 blob / 篡改 envelope 字节 / 错公钥 / 算法降级 → 全拒（fail-closed）");
}

// ⑤ inspectBundle：签发侧 keyless 自验
{
  const r = inspectBundle(packed);
  assert.ok(r.ok, `inspectBundle 应通过：${r.ok ? "" : r.reason}`);
  assert.equal(r.value, digest, "inspectBundle 应返回 digest");

  // keyless 自验**不做**信任裁定，但结构性缺陷照抓：多塞一个 blob → 第 9 步拒。
  const smuggled: BlobTable = { ...built.blobs };
  const extra = Buffer.from("夹带\n", "utf-8");
  smuggled[sha256Hex(extra)] = extra;
  const r2 = inspectBundle(packBundle(built.bytes, signature, smuggled));
  assert.equal(r2.ok, false, "keyless 自验也须抓到夹带的 blob");
  console.log("  ✓ inspectBundle（keyless 自验，跳过第 6 步）：正例过 / 夹带拒");
}

// ⑥ 🔒 身份混淆：digest 真、Ed25519 真，唯独身份不符（ADR-002 §2.2）
{
  const forged = await (async () => {
    const { serializePayload } = await import("../signer/index.js");
    const payload = serializePayload({
      adapterId: "school-evil",
      adapterVersion: "9.9.9",
      tier: "official",
      digest,
    });
    return {
      adapterId: "school-evil",
      adapterVersion: "9.9.9",
      tier: "official" as const,
      digest,
      signature: await backend.sign(payload),
      keyId: "dev-local",
      algorithm: "ed25519" as const,
    };
  })();

  // digest 本身是对的、签名也是真私钥签的——唯一拦得住它的就是身份三方一致。
  assert.equal(verifyBundleIntegrity(built.bytes, forged).ok, true, "digest 本身是对的（前提成立）");
  const r = openBundle(packBundle(built.bytes, forged, built.blobs), publicKey);
  assert.equal(r.ok, false, "身份与 manifest 不符必须拒（否则身份混淆）");
  assert.match(!r.ok ? r.reason : "", /身份/, "失败原因应指明身份不符");
  console.log("  ✓ 身份混淆（内容 A / 身份 B）被拒（fail-closed，ADR-002 §2.2）");
}

console.log("\nbundle smoke 全部通过 ✅");
