/// V1 bundle 的编译期信任 profile；兼容边界由 ADR-041 承接 ADR-024。
///
/// 仅 `ELECON_TRUST_PROFILE=dev-sideload` 编入旧 V1 无签名 bundle 入口；
/// 缺省或未知值均为 DEPLOY。它与 Flutter Debug/Profile/Release 构建模式独立。
/// 此门不控制 `elecon-script/1`：新源码在各构建模式经用户授权导入，
/// 本地文件调试工具按 ADR-100 在 Debug 构建默认提供。
///
/// V1 兼容保护包括编译期剔除、独立 Android applicationId 后缀、启动水印，
/// 以及 `tool/check_release_gate.sh` 的哨兵和元数据检查；它们不证明整个产物
/// 不含新源码导入。原生模块侧载仍受当前架构 B4 限制。
/// 核心信任实现的人工审阅按现行 AGENTS 与兼容维护边界执行。
library;

/// 编译期信任 profile 原始值（`--dart-define=ELECON_TRUST_PROFILE=...`）。缺省 `''`。
const String kTrustProfile = String.fromEnvironment('ELECON_TRUST_PROFILE');

/// DEV 侧载 profile 的**唯一**合法值。其余一切值均判为 DEPLOY（fail-closed）。
const String kDevSideloadProfile = 'dev-sideload';

/// 旧 V1 bundle 侧载入口是否编入本产物。DEPLOY 下为 `false`，启用该入口的分支
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
/// `tool/check_release_gate.sh` 对 DEPLOY 产物 grep 本字面量，命中即判定「V1 侧载入口
/// 仍在产物里」并拒绝分发。这是**结构性**证据（验代码确实不在），比元数据标记强。
///
/// 🔒 **不得改写、拼接、或用变量组装**：gate 靠它以完整字面量出现在产物中才能命中；
/// 任何形式的拆分都会让符号 grep 变成永远为真的空断言。
const String kSideloadEntryMarker = 'ELECON_SIDELOAD_ENTRY_A7F3';
