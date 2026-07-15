/**
 * bundle envelope 构建（ADR-018 §2.9）—— **签名对象**的确定性序列化。
 *
 * envelope = `{ bundleFormat, files: [{ path, encoding, content }] }`,files 为 §2.3 BUNDLE_INCLUDE
 * 集（manifest.json / index.js / 运行时资产;fixtures/README 剔除）,按路径字典序、内容经
 * signer 的 `canonicalizeContent`（NFC/LF）规范化。**关键不变量**:
 *
 *     envelopeDigest(buildEnvelope(dir)) === computeBundleDigest(dir)
 *
 * 即 envelope 的 digest 与 signer 目录式双层 SHA-256 **逐字节一致**——签端可从目录签,验端可从
 * envelope 验,二者对同一 adapter 得同一 digest。故 envelope 只是"把要签的文件确定性打包"的载体。
 *
 * **keyless**（无私钥,纯确定性）——同 signer 的 digest 计算,可安全测试。签名本身见 signer（🔒）。
 * adapterId/version 不放 envelope 顶层:权威值在 files 里的 manifest.json（已进 digest），不设二源。
 */

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { canonicalizeContent, collectBundleFiles } from "../signer/index.js";

export const BUNDLE_FORMAT = "elecon-bundle/1";

export interface EnvelopeFile {
  /** 相对 adapter 目录的路径（字典序）。 */
  path: string;
  /** utf-8 文本（规范化后原样）或 base64（二进制资产）。 */
  encoding: "utf-8" | "base64";
  content: string;
}

export interface BundleEnvelope {
  bundleFormat: string;
  files: EnvelopeFile[];
}

function sha256(buf: Buffer): Buffer {
  return createHash("sha256").update(buf).digest();
}

/** envelope file → 其规范化字节（与 signer canonicalizeContent 的输出一致）。 */
export function fileBytes(f: EnvelopeFile): Buffer {
  return f.encoding === "utf-8" ? Buffer.from(f.content, "utf-8") : Buffer.from(f.content, "base64");
}

/** 从 adapter 目录构建 envelope（复用 signer 的文件收集 + 规范化,零漂移）。 */
export function buildEnvelope(dir: string): BundleEnvelope {
  const files: EnvelopeFile[] = collectBundleFiles(dir).map((rel) => {
    const canon = canonicalizeContent(readFileSync(join(dir, rel)));
    const asText = canon.toString("utf-8");
    const isText = Buffer.from(asText, "utf-8").equals(canon);
    return isText
      ? { path: rel, encoding: "utf-8", content: asText }
      : { path: rel, encoding: "base64", content: canon.toString("base64") };
  });
  return { bundleFormat: BUNDLE_FORMAT, files };
}

/**
 * envelope digest = `SHA-256( SHA-256(file1) || SHA-256(file2) || … )`,按路径字典序。
 * 与 signer `computeBundleDigest` **同算法**;两端对同一 adapter 得同一 hex digest。
 */
export function envelopeDigest(env: BundleEnvelope): string {
  const sorted = [...env.files].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const parts = sorted.map((f) => sha256(fileBytes(f)));
  return sha256(Buffer.concat(parts)).toString("hex");
}
