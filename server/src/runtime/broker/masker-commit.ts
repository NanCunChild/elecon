/**
 * Response Masker → Credential Store 提交桥接（ADR-026 §2.8 交付事务 Commit 段 / 工程说明
 * §9.2 step 5，checklist **C2** 的落库中段）—— **TS 参考实现**。
 *
 * `applyResponseMasker`（纯引擎，`response-masker.ts`）产出 `captured[]`（credential 目标收割值）
 * + `projected`。本模块把 `captured[]` **落库**，供后续执行经 broker `decideInjection` →
 * `resolver.get(ref)` 注入（命名 header 由 ADR-029 §2.1 `headerName` 承接）。这是
 * **Capture（已落地）→ Commit（本件）→ 注入（已落地）** 闭环的缺失中段。
 *
 * 与 `harvest.ts` 同构：注入权威唯一在**已验签 manifest** `credentials.<ref>`（type/scope），
 * store 只存防御性副本（ADR-012 §2.4）；同 ref 已存在 → 覆盖（会话轮换）；`expiresAt=null`
 * （会话语义，见 harvest 文件头，靠 §2.5 401-重登兜底）。
 *
 * **与 harvest 的关键差异**：harvest 的 plan 源自 decl（无 decl 自然不产项，故防御性跳过）；
 * 本件 plan 源自**响应**——已收割到敏感值却在 manifest 找不到对应 credential decl，是 D2 / RM8
 * 契约违背，**绝不静默丢**，必须 `commit_ref_undeclared` fail-closed。
 *
 * A6（安全清单）：**单响应至多一个持久 credential**——运行期 assert `captured.length ≤ 1`，
 * 超出 `commit_multiple_credentials` fail-closed。分层由 validator RM15 / firewall 保证，此处
 * 作纵深防御兜底（Broker 不信任上游已校验）。
 *
 * 🔒 红线 #1 承重路径（凭证派生值入核心库）：AI 起草，须人工 + 安全清单复核，不得 AI 独自
 *    闭环（AGENTS.md §1 / ADR-026 §6）。错误只进宿主日志，绝不含收割值 / 回流 adapter。
 *
 * ⚠️ **尚未接入 live 交付路径**：把本 Commit 编入真正的响应交付需要 —— ① 统一 delivery
 *    firewall 证明 declarative / imperative / actuator 三入口无旁路（checklist C1，含 A3 非
 *    UTF-8 fail-closed）；② 先修 ADR-023 源响应投影缺口（C0）。二者均须人工主导，故本件先作
 *    独立、可测的 Commit 段落地，接线点留空。
 */

import type { CredentialEntry } from "../credential/types.js";
import type { BrokerManifestView } from "./inject-policy.js";
import type { CapturedCredential } from "./response-masker.js";

/** 提交阶段错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不含收割值。 */
export class MaskerCommitError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "MaskerCommitError";
  }
}

/** Commit 写入目标（`CredentialStore` 满足之；与 harvest `HarvestSink` 同形）。 */
export interface MaskerCommitSink {
  put(entry: CredentialEntry): void;
}

/** Commit 所需执行上下文（运行时提供）。 */
export interface MaskerCommitContext {
  schoolId: string;
  now: () => number;
}

/**
 * 把 Masker 收割的 credential 目标值编排为待落库条目（**纯**，可 golden / 独立 smoke）。
 *
 * - **A6**：`captured.length > 1` → `commit_multiple_credentials` fail-closed。
 * - 每个 ref 必须在 manifest `credentials` 已声明，否则 `commit_ref_undeclared` fail-closed
 *   （已收割敏感值却无声明落点 = 契约违背，绝不静默丢）。
 * - `type` / `scope` 取自 manifest decl（防御性副本）；`value` 为收割标量原样透传；
 *   `expiresAt=null`（会话语义）。
 */
export function planMaskerCommit(
  captured: readonly CapturedCredential[],
  view: BrokerManifestView,
  ctx: MaskerCommitContext,
): CredentialEntry[] {
  if (captured.length > 1) {
    throw new MaskerCommitError(
      "commit_multiple_credentials",
      `单响应至多一个持久 credential（A6），实得 ${captured.length}`,
    );
  }

  const entries: CredentialEntry[] = [];
  for (const cap of captured) {
    const decl = view.credentials?.[cap.ref];
    if (decl === undefined) {
      throw new MaskerCommitError(
        "commit_ref_undeclared",
        `收割值 ref '${cap.ref}' 未在 manifest credentials 声明（D2 / RM8）`,
      );
    }
    entries.push({
      ref: cap.ref,
      schoolId: ctx.schoolId,
      type: decl.type,
      scope: [...decl.scope], // 防御性副本（注入权威仍在 manifest，ADR-012 §2.4）
      value: cap.value,
      acquiredAt: ctx.now(),
      expiresAt: null,
      status: "active",
    });
  }
  return entries;
}

/**
 * 把 Masker 收割值落库（薄桥接）。先 `planMaskerCommit` 校验 + 编排，再逐条 `sink.put`。
 * 任一步 fail-closed（抛 {@link MaskerCommitError}）→ **不落任何库**（planner 先跑完全部校验
 * 再进入 put 循环，A6 / 未声明 ref 都在 put 之前拦下，不留半提交）。
 */
export function commitMaskerCaptured(
  captured: readonly CapturedCredential[],
  view: BrokerManifestView,
  sink: MaskerCommitSink,
  ctx: MaskerCommitContext,
): void {
  const entries = planMaskerCommit(captured, view, ctx);
  for (const entry of entries) {
    sink.put(entry);
  }
}
