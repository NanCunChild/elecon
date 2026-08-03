/**
 * Masker → Credential Store 提交桥接冒烟（checklist C2 落库中段）。
 *
 *   planMaskerCommit         →  captured[] + manifest view → CredentialEntry[]（纯，含 fail-closed）
 *   commitMaskerCaptured + CredentialStore
 *                            →  提交后 get(ref) 取到收割值（证 Capture→Commit→resolver.get 闭环）
 *
 *   运行：cd server && npm run smoke:masker-commit
 *
 * 🔒 红线 #1 承重路径（凭证派生值入核心库）：与被测代码一并须人工 + 安全清单复核
 * （不得 AI 独自闭环，AGENTS.md §1）。
 */

import { strict as assert } from "node:assert";
import { runMain } from "../__testutils__/smoke-utils.js";
import { CredentialStore } from "../credential/store.js";
import type { BrokerManifestView } from "./inject-policy.js";
import { commitMaskerCaptured, MaskerCommitError, planMaskerCommit } from "./masker-commit.js";
import type { CapturedCredential } from "./response-masker.js";

const AIRCON_VIEW: BrokerManifestView = {
  allow: ["https://gxkt.juhaolian.cn/*"],
  credentials: {
    "aircon-session": {
      scope: ["https://gxkt.juhaolian.cn/*"],
      type: "header",
      headerName: "x-access-token",
    },
  },
};

const ctx = { schoolId: "juhaolian-demo", now: () => 1_700_000_000_000 };

function expectCommitError(fn: () => unknown, code: string, name: string): void {
  try {
    fn();
  } catch (err) {
    assert.ok(err instanceof MaskerCommitError, `${name}: 期望 MaskerCommitError，实得 ${String(err)}`);
    assert.equal(err.code, code, `${name}: 错误码应为 ${code}，实得 ${err.code}`);
    return;
  }
  assert.fail(`${name}: 期望 fail-closed（${code}），却成功`);
}

async function main(): Promise<void> {
  let passed = 0;

  // ① 单个 credential 收割 → 条目 type/scope 取自 manifest decl（防御性副本），value 原样，
  //    expiresAt=null / status=active。
  {
    const captured: CapturedCredential[] = [
      { ruleId: "r-aircon", ref: "aircon-session", value: "TOKEN_FICTITIOUS_abc123" },
    ];
    const entries = planMaskerCommit(captured, AIRCON_VIEW, ctx);
    assert.equal(entries.length, 1, "应产出 1 条");
    const e = entries[0]!;
    assert.deepEqual(
      e,
      {
        ref: "aircon-session",
        schoolId: "juhaolian-demo",
        type: "header",
        scope: ["https://gxkt.juhaolian.cn/*"],
        value: "TOKEN_FICTITIOUS_abc123",
        acquiredAt: 1_700_000_000_000,
        expiresAt: null,
        status: "active",
      },
      "条目形状 / 权威字段应来自 manifest decl",
    );
    // scope 是防御性副本（非同一引用）。
    assert.notEqual(e.scope, AIRCON_VIEW.credentials!["aircon-session"]!.scope, "scope 应为副本");
    passed++;
    console.log("  ✓ 单 credential → CredentialEntry（type/scope 取自 manifest，value 原样，session 语义）");
  }

  // ② 空 captured（如全 redact、无 credential 目标）→ 无条目、不落库。
  {
    const entries = planMaskerCommit([], AIRCON_VIEW, ctx);
    assert.equal(entries.length, 0, "空 captured 不产条目");
    passed++;
    console.log("  ✓ 空 captured（纯 redact）→ 不落库");
  }

  // ③ A6：captured > 1 → commit_multiple_credentials fail-closed，且 put 前即拦（不落任何库）。
  {
    const captured: CapturedCredential[] = [
      { ruleId: "r1", ref: "aircon-session", value: "v1" },
      { ruleId: "r2", ref: "aircon-session", value: "v2" },
    ];
    expectCommitError(
      () => planMaskerCommit(captured, AIRCON_VIEW, ctx),
      "commit_multiple_credentials",
      "A6 单持久 credential",
    );
    const store = new CredentialStore(undefined, ctx.now);
    expectCommitError(
      () => commitMaskerCaptured(captured, AIRCON_VIEW, store, ctx),
      "commit_multiple_credentials",
      "A6 via commit",
    );
    assert.equal(store.list().length, 0, "A6 失败时不得半提交");
    passed++;
    console.log("  ✓ A6：captured>1 fail-closed（commit_multiple_credentials），不半提交");
  }

  // ④ ref 未在 manifest 声明 → commit_ref_undeclared fail-closed（已收割敏感值绝不静默丢）。
  {
    const captured: CapturedCredential[] = [{ ruleId: "r", ref: "ghost-ref", value: "leaked?" }];
    expectCommitError(
      () => planMaskerCommit(captured, AIRCON_VIEW, ctx),
      "commit_ref_undeclared",
      "未声明 ref",
    );
    const store = new CredentialStore(undefined, ctx.now);
    expectCommitError(
      () => commitMaskerCaptured(captured, AIRCON_VIEW, store, ctx),
      "commit_ref_undeclared",
      "未声明 ref via commit",
    );
    assert.equal(store.list().length, 0, "未声明 ref 失败时不得落库");
    passed++;
    console.log("  ✓ 未声明 ref → commit_ref_undeclared fail-closed（不落库）");
  }

  // ⑤ 闭环：commit 后 store.get(ref) 取到收割值，via=header（可供 B6 命名 header 注入）。
  {
    const store = new CredentialStore(undefined, ctx.now);
    const captured: CapturedCredential[] = [
      { ruleId: "r-aircon", ref: "aircon-session", value: "TOKEN_FICTITIOUS_xyz789" },
    ];
    commitMaskerCaptured(captured, AIRCON_VIEW, store, ctx);
    const resolved = await store.get("aircon-session");
    assert.ok(resolved !== null, "commit 后应能取回凭证");
    assert.equal(resolved.via, "header", "via 应为 header");
    assert.equal(resolved.value, "TOKEN_FICTITIOUS_xyz789", "取回值应等于收割值");
    passed++;
    console.log("  ✓ 闭环：commit → get(ref) 取回收割值（via=header，供命名头注入）");
  }

  console.log(`Masker Commit 桥接 smoke: ${passed} 组通过 ✅`);
}

runMain(main);
