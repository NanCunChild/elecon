/**
 * 信任裁定上下文 —— fetch 运行时的强制入场凭据（ADR-002 §2.6 运行时闸门）。
 * 镜像 `client/lib/core/trust/trusted_context.dart`（#79 P0-1）。
 *
 * 立场：`runFetchAdapter` 是凭证注入的入口，其安全性不得依赖「上层不要误调用」
 * 的调用约定，而要在可信核心边界 fail-closed——入口强制接收本类型实例，而
 * 本类型只能经核心的信任裁定路径构造：
 *
 *  - **official**：由核心验签流程构造（ADR-002 §2.3 验签 → §2.4 吊销 → 由签名
 *    裁定档位）。验签器尚未落地，落地前**无 official 构造路径**——生产环境下
 *    fetch 模式整体 fail-closed（不存在已验签的 official adapter，就不该有任何
 *    adapter 拿到凭证注入能力）。
 *  - **dev_sideload**：dev 例外（ADR-002 §2.5）。服务端无「debug build」概念，
 *    对应边界取 `NODE_ENV !== "production"`：生产下构造即抛。与客户端的编译期
 *    剔除（kDebugMode 死代码消除）语义等价但机制不同——服务端二进制不向终端
 *    用户分发，运行时 fail-closed 检查即为该端的承重闸门（campus 中继落地时
 *    随部署形态复核，ADR-003）。
 *
 * 纵深防御（§2.6 运行时不信任上游）：TS 的 `private constructor` 只是编译期
 * 约束，运行时仍可 `new (TrustedAdapterContext as any)(...)`；`instanceof` 也可被
 * `Object.create(TrustedAdapterContext.prototype)` 伪造。故运行时防伪不依赖二者：
 *
 *  - 构造器要求**模块私有 Symbol token**——模块外拿不到 token，直接 `new` 构造即抛；
 *  - 每个合法实例登记进**模块私有 WeakSet**，入口经 [isTrustedAdapterContext]
 *    校验登记——绕过构造器的对象（cast / Object.create）不在登记内，一律拒绝。
 *
 * `instanceof` 降级为守卫内的辅助检查（兼收窄类型），不再是唯一运行时防伪。
 *
 * 🔒 红线 #1 凭证路径承重件：改动本文件须人工 + 安全清单复核，不得 AI 独自闭环。
 */

/** 宿主裁定的 adapter 信任档（ADR-002 §2.1 两档制；权威来自验签，不信任 manifest 自报）。 */
export type AdapterTrustTier = "official" | "dev_sideload";

/** 模块私有构造 token：不导出，模块外无法取得 → 绕过静态工厂直接 `new` 必抛。 */
const issuanceToken = Symbol("elecon.TrustedAdapterContext.issuance");

/** 模块私有签发登记：只有经合法构造路径产生的实例在册，WeakSet 成员身份不可伪造。 */
const issued = new WeakSet<TrustedAdapterContext>();

/** 经核心信任裁定后签发的执行凭据。运行时防伪见文件头（token + 签发登记）。 */
export class TrustedAdapterContext {
  private constructor(token: symbol, readonly tier: AdapterTrustTier) {
    if (token !== issuanceToken) {
      throw new Error("TrustedAdapterContext 只能经核心信任裁定路径构造（ADR-002 §2.6，fail-closed）");
    }
    issued.add(this);
  }

  /**
   * dev 侧载裁定（ADR-002 §2.5）：仅非生产环境可构造；生产下抛错（fail-closed）。
   */
  static devSideload(): TrustedAdapterContext {
    if (process.env.NODE_ENV === "production") {
      throw new Error("dev 侧载信任上下文在生产环境不存在（红线 #4/#5，ADR-002 §2.5）");
    }
    return new TrustedAdapterContext(issuanceToken, "dev_sideload");
  }

  // ADR-002 §2.3 验签器落地后在此增 official 构造路径（入参为验签产物，
  // 由验签实现的 PR 一并人工审）。在那之前不提供——fail-closed。
}

/**
 * 运行时防伪守卫：仅认模块私有登记内的实例。字面量 cast、`Object.create(prototype)`、
 * token 不符的直接 `new` 均不在册 → false。`instanceof` 仅为类型收窄的辅助检查。
 */
export function isTrustedAdapterContext(value: unknown): value is TrustedAdapterContext {
  return value instanceof TrustedAdapterContext && issued.has(value);
}

/**
 * fetch 运行时入场判定（纯函数，负例可测）：official 一律放行；dev_sideload 仅
 * 非生产放行；其余 fail-closed。生产接线固定为 `production: NODE_ENV === "production"`。
 */
export function fetchTrustPermitted(tier: AdapterTrustTier, opts: { production: boolean }): boolean {
  return tier === "official" || !opts.production;
}
