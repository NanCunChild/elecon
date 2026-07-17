/**
 * revocation：吊销清单构建 / 验签 / 判定（ADR-002 §2.4）。
 *
 * 🔒 安全敏感承重路径（红线 #4）。按 AGENTS.md §1 不得由 AI 独自闭环——本文件是**骨架**：
 *     吊销清单的**数据结构 + 纯判定逻辑**（bundle 是否被吊销 / 是否低于最低版本 / kill-switch）
 *     已实现供审阅；**清单签名/验签复用 signer 的 Ed25519（同一 pin 公钥体系）**，
 *     其密钥接线与公网分发/拉取-回退-bootstrap 由维护者人工闭环。
 *
 * 机制（ADR-002 §2.4）：
 *  - 吊销清单：signed revocation list，经公网哑服务分发（公开、零凭证，红线 #2）。
 *  - 核心行为：验签清单 → 拒绝加载被吊销 bundle；支持**最低版本下限**强制升级；支持 **kill-switch**。
 *  - 时效/离线：清单自带 TTL；拉取失败回退**上一份已验签清单**（绝不"拉不到=全放行"）。
 *  - bootstrap：App bundle 预置一份初始已签名清单作 last-good 初值（新装即 fail-closed 而不瘫）。
 *
 * **字节精确签名**（与 SignedCatalog 同模型，ADR-002 §2.3）：签名对象 = RevocationList 的**原始
 * JSON 字节**（`SignedRevocationList.listJson`），签/传/验/parse 同一份字节，Dart 侧零规范化、
 * 零跨语言漂移。**不**重新序列化 list——避免字段漂移把某字段甩出签名范围。
 */

import { verify as edVerify, type KeyObject } from "node:crypto";
import type { SignBackend, VerifyResult } from "./index.js";

// ---- 数据结构 ----

/** 单条吊销规则。至少命中一种匹配即视为吊销。 */
export interface RevocationEntry {
  adapterId: string;
  /** 精确吊销的 bundle digest（hex）。可选。 */
  digest?: string;
  /** 版本范围吊销：闭区间下限/上限（semver 字符串）。可选。 */
  versionRange?: { minInclusive?: string; maxInclusive?: string };
  reason: string;
}

export interface RevocationList {
  /** 单调递增序号，防回滚（旧清单不得覆盖新清单）。 */
  sequence: number;
  issuedAt: string;
  ttlSeconds: number;
  /** 每个 adapterId 的最低可加载版本（强制升级）。 */
  minVersions: Record<string, string>;
  /** 全局 kill-switch：为 true 时拒绝加载一切 official adapter（密钥泄露急性事件）。 */
  killSwitch: boolean;
  entries: RevocationEntry[];
}

/**
 * 已签名的吊销清单（复用 signer 的 Ed25519 体系，**字节精确**，同 SignedCatalog）。
 *
 * 被签名的是 [listJson] 原始文本；keyId/algorithm/signature 不在签名范围内（改动任一都会
 * 验签失败或命不中锚，故无需签）。
 */
export interface SignedRevocationList {
  /** 被签名的 RevocationList **原始 JSON 文本**（签/传/验/parse 同一份字节）。 */
  listJson: string;
  /** Ed25519 签名（base64）over `Buffer.from(listJson,"utf-8")`。 */
  signature: string;
  keyId: string;
  algorithm: "ed25519";
}

// ---- 纯判定逻辑（无密钥，可测） ----

/** 极简 semver 比较（仅 `x.y.z` 数字段；预发布/构建元数据不支持，需要时人工扩展）。 */
export function compareSemver(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

export interface AdapterRef {
  adapterId: string;
  adapterVersion: string;
  digest: string;
}

export interface RevocationDecision {
  allowed: boolean;
  reason?: string;
}

/**
 * 判定某 adapter 是否被吊销 / 低于最低版本 / 撞 kill-switch。fail toward less trust。
 * 纯函数：不拉取、不验签（验签由调用方先做，传入的须是**已验签**清单）。
 */
export function isRevoked(ref: AdapterRef, list: RevocationList): RevocationDecision {
  if (list.killSwitch) {
    return { allowed: false, reason: "kill-switch 生效：拒绝加载全部 official adapter" };
  }
  const min = list.minVersions[ref.adapterId];
  if (min && compareSemver(ref.adapterVersion, min) < 0) {
    return { allowed: false, reason: `版本 ${ref.adapterVersion} 低于最低要求 ${min}（强制升级）` };
  }
  for (const e of list.entries) {
    if (e.adapterId !== ref.adapterId) continue;
    if (e.digest && e.digest === ref.digest) {
      return { allowed: false, reason: `bundle 被吊销：${e.reason}` };
    }
    const r = e.versionRange;
    if (r) {
      const geMin = r.minInclusive ? compareSemver(ref.adapterVersion, r.minInclusive) >= 0 : true;
      const leMax = r.maxInclusive ? compareSemver(ref.adapterVersion, r.maxInclusive) <= 0 : true;
      if (geMin && leMax) return { allowed: false, reason: `版本区间被吊销：${e.reason}` };
    }
  }
  return { allowed: true };
}

/**
 * 选择 last-good 清单：新清单 sequence 须 > 现存，且（🔒 人工闭环）须已验签。
 * 防回滚：旧序号不得覆盖新序号（ADR-002 §2.4「绝不把拉不到当放行」的姊妹约束）。
 */
export function pickNewer(current: RevocationList, incoming: RevocationList): RevocationList {
  return incoming.sequence > current.sequence ? incoming : current;
}

// ---- 签名 / 验签（字节精确，同 SignedCatalog；复用 signer 的 Ed25519 + pin 公钥体系） ----

/** 🔒 对 RevocationList 签名 → SignedRevocationList（序列化**恰好一次**，此后只用这份字节）。 */
export async function signRevocation(
  list: RevocationList,
  backend: SignBackend,
): Promise<SignedRevocationList> {
  const listJson = JSON.stringify(list);
  const signature = await backend.sign(Buffer.from(listJson, "utf-8"));
  return { listJson, signature, keyId: backend.keyId, algorithm: "ed25519" };
}

/**
 * 🔒 验签吊销清单（对 pin 公钥；fail-closed）→ 成功返回**已解析** RevocationList。
 * **信任哪把公钥 + 是否采用（防回滚/TTL/last-good）** 由客户端加载器裁定，不在此。
 */
export function verifyRevocation(
  signed: SignedRevocationList,
  publicKey: KeyObject,
): VerifyResult<RevocationList> {
  if (signed.algorithm !== "ed25519") {
    return { ok: false, reason: `不支持的签名算法：${signed.algorithm}` };
  }
  const bytes = Buffer.from(signed.listJson, "utf-8");
  if (!edVerify(null, bytes, publicKey, Buffer.from(signed.signature, "base64"))) {
    return { ok: false, reason: "Ed25519 验签失败 → fail-closed。" };
  }
  try {
    return { ok: true, value: JSON.parse(signed.listJson) as RevocationList };
  } catch (err) {
    return { ok: false, reason: `revocation JSON 解析失败：${(err as Error).message}` };
  }
}

// 🔒 待人工闭环：
//   - 签名密钥接线（YubiKey pin 公钥；密钥接线人工）。
//   - 公网哑服务分发端点 + 客户端拉取 + TTL + 拉取失败回退 last-good（server/src/public，红线 #2）。
//   - App bundle 预置初始已签名清单（bootstrap 初值）。
//   - 与核心加载路径联动（verifyAdapter 通过后再过 isRevoked）+ ADR-012 凭证吊销联动。
