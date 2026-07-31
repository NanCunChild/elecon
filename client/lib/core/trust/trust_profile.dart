/// 信任 profile 编译期判别器（ADR-024）—— 侧载入口的**唯一**开关。
///
/// ADR-024 决策：把 adapter 侧载判别器从 `kReleaseMode` / `kDebugMode`（优化等级）
/// **解绑**，改由显式编译期 flag [String.fromEnvironment] `ELECON_TRUST_PROFILE`
/// 决定。「优化」人人可得（任何构建可 `--release`），「是否含侧载入口」只由本 flag 定。
///
/// **护栏 1（ADR-024 §2.3 / §5.2）——fail-closed 默认 DEPLOY**：值枚举，仅
/// `'dev-sideload'` ⟹ DEV；缺省 `''`、拼错、未识别的一切值 ⟹ DEPLOY（侧载剔除）。
/// [kSideloadEnabled] 是**编译期常量**，DEPLOY 产物内启用侧载的代码路径根本不存在、
/// 被 tree-shake 剔除（红线 #4「DEPLOY 包内无侧载入口」语义平移），任何运行时
/// config/env 都翻不开。
///
/// **接线状态（2026-07-31）**：本模块是 ADR-024 落地的**纯基座 slice**，尚未接入
/// 侧载判别路径。判别器翻转（`core/trust/trusted_context.dart` 的 [devSideload] 由
/// `kDebugMode` 改挂本常量）+ applicationId 隔离 + 启动页水印 + gate 断言四条护栏
/// **必须同一 PR 捆绑落地**，否则会造出「优化版可侧载但无补偿护栏」的危险半成品。
/// 落地拆分见 `docs/reference/adr_024_landing.md`。
///
/// **不改传输底座（ADR-024 §2.4）**：本 flag **只解绑 adapter 侧载**；dev 传输底座
/// 看全部流量，风险量级更高，恒 `kDebugMode`-only，不受本 flag 影响。
///
/// 🔒 红线 #4 承重件：改动本文件或其接线须人工 + 安全清单复核，不得 AI 独自闭环
///    （AGENTS.md §1 / ADR-024 §3）。
library;

/// 编译期信任 profile 原始值（`--dart-define=ELECON_TRUST_PROFILE=...`）。缺省 `''`。
const String kTrustProfile = String.fromEnvironment('ELECON_TRUST_PROFILE');

/// DEV 侧载 profile 的**唯一**合法值。其余一切值均判为 DEPLOY（fail-closed）。
const String kDevSideloadProfile = 'dev-sideload';

/// 侧载入口是否编入本产物。**编译期常量**：DEPLOY 下为 `false`，启用侧载的分支
/// 作为死代码被 tree-shake 剔除（护栏 2，ADR-024 §2.3）。
const bool kSideloadEnabled = kTrustProfile == kDevSideloadProfile;
