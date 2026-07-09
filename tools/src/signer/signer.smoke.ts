/**
 * signer 冒烟测试 —— 仅覆盖**确定性、无密钥**部分：bundle digest 稳定性、
 * revocation 纯判定（kill-switch / 最低版本 / digest / 版本区间）、semver 比较。
 *
 * 🔒 **有意不包含** Ed25519 sign/verify 往返测试与密钥加载——签名操作是承重路径，
 *    其代码与测试须由维护者人工闭环（AGENTS.md §1，ADR-002 §2.3）。
 *
 *   运行：cd tools && npm run smoke:signer
 */

import { strict as assert } from "node:assert";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { computeBundleDigest, serializePayload } from "./index.js";
import { compareSemver, isRevoked, pickNewer, type RevocationList } from "./revocation.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const xidian = join(repoRoot, "adapters", "school-xidian");

// ---- digest 确定性 ----

{
  const d1 = computeBundleDigest(xidian);
  const d2 = computeBundleDigest(xidian);
  assert.strictEqual(d1, d2, "同一 bundle 两次 digest 必须一致");
  assert.match(d1, /^[0-9a-f]{64}$/, "digest 应为 64 hex（SHA-256）");
  console.log("✓ bundle digest 确定性");
}

// ---- payload 序列化键序稳定 ----

{
  const a = serializePayload({ adapterId: "school-x", adapterVersion: "1.0.0", tier: "official", digest: "ab" });
  const b = serializePayload({ digest: "ab", tier: "official", adapterVersion: "1.0.0", adapterId: "school-x" } as never);
  assert.ok(a.equals(b), "payload 序列化须与输入键序无关（固定键序）");
  console.log("✓ payload 序列化键序稳定");
}

// ---- semver 比较 ----

{
  assert.strictEqual(compareSemver("1.2.0", "1.10.0"), -1, "1.2.0 < 1.10.0（数字非字典序）");
  assert.strictEqual(compareSemver("2.0.0", "1.9.9"), 1);
  assert.strictEqual(compareSemver("1.0.0", "1.0.0"), 0);
  console.log("✓ semver 比较");
}

// ---- revocation 判定 ----

const base: RevocationList = {
  sequence: 5,
  issuedAt: "2026-07-09T00:00:00Z",
  ttlSeconds: 3600,
  minVersions: {},
  killSwitch: false,
  entries: [],
};

{
  // kill-switch
  const d = isRevoked({ adapterId: "school-x", adapterVersion: "1.0.0", digest: "aa" }, { ...base, killSwitch: true });
  assert.ok(!d.allowed && /kill-switch/.test(d.reason ?? ""), "kill-switch 应拒绝一切");

  // 最低版本
  const d2 = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.0.0", digest: "aa" },
    { ...base, minVersions: { "school-x": "1.2.0" } },
  );
  assert.ok(!d2.allowed && /低于最低/.test(d2.reason ?? ""), "低于最低版本应拒绝");

  // digest 精确吊销
  const d3 = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.0.0", digest: "deadbeef" },
    { ...base, entries: [{ adapterId: "school-x", digest: "deadbeef", reason: "有漏洞" }] },
  );
  assert.ok(!d3.allowed && /被吊销/.test(d3.reason ?? ""), "digest 命中应拒绝");

  // 版本区间吊销
  const d4 = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.1.0", digest: "aa" },
    { ...base, entries: [{ adapterId: "school-x", versionRange: { minInclusive: "1.0.0", maxInclusive: "1.2.0" }, reason: "区间坏" }] },
  );
  assert.ok(!d4.allowed && /区间/.test(d4.reason ?? ""), "版本区间命中应拒绝");

  // 放行（无命中）
  const d5 = isRevoked({ adapterId: "school-y", adapterVersion: "3.0.0", digest: "aa" }, base);
  assert.ok(d5.allowed, "无命中应放行");

  console.log("✓ revocation 判定（kill-switch / 最低版本 / digest / 区间 / 放行）");
}

// ---- 防回滚 ----

{
  const older: RevocationList = { ...base, sequence: 3 };
  const newer: RevocationList = { ...base, sequence: 7 };
  assert.strictEqual(pickNewer(newer, older).sequence, 7, "旧序号不得覆盖新序号");
  assert.strictEqual(pickNewer(base, newer).sequence, 7, "新序号应被采用");
  console.log("✓ 防回滚（sequence 单调）");
}

console.log("\nsigner smoke（确定性部分）全部通过 ✅  —— sign/verify 往返测试留待人工闭环。");
