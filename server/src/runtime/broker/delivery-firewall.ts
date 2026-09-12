/**
 * Broker 统一交付 firewall（ADR-026 §2.4 / 工程说明 §9.2 step 4，checklist **C1**）——
 * **TS 参考骨架**。
 *
 * 这是**唯一**把响应交回 adapter 的 choke point：declarative（`declarative_host` / `sandbox`）、
 * imperative（`fetch-proxy` / `sandbox.imperative`）、actuator（ADR-030 action 入口）三入口
 * **必须**都经此函数交付，不得各自直接构造 adapter-visible 响应（ADR-026 §2.4「统一且不可
 * 绕过」）。「无旁路」由此结构 + 发布门共同保证。
 *
 * 交付事务次序（ADR-026 §2.4，任一步失败 → 抛错、**绝不交付原响应**、绝不半提交）：
 *
 *   ① A3 明文边界   传输层须已解码为 UTF-8 明文；非法 / 非 UTF-8 → fail-closed（不交付原始字节）
 *   ② Policy 匹配   从 masker.json 选出适用规则（**seam**：由调用方按 match 块解析后传入 rules）
 *   ③ Capture       从**脱敏前**响应提取 credential 敏感值  ┐
 *   ④ Validate      类型 / 数量 / 大小 / scope / 目标           │ applyResponseMasker（纯，任一失败即抛）
 *   ⑤ Project       删除 / 替换 adapter-visible 响应中的原值   ┘  —— 含 C0：**源响应投影**
 *   ⑥ Commit        原子提交 credential（A6 单持久 ref）        —— commitMaskerCaptured
 *   ⑦ header 脱敏    响应头 allowlist（Set-Cookie/Authorization/Location 剥除）→ adapter —— processResponse
 *
 * 注：原 ⑦「注入值回显剥离」（stripEchoes）已于 2026-08-05 退役（ADR-023 §2.5 修订）——回显改由
 * Masker 作者 `redact` 声明式承接（ADR-026 §2.10），firewall 不再做 blanket 反射剥离。
 *
 * **C0（ADR-023 源响应投影缺口）**：⑤ Project 作用于**源响应**——credential-sensitive `bind`
 * 抽取所在的那条响应，其原值在交付前被替换为 sentinel（ADR-023 §4 精确边界）。firewall
 * 交付事务测试须含「源响应投影后再交付」的 raw→delivered 用例（见 smoke）。
 *
 * 🔒 红线 #1 承重路径 + 不可绕过边界：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环
 *    （AGENTS.md §1 / ADR-026 §6）。错误只进宿主日志，绝不含原值 / 命中片段 / 回流 adapter。
 *
 * **接线进度（2026-08-05，🔒 待人工签收）**：**imperative 入口已接线**——`fetch-proxy.ts`
 *    `proxyFetch` 每次 `ctx.fetch` 交回 adapter 的响应已改为强制经本 choke point（原末尾裸
 *    `processResponse` 已移除；无策略 → 空规则透明交付，行为等价、无旁路）；sandbox
 *    `ImperativeAdapterDeps.masker` 提供注入点，端到端 smoke 见 `sandbox.imperative.smoke.ts`。
 *    **owner 决议已处置（2026-08-05，ADR-026 §2.10）**：**①** A3 真实判定已由传输层给出
 *    （`transport/direct.ts` charset + `fatal` 解码 → `decodeOk`，本层 `transportDecodeOk` 入口消费）；
 *    原 **⑦** 注入值回显 blanket 剥离（`injectedValues`/`stripEchoes`）**已退役**（ADR-023 §2.5 修订，
 *    回显交 Masker `redact` 承担）；**actuator** 入口收口已确认（ADR-030 已接受）。
 *    **仍待接线**：**declarative** 宿主代取 + **actuator** 两入口；**②** Policy 匹配（§2.10
 *    `match`→rules 解析与 store 装配，seam）、**⑥** Credential Store 原子性 / generation swap（真实 SecureStore）。
 */

import { type ProcessedResponse, processResponse, type RawResponse } from "./assemble.js";
import type { HeaderMap } from "./header-sanitize.js";
import type { BrokerManifestView } from "./inject-policy.js";
import { commitMaskerCaptured, type MaskerCommitContext, type MaskerCommitSink } from "./masker-commit.js";
import { applyResponseMasker, type MaskerRawResponse, type MaskerRule } from "./response-masker.js";

/** 交付 firewall 阶段错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不含原值。 */
export class DeliveryFirewallError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "DeliveryFirewallError";
  }
}

/** 交付 firewall 入口的原始响应（**脱敏前**）。`body` 是传输层解码后的 UTF-8 明文（A3）。 */
export interface FirewallRawResponse {
  status: number;
  headers: HeaderMap;
  /** 传输层解码后的明文 body；无 body（如 204 / HEAD）时缺省。 */
  body?: string;
  /** P1-04：传输层折叠前记录的重复响应头名（小写）；Masker header 源命中即 `capture_ambiguous`。 */
  repeatedHeaders?: readonly string[];
}

export interface DeliveryFirewallInput {
  raw: FirewallRawResponse;
  /**
   * A3 明文边界：传输层是否已把 body 成功解码为 UTF-8 明文（`Content-Encoding` 解压 + 字符集
   * 解码属传输层职责）。`false` → fail-closed，绝不把原始 / 非 UTF-8 字节交给 Masker 或 adapter。
   * **seam**：真实判定在传输层（`fetch-proxy`/`transport`），本层作边界断言（纵深防御）。
   */
  transportDecodeOk: boolean;
  /**
   * **P1-04 基数可证明性**：传输层能否证明每个响应头名在线上出现的次数（见
   * `TransportResponse.headerCardinalityAttested`）。`false` 时任何 header 源 Masker 规则
   * fail-closed（`header_cardinality_unattested`）——折叠后的 `"a, b"` 与单值 `"a, b"` 不可区分，
   * 把它当凭证收割等于在歧义上开口。缺省按 `false`（**不可证明**）处理。
   */
  headerCardinalityAttested?: boolean;
  /**
   * ② Response Credential Policy 匹配结果：本次响应适用的 Masker 规则。
   * **seam**：调用方从签名 `masker.json` 的 match 块（url/status/content-type）解析选出后传入；
   * 纯引擎不含 match 判定（ADR-026 §2.8）。空数组 = 无策略命中，响应仍**经本 choke point** 交付。
   */
  rules: readonly MaskerRule[];
  /** ⑥ Commit 目标权威（已验签 manifest credentials；type/scope 由此取，ADR-012 §2.4）。 */
  view: BrokerManifestView;
  /** ⑥ Commit 落库目标（`CredentialStore`；真实原子性 / generation swap 为 seam）。 */
  sink: MaskerCommitSink;
  ctx: MaskerCommitContext;
  /** 执行取消信号。Capture 与不可逆 Commit 前均须即时复核，防忽略 abort 的 transport 晚到后落库。 */
  signal?: AbortSignal;
}

export interface DeliveryOutcome {
  /** 交回 adapter 的响应（已 ⑤ 投影 + ⑦ header 脱敏）。 */
  response: ProcessedResponse;
  /** 本次交付提交的持久 credential 数（A6：≤1）。诊断用，**不含值**。 */
  committedCount: number;
}

/**
 * 经统一 firewall 交付一次响应（交付事务，fail-closed）。三入口共用此唯一 choke point。
 *
 * 任一步抛错 → 向上传播、**不返回可交付响应**（调用方据此让整条 capability 失败，绝不回退到
 * 交付原响应，ADR-026 §2.5）。⑤ Project 之前的 ③④ 由 `applyResponseMasker` 内部 fail-closed；
 * ⑥ Commit 失败在交付**之前**，故不会「已交付又提交失败」；⑥ 成功但后续（纯步）异常时，最坏是
 * 「凭证已存但本次响应未交付」的**安全侧偏差**（ADR-026 §2.4 明示接受），绝不泄露原响应。
 */
export function deliverThroughFirewall(input: DeliveryFirewallInput): DeliveryOutcome {
  const { raw, rules, view, sink, ctx } = input;

  // ① A3 明文边界（纵深防御；真实解码判定在传输层 seam）。
  if (!input.transportDecodeOk) {
    throw new DeliveryFirewallError(
      "body_not_plaintext",
      "传输层未能解码为 UTF-8 明文（A3）——拒交付，绝不把原始 / 非 UTF-8 字节交 Masker/adapter",
    );
  }

  // ①b P1-04 原始基数边界：传输层不能证明基数时，header 源规则一律拒（纵深防御，与纯引擎
  // 的 `capture_ambiguous` 分工：引擎判「已知重复」，本层判「无从得知」）。
  if (input.headerCardinalityAttested !== true && rules.some((r) => r.capture.source === "header")) {
    throw new DeliveryFirewallError(
      "header_cardinality_unattested",
      "传输层无法证明响应头原始基数（P1-04）——header 源 Masker 规则拒交付，绝不收割折叠后的合并值",
    );
  }

  // 取消可能发生在 transport 已 resolve、但响应尚未进入交付事务的窗口。
  assertDeliveryActive(input.signal);

  const hadBody = raw.body !== undefined;

  // ②→⑤ Capture + Validate + Project（纯引擎；任一失败即抛 → fail-closed）。
  // body 缺省时以空串喂入：header 源规则不读 body；json 源规则遇空串 → capture_not_json 正确 fail-closed。
  const maskerRaw: MaskerRawResponse = {
    status: raw.status,
    headers: raw.headers,
    body: raw.body ?? "",
    ...(raw.repeatedHeaders !== undefined ? { repeatedHeaders: raw.repeatedHeaders } : {}),
  };
  const { captured, projected } = applyResponseMasker(rules as MaskerRule[], maskerRaw);

  // ⑥ Commit（A6 单持久 ref；未声明 ref fail-closed）。在交付**之前**，失败则不交付。
  assertDeliveryActive(input.signal);
  commitMaskerCaptured(captured, view, sink, ctx);

  // ⑦ 响应头 allowlist 脱敏（Set-Cookie/Authorization/Location 剥除）→ adapter。
  const deliveredBody: string | undefined = hadBody ? projected.body : undefined;
  const rawForDelivery: RawResponse =
    deliveredBody === undefined
      ? { status: raw.status, headers: projected.headers }
      : { status: raw.status, headers: projected.headers, body: deliveredBody };

  return { response: processResponse(rawForDelivery), committedCount: captured.length };
}

function assertDeliveryActive(signal: AbortSignal | undefined): void {
  if (signal?.aborted) {
    throw new DeliveryFirewallError("delivery_cancelled", "执行已取消，拒绝 Capture / Commit / 交付");
  }
}
