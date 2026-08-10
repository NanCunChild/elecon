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
/// **接线状态（2026-08-07：slice 1–3 已接线）**：判别器已翻转——
/// `core/trust/trusted_context.dart` 的 `devSideload()` 与 `fetchTrustPermitted`
/// 挂 [kSideloadEnabled]（slice 1）；DEV 用独立 applicationId 后缀 + 构建元数据标记
/// （`android/app/build.gradle.kts`）与启动页水印（`ui/security/dev_sideload_banner.dart`，
/// slice 2）；`tool/check_release_gate.sh` 对分发产物做符号 grep + 元数据双断言
/// （slice 3）。slice 4（AGENTS.md 红线 #4 措辞）属红线原文，由 owner 单独决策。
/// 落地拆分与签收见 `docs/reference/adr_024_landing.md`。
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

/// 产物级信任标记（护栏 4b，ADR-024 §5.3）。分发/提交产物的构建元数据必须是
/// `DEPLOY`；Android 侧由 gradle 写进 `assets/elecon_build_profile.txt`，
/// `tool/check_release_gate.sh` 与之比对，防「符号 grep 因混淆/重命名漏网」。
const String kBuildProfileLabel = kSideloadEnabled ? 'DEV-SIDELOAD' : 'DEPLOY';

/// **侧载入口符号哨兵**（护栏 4a，ADR-024 §5.3）。
///
/// 只在 [kSideloadEnabled] 为真才可达的代码路径里出现，故：
///   - DEV 产物里存在该字面量；
///   - DEPLOY 产物里，含它的分支是编译期死代码，被 tree-shake 连同字面量一并剔除。
///
/// `tool/check_release_gate.sh` 对 DEPLOY 产物 grep 本字面量，命中即判定「侧载入口
/// 仍在产物里」并拒绝分发。这是**结构性**证据（验代码确实不在），比元数据标记强。
///
/// 🔒 **不得改写、拼接、或用变量组装**：gate 靠它以完整字面量出现在产物中才能命中；
/// 任何形式的拆分都会让符号 grep 变成永远为真的空断言。
const String kSideloadEntryMarker = 'ELECON_SIDELOAD_ENTRY_A7F3';
